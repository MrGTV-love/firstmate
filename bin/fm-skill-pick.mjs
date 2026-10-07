#!/usr/bin/env node
// The TypeSafe skill-suggestion cookbook recipe on the vendored hyper-jev client.
// Usage: node bin/fm-skill-pick.mjs roster <catalog-dir>... > roster.json
//        node bin/fm-skill-pick.mjs pick <task-file> <roster.json> < keys
// Recipe: https://docs.typesafe.ai/cookbooks/skill_suggestion ("rank the whole
// roster", "rerank the top three", suggest()); question texts, thresholds,
// shortlist and excerpt are the cookbook's, verbatim. Transport, validation,
// retries and provider endpoints are .agents/skills/hyper-jev's starter client,
// unchanged. keys is two lines, the TypeSafe key then the OpenRouter key;
// either may be empty. TypeSafe is asked directly first; when that call fails and an
// OpenRouter key exists, the same request and the rest of this run go through
// OpenRouter. Keys arrive on stdin only and are never printed.
// roster: one entry per skill name, the earlier catalog winning; a skill is
// sent only when <name>/SKILL.md is a regular Git-tracked file with a
// description, and every other one is listed in not_judged with its reason.
// pick prints status=, reason=, picked=, path=, fit=, provider= and model=
// lines; status is picked, none or unavailable.
import { execFileSync } from 'node:child_process';
import { closeSync, lstatSync, openSync, readFileSync, readSync, readdirSync, realpathSync } from 'node:fs';
import { join } from 'node:path';
import { JevClient } from '../.agents/skills/hyper-jev/templates/starter/src/core/client.ts';
import { choice, noul } from '../.agents/skills/hyper-jev/templates/starter/src/core/helpers.ts';
import { LIMITS } from '../.agents/skills/hyper-jev/templates/starter/src/core/types.ts';

// Cookbook constants.
const SHORTLIST = 3;
const EXCERPT_CHARS = 700;
const GATE_THRESHOLD = 0.30;
const FITS_THRESHOLD = 0.30;
const CHOICE_INSTRUCTIONS =
  "Which of these skills, if any, is the right one to load to help with the " +
  "user's latest request?";
const GATE_QUESTIONS = {
  acts_on_user_system:
    "Is the assistant being asked to act on the user's files, accounts, devices, " +
    'or online services, rather than only to explain or advise?',
  would_follow_documented_procedure:
    'Would a careful expert answering this consult a specific documented procedure ' +
    'or set of commands, rather than answering from general understanding?',
  prose_suffices:
    'Could a knowledgeable generalist fully satisfy this request in prose, with ' +
    "no tools, no documentation, and no access to the user's files or accounts?",
};
const INVERTED = new Set(['prose_suffices']);
const RERANK_INSTRUCTIONS =
  "Exactly one of these skills is the right one to load for the user's latest " +
  'request. Which one? Read what each actually does, not just its name.';

// Firstmate bounds: fm-spawn stops the whole picker at 30 seconds.
const CALL_TIMEOUT_MS = 10_000;
const RUN_DEADLINE_MS = 25_000;
const HEAD_BYTES = 65_536;

function readHead(path) {
  const fd = openSync(path, 'r');
  try {
    const buffer = Buffer.alloc(HEAD_BYTES);
    return buffer.subarray(0, readSync(fd, buffer, 0, HEAD_BYTES, 0)).toString('utf8');
  } finally {
    closeSync(fd);
  }
}

function scalar(value) {
  if (value.startsWith('"')) return JSON.parse(value);
  if (value.startsWith("'") && value.endsWith("'")) return value.slice(1, -1).replaceAll("''", "'");
  return value.replace(/[ \t]+#.*$/, '');
}

// Reads `name` and `description` from simple YAML frontmatter: plain, quoted,
// folded (>) or literal (|) scalars, with indented continuation lines.
function frontmatter(text) {
  const match = text.replaceAll('\r\n', '\n').match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return null;
  const lines = match[1].split('\n');
  const fields = {};
  for (let i = 0; i < lines.length; i++) {
    const field = lines[i].match(/^(name|description):[ \t]*(.*?)[ \t]*$/);
    if (!field) continue;
    const continuation = [];
    while (i + 1 < lines.length && /^([ \t]|$)/.test(lines[i + 1])) continuation.push(lines[++i].trim());
    while (continuation.length && continuation.at(-1) === '') continuation.pop();
    const [, key, value] = field;
    if (/^[>|][-+]?$/.test(value)) fields[key] = continuation.join(value.startsWith('>') ? ' ' : '\n');
    else fields[key] = scalar([value, ...continuation].filter(Boolean).join(' '));
  }
  return { ...fields, body: match[2].trimStart() };
}

function tracked(dir) {
  try {
    return new Set(execFileSync('git', ['-C', dir, 'ls-files', '-z', '--', '*/SKILL.md'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).split('\0').filter(Boolean));
  } catch {
    return new Set();
  }
}

function roster(catalogs) {
  const seen = new Set();
  const skills = [];
  const notJudged = [];
  for (const catalog of catalogs) {
    let dir;
    let names;
    try {
      dir = realpathSync(catalog);
      names = readdirSync(dir).sort();
    } catch {
      continue;
    }
    const inGit = tracked(dir);
    for (const child of names) {
      const path = join(dir, child, 'SKILL.md');
      let skill = null;
      let reason = null;
      try {
        if (!lstatSync(join(dir, child)).isDirectory()) continue;
        if (!lstatSync(path, { throwIfNoEntry: false })) continue;
        skill = frontmatter(readHead(path));
      } catch {
        reason = 'unreadable skill file';
      }
      const name = skill?.name || child;
      if (seen.has(name)) continue;
      seen.add(name);
      if (!reason && !(inGit.has(`${child}/SKILL.md`) && lstatSync(path).isFile())) {
        reason = 'not a Git-tracked file in this project';
      } else if (!reason && !skill?.description) reason = 'no readable description';
      if (reason) notJudged.push({ name, reason });
      else skills.push({ name, path, description: skill.description, excerpt: skill.body.slice(0, EXCERPT_CHARS) });
    }
  }
  return { skills, not_judged: notJudged };
}

function line(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

async function pick(taskFile, rosterFile) {
  const request = readFileSync(taskFile, 'utf8');
  const { skills } = JSON.parse(readFileSync(rosterFile, 'utf8'));
  const [typesafe = '', openrouter = ''] = readFileSync(0, 'utf8').split('\n');
  const keys = { typesafe: typesafe.trim(), openrouter: openrouter.trim() };
  const byName = new Map(skills.map((skill) => [skill.name, skill]));
  const out = { status: 'unavailable', reason: '', picked: '', path: '', fit: '', provider: '', model: '' };
  const done = () => {
    for (const [key, value] of Object.entries(out)) process.stdout.write(`${key}=${line(value)}\n`);
  };
  if (!skills.length) {
    Object.assign(out, { status: 'none', reason: 'this project has no skills to judge' });
    return done();
  }
  const client = (provider) => keys[provider]
    ? new JevClient({ provider, apiKey: keys[provider], timeoutMs: CALL_TIMEOUT_MS })
    : null;
  let current = client('typesafe');
  let fallback = client('openrouter');
  if (!current) [current, fallback] = [fallback, null];
  if (!current) {
    out.reason = 'no TypeSafe or OpenRouter key';
    return done();
  }
  const deadline = AbortSignal.timeout(RUN_DEADLINE_MS);
  const state = { request, recent_context: '' };
  let directFailure = '';
  const ask = async (questions) => {
    try {
      return await current.systemOne(state, questions, { signal: deadline });
    } catch (error) {
      if (!fallback || deadline.aborted || error?.name === 'QuestionValidationError') throw error;
      directFailure = `${line(error?.message)}; used OpenRouter`;
      [current, fallback] = [fallback, null];
      return current.systemOne(state, questions, { signal: deadline });
    }
  };
  try {
    // Request 1: rank the whole roster, and score whether a skill applies.
    // One Choice holds at most 255 options, so a larger roster is split into
    // chunks ranked in the same request, as the cookbook advises.
    const wideQuestions = {};
    const chunks = Math.ceil(skills.length / LIMITS.MAX_CHOICE_OPTIONS);
    for (let i = 0; i < chunks; i++) {
      const part = skills.slice(i * LIMITS.MAX_CHOICE_OPTIONS, (i + 1) * LIMITS.MAX_CHOICE_OPTIONS);
      wideQuestions[chunks === 1 ? 'which' : `which::${i + 1}`] =
        choice(CHOICE_INSTRUCTIONS, Object.fromEntries(part.map((skill) => [skill.name, skill.description])));
    }
    for (const [key, text] of Object.entries(GATE_QUESTIONS)) wideQuestions[`gate::${key}`] = noul(text);
    const wide = await ask(wideQuestions);
    const ranked = Object.entries(wide.answers)
      .filter(([key]) => key.startsWith('which'))
      .flatMap(([, answer]) => Object.entries(answer.probabilities))
      .sort((a, b) => b[1] - a[1]);
    const oriented = Object.keys(GATE_QUESTIONS).map((key) => {
      const value = wide.answers[`gate::${key}`].noul;
      return INVERTED.has(key) ? 1 - value : value;
    });
    const gate = oriented.reduce((sum, value) => sum + value, 0) / oriented.length;
    Object.assign(out, { provider: current.provider, model: wide.meta.resolvedModel });
    if (gate < GATE_THRESHOLD) {
      Object.assign(out, { status: 'none', reason: `need ${gate.toFixed(2)} below ${GATE_THRESHOLD}` });
      return done();
    }
    // Request 2: the same Choice over the shortlist, plus one fits noul each.
    const shortlist = ranked.slice(0, SHORTLIST).map(([name]) => byName.get(name));
    const rerankQuestions = {
      which: choice(RERANK_INSTRUCTIONS, Object.fromEntries(shortlist.map((skill) =>
        [skill.name, `${skill.description} — ${skill.excerpt}`]))),
    };
    for (const skill of shortlist) {
      rerankQuestions[`fits::${skill.name}`] = noul(
        `Does the skill '${skill.name}' do the specific thing the user's request asks ` +
        `for? It is described as: ${skill.description}`,
      );
    }
    const result = await ask(rerankQuestions);
    const best = Math.max(...shortlist.map((skill) => result.answers[`fits::${skill.name}`].noul));
    Object.assign(out, { provider: current.provider, model: result.meta.resolvedModel });
    if (best < FITS_THRESHOLD) {
      Object.assign(out, { status: 'none', reason: `best fit ${best.toFixed(2)} below ${FITS_THRESHOLD}` });
      return done();
    }
    const winner = byName.get(result.answers.which.choice);
    Object.assign(out, {
      status: 'picked', picked: winner.name, path: winner.path,
      fit: result.answers[`fits::${winner.name}`].noul.toFixed(2),
    });
  } catch (error) {
    out.reason = deadline.aborted ? `no answer within ${RUN_DEADLINE_MS / 1000}s` : line(error?.message);
  }
  if (directFailure) out.reason = [out.reason, `TypeSafe direct failed (${directFailure})`].filter(Boolean).join('; ');
  return done();
}

const [command, ...args] = process.argv.slice(2);
if (command === 'roster' && args.length) process.stdout.write(`${JSON.stringify(roster(args))}\n`);
else if (command === 'pick' && args.length === 2) await pick(...args);
else {
  process.stderr.write('usage: fm-skill-pick.mjs roster <catalog-dir>... | pick <task-file> <roster.json> < keys\n');
  process.exit(2);
}
