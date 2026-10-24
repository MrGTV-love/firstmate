#!/usr/bin/env bash
# Offline T3 acceptance through installed task hooks and both write adapters.
set -u
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-secrets)
fm_git_identity 'Credential Tests' 'fixture@example.invalid'
with_hooks_env() {
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}
make_repo() { fm_git_init_commit "$1"; }

test_credentials_are_checked_at_commit_and_push() {
  local repo remote hooks out before keep=${1:-0}
  repo="$TMP_ROOT/secrets-$keep"
  remote="$TMP_ROOT/secrets-remote-$keep.git"
  hooks="$TMP_ROOT/hooks-secrets-$keep"
  make_repo "$repo"
  git init -q --bare "$remote"
  git -C "$repo" remote add origin "$remote"
  git -C "$repo" push -q origin HEAD:refs/heads/main
  "$STRIP" install "$hooks" "$repo" "$keep" || fail "install failed"
  before=$(git -C "$repo" rev-parse HEAD)
  # Synthetic shape assembled at runtime; never print the fixture value.
  printf 'ghp_%036d\n' 0 >"$repo/credential.txt"
  git -C "$repo" add credential.txt
  out=$(with_hooks_env "$hooks" git -C "$repo" commit -qm 'must refuse credential' 2>&1) &&
    fail "T3(a): a staged GitHub token was committed"
  assert_contains "$out" credential.txt "T3(a): refusal did not name the file"
  assert_not_contains "$out" "ghp_" "credential value leaked in refusal"
  assert_equals "$before" "$(git -C "$repo" rev-parse HEAD)" "refused commit moved HEAD"
  # The index, not the edited working copy, must be inspected.
  printf 'replace-me\n' >"$repo/credential.txt"
  out=$(with_hooks_env "$hooks" git -C "$repo" commit -qm 'must still refuse staged credential' 2>&1) &&
    fail "scanner inspected the worktree rather than the index"
  git -C "$repo" add credential.txt
  with_hooks_env "$hooks" git -C "$repo" commit -qm 'placeholder' || fail "T3(c): placeholder did not commit"
  assert_equals replace-me "$(git -C "$repo" show HEAD:credential.txt)" "placeholder missing from commit"
  printf '.env\n' >"$repo/.gitignore"
  git -C "$repo" add .gitignore
  with_hooks_env "$hooks" git -C "$repo" commit -qm 'ignore local environment' || fail "ignore setup failed"
  before=$(git -C "$repo" rev-parse HEAD)
  printf 'ghp_%036d\n' 0 >"$repo/.env"
  git -C "$repo" add -A
  assert_equals '' "$(git -C "$repo" diff --cached --name-only)" "T3(b): ignored secret entered the index"
  with_hooks_env "$hooks" git -C "$repo" commit -qm 'nothing staged' >/dev/null 2>&1 &&
    fail "T3(b): ignored .env created a commit"
  assert_equals "$before" "$(git -C "$repo" rev-parse HEAD)" "T3(b): ignored write moved HEAD"
  cat >"$repo/.git/hooks/pre-push" <<'SH'
#!/usr/bin/env bash
cat >.git/pre-push-input
SH
  chmod +x "$repo/.git/hooks/pre-push"
  with_hooks_env "$hooks" git -C "$repo" push -q origin HEAD:refs/heads/main || fail "placeholder push failed"
  assert_contains "$(cat "$repo/.git/pre-push-input")" "HEAD $before refs/heads/main" "repository hook lost its original pre-push records"
  git -C "$repo" add -f .env
  out=$(with_hooks_env "$hooks" git -C "$repo" commit -qm 'force added local credential' 2>&1) &&
    fail "force-adding an ignored secret escaped the commit check"
  assert_contains "$out" .env "force-added ignored file was not named"
  git -C "$repo" restore --staged .env
  # A commit made outside the fleet hooks must still be caught at push, even
  # when a later commit removes the secret and the staging area is empty.
  printf 'ghp_%036d\n' 0 >"$repo/credential.txt"
  git -C "$repo" add credential.txt
  git -C "$repo" commit -qm 'unscanned credential'
  printf 'replace-me\n' >"$repo/credential.txt"
  git -C "$repo" add credential.txt
  git -C "$repo" commit -qm 'remove credential at tip'
  out=$(with_hooks_env "$hooks" git -C "$repo" push -q origin HEAD:refs/heads/main 2>&1) &&
    fail "pre-push missed a credential in an outgoing ancestor"
  assert_contains "$out" credential.txt "pre-push refusal did not name the file"
  assert_not_contains "$out" "ghp_" "credential value leaked at push"
  assert_equals "$before" "$(git -C "$remote" rev-parse refs/heads/main)" "refused push changed remote"
  out=$(with_hooks_env "$hooks" git -C "$repo" push -q origin HEAD:refs/heads/new-branch 2>&1) &&
    fail "a new branch escaped outgoing-history inspection"
  assert_contains "$out" credential.txt "new-branch refusal did not name the file"
  with_hooks_env "$hooks" git -C "$repo" push -q origin :refs/heads/main || fail "ref deletion was treated as new content"
  pass "T3(a-c): staged credential refuses by filename, ignored .env commits nothing, placeholders commit and push; outgoing history is checked"
}

test_project_pre_commit_changes_are_scanned() {
  local repo hooks before out status
  repo="$TMP_ROOT/project-stages-secret"
  hooks="$TMP_ROOT/hooks-project-stages-secret"
  make_repo "$repo"
  "$STRIP" install "$hooks" "$repo" || fail "install failed"
  before=$(git -C "$repo" rev-parse HEAD)
  cat >"$repo/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
printf 'ghp_%036d\n' 0 >hook-staged.txt
git add hook-staged.txt
SH
  chmod +x "$repo/.git/hooks/pre-commit"
  printf 'benign initial change\n' >>"$repo/README.md"
  git -C "$repo" add README.md
  out=$(with_hooks_env "$hooks" git -C "$repo" commit -qm 'project hook stages credential' 2>&1) &&
    fail "a chained project pre-commit hook staged a credential after inspection"
  assert_contains "$out" hook-staged.txt "post-project-hook credential refusal did not name the file"
  assert_not_contains "$out" "ghp_" "post-project-hook refusal printed matching bytes"
  assert_equals "$before" "$(git -C "$repo" rev-parse HEAD)" "project hook credential reached a commit"
  git -C "$repo" ls-files --error-unmatch hook-staged.txt >/dev/null || fail "project hook never staged its credential"
  # A project-hook refusal must propagate before the scanner runs, even while
  # the index still contains the synthetic credential from the first case.
  printf '#!/usr/bin/env bash\nexit 17\n' >"$repo/.git/hooks/pre-commit"
  (cd "$repo" && with_hooks_env "$hooks" "$hooks/pre-commit") >/dev/null 2>&1
  status=$?
  expect_code 17 "$status" "task wrapper lost the project hook failure status"
  pass "project pre-commit staging is scanned before commit, and project-hook failure propagates"
}

test_project_pre_commit_changes_are_scanned
test_credentials_are_checked_at_commit_and_push 0
test_credentials_are_checked_at_commit_and_push 1

export T3_ROOT="$ROOT" T3_TMP="$TMP_ROOT"
node --experimental-strip-types --no-warnings --input-type=module <<'JS' || fail 'T3 native write acceptance'
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
const root = process.env.T3_ROOT;
const home = `${process.env.T3_TMP}/native-home`;
for (const dir of ['config', 'state', 'data']) mkdirSync(`${home}/${dir}`, { recursive: true });
const { installJevGuard } = await import(pathToFileURL(`${root}/bin/fm-jev-guard.ts`));
let requests = 0;
globalThis.fetch = async () => { requests++; throw new Error('no provider permitted'); };
const secret = 'ghp_' + '0'.repeat(36);
const report = 'Measured observations in an ordinary report.\n'.repeat(10000).slice(0, 396924);
assert.equal(Buffer.byteLength(report), 396924);
for (const host of ['omp', 'claude']) {
  const wt = `${home}/${host}`;
  mkdirSync(wt);
  const git = (...args) => execFileSync('git', ['-C', wt, ...args], { encoding: 'utf8' });
  git('init', '-q');
  writeFileSync(`${wt}/.gitignore`, '.env\n');
  git('add', '.gitignore');
  git('commit', '-qm', 'base');
  const before = git('rev-parse', 'HEAD');
  const context = { home, config: `${home}/config`, state: `${home}/state`, task: host,
    data: `${home}/data`, worktree: wt, project: 'firstmate', policy: 'FIRSTMATE_JEV_GUARD_V1' };
  const handlers = {};
  installJevGuard({ on(name, handler) { handlers[name] = handler; } }, context);
  async function admit(path, content, tool = 'write') {
    if (host === 'omp') {
      assert.equal(await handlers.tool_call({ toolName: tool, input: { path, content, new_string: content } }, { cwd: wt }), undefined);
    } else {
      const out = execFileSync(`${root}/bin/fm-jev-guard-hook.sh`, [home, context.config, context.state, host,
        wt, context.data, 'firstmate', context.policy], { encoding: 'utf8', input: JSON.stringify({
          hook_event_name: 'PreToolUse', cwd: wt, tool_name: tool === 'write' ? 'Write' : 'Edit',
          tool_input: { file_path: path, content, old_string: '', new_string: content },
        }) });
      assert.equal(out, '', 'native write/edit must not require model credentials');
    }
  }
  await admit(`${wt}/.env`, secret);
  writeFileSync(`${wt}/.env`, secret);
  git('add', '-A');
  assert.equal(git('diff', '--cached', '--name-only'), '', 'T3(b): ignored write stages nothing');
  assert.equal(git('rev-parse', 'HEAD'), before);
  await admit(`${wt}/report.md`, report);
  writeFileSync(`${wt}/report.md`, report);
  await admit(`${wt}/report.md`, report, 'edit');
  // Privacy text cannot become egress when there is no write-content model call.
  writeFileSync(`${home}/config/dispatch-never-send`, 'Measured observations\n');
  await admit(`${wt}/report.md`, report);
  const hooks = `${home}/${host}-hooks`;
  execFileSync(`${root}/bin/fm-git-strip-ai-trailers.sh`, ['install', hooks, wt]);
  git('add', 'report.md');
  git('-c', `core.hooksPath=${hooks}`, 'commit', '-qm', 'report');
  assert.equal(Buffer.byteLength(git('show', 'HEAD:report.md')), 396924, 'T3(d): complete report committed');
  assert.equal(readFileSync(`${wt}/.env`, 'utf8'), secret);
  console.log(`${host}: ignored .env write stages nothing; wrote and committed 396924-byte report; no provider needed`);
}
assert.equal(requests, 0, 'writes must not call a model provider');
// Preserve the old conservative shape boundaries at their new commit boundary,
// including binary blobs and names that cannot be parsed line by line.
const wt = `${home}/shapes`;
mkdirSync(wt);
const hooks = `${home}/shapes-hooks`;
const git = (...args) => execFileSync('git', ['-C', wt, ...args], { encoding: 'utf8' });
git('init', '-q');
execFileSync(`${root}/bin/fm-git-strip-ai-trailers.sh`, ['install', hooks, wt]);
const { spawnSync } = await import('node:child_process');
const values = [
  '-----BEGIN ' + 'PRIVATE KEY-----', '-----BEGIN PGP ' + 'PRIVATE KEY BLOCK-----',
  'ghp_' + '0'.repeat(36), 'github_pat_' + '0'.repeat(30),
  'AKIA' + 'Z'.repeat(16), 'xoxb-' + '0'.repeat(24),
  'postgres://fixture:' + '0'.repeat(12) + '@localhost/db',
  'redis://:' + '0'.repeat(12) + '@localhost/db',
];
const filename = 'shape fixture\nwith newline.bin';
for (const value of values) {
  writeFileSync(`${wt}/${filename}`, Buffer.concat([Buffer.from([0]), Buffer.from(value)]));
  git('add', filename);
  const commit = spawnSync('git', ['-C', wt, '-c', `core.hooksPath=${hooks}`, 'commit', '-qm', 'shape'], { encoding: 'utf8' });
  assert.equal(commit.status, 1, 'a retained credential shape must refuse at commit');
  assert.ok((commit.stdout + commit.stderr).includes('shape fixture\\nwith newline.bin'));
  assert.equal((commit.stdout + commit.stderr).includes(value), false, 'refusal cannot print matching bytes');
}
const benign = [
  'ordinary-word-'.repeat(100000), 'prefix-ghp_' + '0'.repeat(36),
  'http://localhost:3000?email=foo@bar.com',
  '{"endpoint":"http://localhost:3000","owner":"alice@example.com"}',
  'replace-me',
].join('\n');
writeFileSync(`${wt}/${filename}`, benign);
git('add', filename);
git('-c', `core.hooksPath=${hooks}`, 'commit', '-qm', 'benign prose');
writeFileSync(`${wt}/${filename}`, benign + '\n---.+postgres://fixture:' + '0'.repeat(12) + '@localhost/db');
git('add', filename);
const punctuation = spawnSync('git', ['-C', wt, '-c', `core.hooksPath=${hooks}`, 'commit', '-qm', 'URL after punctuation'], { encoding: 'utf8' });
assert.equal(punctuation.status, 1, 'punctuation-led credential URL must refuse after long hyphenated prose');
console.log('credential shapes: complete binary blobs, newline names, anchored prefixes and URL boundaries checked at commit');
JS
pass 'T3(b,d): both native write adapters admit ignored credentials and the 396924-byte report without a provider'

