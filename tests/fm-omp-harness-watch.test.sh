#!/usr/bin/env bash
# tests/fm-omp-harness-watch.test.sh - omp harness regressions (watch extension, supervision host handbacks, and lifecycle deadlines).
set -u

# shellcheck source=tests/fm-omp-harness-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-omp-harness-helpers.sh"

# A host close that is not an operational hand-back is a queue-read mark: its
# headline comes only from a queued row. With nothing queued, a park boundary
# sends nothing, while a diagnostic line is delivered with the fixed pointer.
# The away note is never stored in the mark: it is added when the wake is
# sent, only while the away record exists.
test_watch_extension_marks_host_closes_without_headlines() {  # <boundary|note|archived|diagnostic|restore-boundary|restore-diagnostic>
  local kind=${1:-boundary} repo home log out status
  repo="$TMP_ROOT/watch-host-mark-$kind/repo"; home="$TMP_ROOT/watch-host-mark-$kind/home"; log="$TMP_ROOT/watch-host-mark-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  case "$kind" in note|archived|diagnostic) : > "$home/state/.afk-contract" ;; esac
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
count=$(grep -c '^host=' "$FM_ARM_LOG")
boundary='supervision-host: cycle boundary - the park ended with nothing for main'
diagnostic='supervision-host: the away session could not take this wake: fixture; this wake is yours'
case "$HOST_CLOSE_KIND:$count" in
  boundary:[123])
    sleep 1
    printf '%s\n' "$boundary"
    exit 0
    ;;
  diagnostic:1)
    sleep 1
    printf 'signal: close headline\n%s\n' "$diagnostic"
    exit 0
    ;;
  note:1|archived:1|restore-*:1)
    sleep 1
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
    fm_wake_append signal queued.status 'signal: durable queued row' || exit 1
    case "$HOST_CLOSE_KIND" in
      restore-boundary) printf '%s\n' "$boundary" ;;
      *) printf 'signal: close headline\n%s\n' "$diagnostic" ;;
    esac
    exit 0
    ;;
esac
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(HOST_CLOSE_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const handoff = `${state}/extensions/omp-primary-watch/session-replacement-actionable.json`;
const kind = process.env.HOST_CLOSE_KIND;
const restore = kind.startsWith("restore-");
const diagnostic = "supervision-host: the away session could not take this wake: fixture; this wake is yours";
const pointer = "FIRSTMATE WATCHER WAKE: check: wake may be due";
const away = "not from the captain: it is not a return";
const handlers = new Map(); let tool = null; const sent = []; let editor = "";
let idle = kind !== "archived";
const ctx = { hasUI: true, isIdle: () => idle, hasPendingMessages: () => false,
  ui: { getEditorText: () => editor, setEditorText: (value) => { editor = value; } } };
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    sent.push({ m, o });
    if (restore && sent.length === 1) return undefined;
    handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
    return undefined;
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, ctx);
await tool.execute();
const hosts = () => (existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8") : "").trim().split("\n").filter((row) => row.startsWith("host="));
const wanted = kind === "boundary" ? 4 : 2;
const expected = { boundary: 0, note: 1, archived: 1, diagnostic: 1, "restore-boundary": 1, "restore-diagnostic": 2 }[kind];
const until = async (predicate) => { for (let i = 0; i < 150 && !predicate(); i += 1) await new Promise((r) => setTimeout(r, 100)); };
if (kind === "archived") {
  await until(() => hosts().length >= 2 && existsSync(`${state}/.wake-queue`));
  await new Promise((r) => setTimeout(r, 1500));
  if (sent.length !== 0) throw new Error(`a watcher wake was sent into a busy turn: ${JSON.stringify(sent)}`);
  rmSync(`${state}/.afk-contract`);
  idle = true;
  await handlers.get("agent_end")({}, ctx);
}
if (restore) {
  await until(() => sent.length === 1);
  if (sent.length !== 1 || !sent[0].m.includes("FIRSTMATE WATCHER WAKE: signal: durable queued row")) throw new Error(`the queued row was not delivered first: ${JSON.stringify(sent)}`);
  writeFileSync(`${state}/.wake-queue`, "");
  editor = sent[0].m;
  await until(() => editor === "");
  if (editor !== "") throw new Error("the restored wake text was not removed");
}
await until(() => hosts().length >= wanted && sent.length >= expected && !existsSync(handoff));
await new Promise((r) => setTimeout(r, 1500));
if (hosts().length !== wanted) throw new Error(`expected ${wanted} host parks, saw ${hosts().length}: ${JSON.stringify(sent)}`);
if (sent.length !== expected) throw new Error(`expected ${expected} injected wakes for ${kind}, saw ${sent.length}: ${JSON.stringify(sent)}`);
if (sent.some(({ m, o }) => m.includes("signal: close headline") || m.includes("FAILED") || o?.deliverAs !== undefined)) throw new Error(`a close headline, failure, or follow-up was injected: ${JSON.stringify(sent)}`);
if (kind === "note" || kind === "archived") {
  if (!sent[0].m.includes("FIRSTMATE WATCHER WAKE: signal: durable queued row") || !sent[0].m.includes(diagnostic)) throw new Error(`the queue-read wake lost its row or host explanation: ${sent[0].m}`);
  if (kind === "note" && !sent[0].m.includes(away)) throw new Error(`a host mark under an away record lost the away note: ${sent[0].m}`);
  if (kind === "archived" && sent[0].m.includes(away)) throw new Error(`the away note outlived the archived away record: ${sent[0].m}`);
}
if (kind === "diagnostic" || kind === "restore-diagnostic") {
  const last = sent[sent.length - 1].m;
  if (!last.includes(pointer) || !last.includes(diagnostic)) throw new Error(`an empty queue dropped the host explanation: ${last}`);
  if (kind === "diagnostic" && !last.includes(away)) throw new Error(`the empty-queue mark lost the away note: ${last}`);
}
if (existsSync(handoff)) throw new Error("a settled host close retained its handoff");
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension host close mark ($kind): $out"
  [ -z "$out" ] || fail "omp watch extension host close mark test printed output ($kind): $out"
  pass ".omp watch extension: a non-operational host close is a queue-read mark, never a failure or a headline ($kind)"
}

# Marks held through one busy turn merge their host lines into the one wake
# that is sent. When that wake is not consumed and is delivered again, the
# surviving mark still carries every line, with or without a queued row.
test_watch_extension_redelivers_merged_host_notes() {  # <rows|empty>
  local kind=${1:-rows} repo home log out status
  repo="$TMP_ROOT/watch-host-redeliver-$kind/repo"; home="$TMP_ROOT/watch-host-redeliver-$kind/home"; log="$TMP_ROOT/watch-host-redeliver-$kind/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
case "$(grep -c '^host=' "$FM_ARM_LOG")" in
  1)
    sleep 1
    if [ "$REDELIVER_KIND" = rows ]; then
      . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
      fm_wake_append signal queued.status 'signal: durable queued row' || exit 1
    fi
    printf 'supervision-host: cycle boundary - the park ended with nothing for main\n'
    exit 0
    ;;
  2)
    sleep 1
    printf 'supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you\n'
    exit 0
    ;;
esac
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(REDELIVER_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const diagnostic = "supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you";
const headline = process.env.REDELIVER_KIND === "rows" ? "FIRSTMATE WATCHER WAKE: signal: durable queued row" : "FIRSTMATE WATCHER WAKE: check: wake may be due";
const handlers = new Map(); let tool = null; const sent = [];
let idle = false;
const ctx = { isIdle: () => idle, hasPendingMessages: () => false };
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) { sent.push({ m, o }); return undefined; },
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (predicate) => { for (let i = 0; i < 150 && !predicate(); i += 1) await sleep(100); };
const hosts = () => (existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8") : "").trim().split("\n").filter((row) => row.startsWith("host="));
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("before_agent_start")({}, ctx);
await tool.execute();
await until(() => hosts().length >= 3);
await sleep(1500);
if (hosts().length !== 3 || sent.length !== 0) throw new Error(`expected two held host closes during the busy turn: ${hosts().length} ${JSON.stringify(sent)}`);
idle = true;
await handlers.get("agent_end")({}, ctx);
await until(() => sent.length >= 1);
if (sent.length !== 1 || !sent[0].m.includes(headline) || !sent[0].m.includes(diagnostic)) throw new Error(`the merged wake lost its headline or host line: ${JSON.stringify(sent)}`);
idle = false;
await handlers.get("before_agent_start")({ prompt: sent[0].m }, ctx);
idle = true;
await until(() => sent.length >= 2);
if (sent.length !== 2) throw new Error(`an unconsumed merged wake was not delivered again: ${JSON.stringify(sent)}`);
if (!sent[1].m.includes(headline) || !sent[1].m.includes(diagnostic)) throw new Error(`the redelivered wake lost a merged host line: ${sent[1].m}`);
await handlers.get("message_start")({ message: { role: "user", content: sent[1].m } }, ctx);
await sleep(1500);
if (sent.length !== 2) throw new Error(`a consumed wake was delivered again: ${JSON.stringify(sent)}`);
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension merged host note redelivery ($kind): $out"
  [ -z "$out" ] || fail "omp watch extension merged host note redelivery printed output ($kind): $out"
  pass ".omp watch extension: a redelivered merged wake keeps every host line ($kind)"
}

# The replacement handoff follows the same empty-queue rule: stored marks merge
# into one, a diagnostic line is delivered with the fixed pointer, and a mark
# with only the cycle-boundary line is cleared without a send. A stored away
# note is never replayed: the note is decided when the wake is sent.
test_watch_extension_replays_host_marks_from_the_handoff() {  # <diagnostic|boundary>
  local kind=${1:-diagnostic} repo home out status
  repo="$TMP_ROOT/watch-host-mark-handoff-$kind/repo"; home="$TMP_ROOT/watch-host-mark-handoff-$kind/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(HOST_CLOSE_KIND="$kind" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const dir = `${state}/extensions/omp-primary-watch`;
const handoff = `${dir}/session-replacement-actionable.json`;
mkdirSync(dir, { recursive: true });
const boundary = "supervision-host: cycle boundary - the park ended with nothing for main";
const diagnostic = "supervision-host: watcher downtime could not be restored for the main hand-back";
const away = "This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.";
const messages = process.env.HOST_CLOSE_KIND === "boundary"
  ? [`check: wake may be due\n${boundary}`, "check: wake may be due"]
  : [`check: wake may be due\n${boundary}`, `check: wake may be due\n${diagnostic}\n${away}`];
writeFileSync(handoff, JSON.stringify({ version: 2, pending: messages.map((message, i) => ({
  version: 1, token: `1-1-${i + 1}`, message, predecessorArmPid: "",
})) }));
const handlers = new Map(); const sent = [];
const ctx = { isIdle: () => true };
const pi = {
  on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) {
    sent.push({ m, o });
    handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
  },
};
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
for (let i = 0; i < 100 && existsSync(handoff); i += 1) await new Promise((r) => setTimeout(r, 50));
await new Promise((r) => setTimeout(r, 1500));
if (existsSync(handoff)) throw new Error(`the handoff kept a settled mark: ${JSON.stringify(sent)}`);
if (process.env.HOST_CLOSE_KIND === "boundary") {
  if (sent.length !== 0) throw new Error(`a boundary-only handoff mark injected text with an empty queue: ${JSON.stringify(sent)}`);
} else {
  if (sent.length !== 1) throw new Error(`expected one wake for the merged handoff mark: ${JSON.stringify(sent)}`);
  for (const needle of ["FIRSTMATE WATCHER WAKE: check: wake may be due", boundary, diagnostic]) {
    if (!sent[0].m.includes(needle)) throw new Error(`the handoff mark lost '${needle}': ${sent[0].m}`);
  }
  if (sent[0].m.includes(away)) throw new Error(`a stored away note was replayed without an away record: ${sent[0].m}`);
}
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp host mark handoff ($kind): $out"
  [ -z "$out" ] || fail "omp host mark handoff test printed output ($kind): $out"
  pass ".omp watch extension: a handoff host mark follows the empty-queue rule ($kind)"
}

test_watch_extension_migrates_legacy_handoffs() {
  local repo home out status
  repo="$TMP_ROOT/watch-legacy-handoff/repo"; home="$TMP_ROOT/watch-legacy-handoff/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
exec sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, mkdirSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
const dir = `${state}/extensions/omp-primary-watch`;
const handoff = `${dir}/session-replacement-actionable.json`;
mkdirSync(dir, { recursive: true });
writeFileSync(`${state}/.wake-queue`, "1\t1\tcheck\tnew\tcheck: current queued work\n");
const messages = [
  "supervision-host: branch-outcome: captain outcomes (store rows 1)",
  "signal: handled original\nsupervision-host: the captain returned while the away session was handling this wake; relay its visible outcomes",
  "signal: legacy uncorrelated",
  "FIRSTMATE SUPERVISION HOST: check: legacy wrapped uncorrelated",
  "FIRSTMATE SUPERVISION HOST: check: still queued\nwake-seq: 1",
];
writeFileSync(handoff, JSON.stringify({ version: 2, pending: messages.map((message, i) => ({
  version: 1, token: `1-1-${i + 1}`, message, predecessorArmPid: "",
})) }));
const handlers = new Map(); const sent = [];
const ctx = { isIdle: () => true };
const pi = {
  on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {},
  sendUserMessage(m, o) {
    sent.push({ m, o });
    if (m.includes("FIRSTMATE WATCHER WAKE:")) writeFileSync(`${state}/.wake-queue`, "");
    handlers.get("message_start")({ message: { role: "user", content: m } }, ctx);
  },
};
(await import(pathToFileURL(process.env.EXT).href)).default(pi);
await handlers.get("session_start")({}, ctx);
for (let i = 0; i < 100 && (sent.length < 3 || existsSync(handoff)); i += 1) await new Promise((r) => setTimeout(r, 50));
if (sent.length !== 3 || sent.some(({ m }) => m.includes("FAILED") || m.includes("uncorrelated") || m.includes("still queued") || m.includes("handled original"))) throw new Error(`legacy migration failed: ${JSON.stringify(sent)}`);
for (const expected of ["branch-outcome:", "the captain returned", "check: current queued work"]) {
  if (!sent.some(({ m }) => m.includes(expected))) throw new Error(`migration lost ${expected}`);
}
const watcher = sent.find(({ m }) => m.includes("check: current queued work"));
if (!watcher.m.includes("FIRSTMATE WATCHER WAKE:") || watcher.m.includes("FIRSTMATE SUPERVISION HOST:")) throw new Error("legacy host wrapper retained its watcher exemption");
if (existsSync(handoff)) throw new Error("migration retained consumed or retired records");
await handlers.get("session_shutdown")({}, ctx);
await handlers.get("session_start")({}, ctx);
await new Promise((r) => setTimeout(r, 100));
if (sent.length !== 3) throw new Error("legacy records replayed after migration");
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp legacy handoff migration: $out"
  [ -z "$out" ] || fail "omp legacy handoff migration printed output: $out"
  pass ".omp watch extension: legacy operational handoffs load and watcher records collapse into a queue-read mark"
}

# A host whose exit reaches the extension in separate stream chunks is
# delivered once at its close: a successor host whose status and signal lines
# land while the previous wake is still being delivered, with its outcome lines
# after a pause, reaches main as one follow-up carrying both.
test_watch_extension_delivers_a_split_host_close_whole() {
  local repo home log out status
  repo="$TMP_ROOT/watch-host-split/repo"; home="$TMP_ROOT/watch-host-split/home"; log="$TMP_ROOT/watch-host-split/arm.log"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/supervision-host"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
exit 1
SH
  cat > "$repo/bin/fm-supervision-host.sh" <<'SH'
#!/usr/bin/env bash
printf 'host=%s\n' "$$" >> "${FM_ARM_LOG:?}"
started="watcher: started pid=$$ (beacon fresh) recovery-generation=gen-$$"
case "$(grep -c '^host=' "$FM_ARM_LOG")" in
  1)
    printf '%s\n' "$started"
    sleep 1
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
    fm_wake_append signal first 'signal: omp-host first' || exit 1
    printf 'signal: omp-host first\n'
    exit 0
    ;;
  2)
    printf '%s\nsignal: omp-host second\n' "$started"
    sleep 1
    node --input-type=module <<'JS'
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
for (const [stream, label] of [[process.stdout, "stdout"], [process.stderr, "stderr"]]) {
  const bytes = Buffer.from(`supervision-host: outcome 2 for demo [captain]: fixture split ${label} 船😀\n`);
  const cut = bytes.indexOf(Buffer.from("船")) + 1;
  stream.write(bytes.subarray(0, cut));
  await sleep(100);
  stream.write(bytes.subarray(cut));
}
JS
    exit 0
    ;;
esac
printf '%s\n' "$started"
sleep 30
SH
  chmod +x "$repo/bin/fm-watch-arm.sh" "$repo/bin/fm-supervision-host.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(m, o) {
    sent.push({ m, o });
    handlers.get("message_start")({ message: { role: "user", content: m } }, { isIdle: () => true });
    return undefined;
  },
};
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("before_agent_start")({}, { isIdle: () => true });
await tool.execute();
for (let i = 0; i < 80 && sent.length < 2; i += 1) await new Promise((r) => setTimeout(r, 100));
const second = sent.filter((item) => item.m.includes("outcome 2 for demo"));
if (second.length !== 1) throw new Error(`expected one follow-up for the split close, saw ${second.length}: ${JSON.stringify(sent)}`);
if (sent.some((item) => item.m.includes("signal: omp-host second"))) throw new Error(`the split close injected a headline with no queued row: ${JSON.stringify(sent)}`);
if (!second[0].m.includes("supervision-host: outcome 2 for demo [captain]: fixture split")) {
  throw new Error(`the split close was delivered without its outcome line: ${second[0].m}`);
}
for (const stream of ["stdout", "stderr"]) {
  if (!second[0].m.includes(`fixture split ${stream} 船😀`)) throw new Error(`host ${stream} UTF-8 was corrupted: ${second[0].m}`);
}
await handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension split host close: $out"
  [ -z "$out" ] || fail "omp watch extension split host close test printed output: $out"
  pass ".omp watch extension: a host close split across stream chunks reaches main as one whole follow-up"
}

test_task_session_proof_tracks_active_session() {
  local case_dir="$TMP_ROOT/task-session-proof" status
  mkdir -p "$case_dir/extension"
  cp "$ROOT/.omp/extensions/lib/fm-task-session.ts" "$case_dir/extension/"
  FM_PROOF_CASE="$case_dir" EXT="$case_dir/extension/fm-task-session.ts" node --input-type=module <<'EOF'
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync, realpathSync, mkdirSync, symlinkSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const { installTaskSessionProof } = await import(pathToFileURL(process.env.EXT).href);
const state = process.env.FM_PROOF_CASE;
const sessions = `${state}/sessions`, linkedSessions = `${state}/linked-sessions`;
mkdirSync(sessions);
symlinkSync(sessions, linkedSessions, "dir");
const task = `${linkedSessions}/task.jsonl`, personal = `${linkedSessions}/personal.jsonl`;
const canonicalTask = `${realpathSync(sessions)}/task.jsonl`;
writeFileSync(personal, "{}\n");
writeFileSync(`${state}/demo.meta`, "spawn_gen=proof-gen\n");
process.env.FM_SPAWN_GEN = "proof-gen";
const handlers = new Map(), warnings = [];
const pi = { pi: { AgentRegistry: { global() { return { list() { return globalThis.proofRefs; } }; } } }, on(event, handler) { handlers.set(event, handler); } };
installTaskSessionProof(pi, state, "demo");
let file = task;
const ctx = { agent: { kind: "main", id: "Main" }, sessionManager: { getSessionFile() { return file; } }, ui: { notify(message) { warnings.push(message); } } };
let transitionSettled = Promise.resolve();
globalThis.proofSession = { sessionManager: ctx.sessionManager, waitForSessionTransition() { globalThis.proofWaitStarted?.(); return transitionSettled; } };
globalThis.proofRefs = [{ kind: "sub", session: null }, { kind: "sub", session: { sessionManager: {} } }, { kind: "main", session: globalThis.proofSession }];
const flush = () => new Promise(resolve => setImmediate(resolve));
const start = (context = ctx) => handlers.get("session_start")({}, context);
const stop = () => handlers.get("session_shutdown")({}, ctx);
const beforeSwitch = () => handlers.get("session_before_switch")({ targetSessionFile: personal, reason: "resume" }, ctx);
const afterSwitch = () => handlers.get("session_switch")({ previousSessionFile: task, reason: "resume" }, ctx);
const record = () => JSON.parse(readFileSync(`${state}/demo.omp-session.json`, "utf8"));
const begin = (event, context = ctx) => {
  let settle, started;
  transitionSettled = new Promise(resolve => { settle = resolve; });
  const waiting = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`${event} did not await its transition owner`)), 5000);
    started = () => { clearTimeout(timeout); resolve(); };
  });
  globalThis.proofWaitStarted = started;
  handlers.get(event)({}, context);
  return { settle, waiting };
};
assert.equal(existsSync(task), false);
start();
assert.deepEqual(record(), { version: 1, spawn_gen: "proof-gen", pid: process.pid, task_session_file: canonicalTask, current_session_file: canonicalTask });
assert.equal(existsSync(task), false);
writeFileSync(task, "{}\n");
start();
assert.deepEqual(record(), { version: 1, spawn_gen: "proof-gen", pid: process.pid, task_session_file: realpathSync(task), current_session_file: realpathSync(task) });
const parentProof = record();
const events = ["session_start", "session_switch", "session_branch", "session_before_switch", "session_before_branch", "session_shutdown"];
for (const childFile of [personal, undefined]) {
  const manager = { getSessionFile() { return childFile; } };
  const childSession = { sessionManager: manager, waitForSessionTransition() { throw new Error("child transition must not be awaited"); } };
  for (const kind of ["sub", "advisor"]) {
    const ref = { kind, session: childSession };
    globalThis.proofRefs.push(ref);
    for (const childCtx of [{ agent: { kind }, sessionManager: manager, ui: ctx.ui }, { sessionManager: manager, ui: ctx.ui }]) {
      for (const event of events) {
        handlers.get(event)({}, childCtx);
        assert.deepEqual(record(), parentProof, `${event} from ${childFile ? "persisted" : "in-memory"} ${kind} must preserve parent proof`);
      }
    }
    globalThis.proofRefs.pop();
  }
  for (const event of events) {
    handlers.get(event)({}, { agent: { kind: "main" }, sessionManager: manager, ui: ctx.ui });
    assert.deepEqual(record(), parentProof, `${event} from an unregistered manager must preserve parent proof`);
  }
}
for (const context of [ctx, { sessionManager: ctx.sessionManager, ui: ctx.ui }]) {
  for (const event of ["session_before_switch", "session_before_branch"]) {
    for (const outcome of ["cancel", "rollback", "rollback-after-activation"]) {
      for (const predecessor of [task, personal]) {
        file = predecessor; start(context);
        const prior = record();
        const { settle, waiting } = begin(event, context);
        assert.equal(record().current_session_file, "");
        await waiting;
        assert.equal(record().current_session_file, "", `${event} must remain unproven while pending`);
        if (outcome !== "cancel") {
          file = predecessor === task ? personal : task;
          if (outcome === "rollback-after-activation") {
            handlers.get(event === "session_before_switch" ? "session_switch" : "session_branch")({}, context);
            assert.equal(record().current_session_file, realpathSync(file));
          }
          await flush();
          assert.equal(record().current_session_file, outcome === "rollback" ? "" : realpathSync(file));
          file = predecessor;
        }
        settle();
        await flush();
        assert.deepEqual(record(), prior, `${event} ${outcome} must restore only the settled predecessor`);
      }
    }
  }
}
file = task; start();
for (const event of ["session_before_switch", "session_before_branch"]) {
  let transition = begin(event);
  await transition.waiting;
  file = personal;
  transition.settle();
  await flush();
  assert.equal(record().current_session_file, "", `${event} must not restore after an unannounced identity change`);
  file = task; start();
  transition = begin(event);
  await transition.waiting;
  stop();
  transition.settle();
  await flush();
  assert.equal(record().current_session_file, "", `${event} must not restore after shutdown`);
  start();
}
transitionSettled = Promise.resolve();
stop();
assert.equal(record().current_session_file, "");
assert.equal(record().task_session_file, realpathSync(task));
file = task; start();
beforeSwitch();
assert.equal(record().current_session_file, "");
assert.equal(record().task_session_file, realpathSync(task));
file = personal; afterSwitch();
assert.equal(record().current_session_file, realpathSync(personal));
assert.equal(record().task_session_file, realpathSync(task));
// Reloading the extension in the personal session must not rebind the task.
installTaskSessionProof(pi, state, "demo"); start();
assert.equal(record().task_session_file, realpathSync(task));
handlers.get("session_before_branch")({}, ctx);
assert.equal(record().current_session_file, "");
file = task; handlers.get("session_branch")({ previousSessionFile: personal }, ctx);
assert.equal(record().current_session_file, record().task_session_file);
const originalWarn = console.warn; console.warn = () => {};
try {
  await flush();
  const registered = globalThis.proofRefs;
  for (const event of events) {
    for (const refs of [registered.slice(0, 2), [...registered, { kind: "main", session: globalThis.proofSession }]]) {
      start();
      const prior = record();
      globalThis.proofRefs = refs;
      const count = warnings.length;
      handlers.get(event)({}, { sessionManager: ctx.sessionManager, ui: ctx.ui });
      await flush();
      assert.deepEqual(record(), prior, `${event} without a unique registered owner must preserve parent proof`);
      assert.equal(warnings.length, count);
      globalThis.proofRefs = registered;
    }
  }
  for (const event of ["session_before_switch", "session_before_branch"]) {
    start();
    const transition = begin(event, { sessionManager: ctx.sessionManager, ui: ctx.ui });
    await transition.waiting;
    globalThis.proofRefs = registered.slice(0, 2);
    transition.settle();
    await flush();
    assert.equal(record().current_session_file, "", `${event} must not restore after its owner is unregistered`);
    globalThis.proofRefs = registered;
  }
  start();
  beforeSwitch();
  file = `${linkedSessions}/absent.jsonl`;
  afterSwitch();
  assert.equal(record().current_session_file, `${realpathSync(sessions)}/absent.jsonl`);
  assert.equal(record().task_session_file, realpathSync(task));
  assert.notEqual(record().current_session_file, record().task_session_file);
  assert.equal(existsSync(file), false);
  installTaskSessionProof(pi, state, "demo"); start();
  assert.equal(record().task_session_file, realpathSync(task));
  file = task; start();
  assert.equal(record().current_session_file, record().task_session_file);
  beforeSwitch();
  file = `${linkedSessions}/missing-parent/session.jsonl`;
  assert.throws(afterSwitch, { code: "ENOENT" });
  assert.equal(record().current_session_file, "");
  assert.equal(record().task_session_file, realpathSync(task));
  assert.ok(warnings.length);
  file = `${personal}/session.jsonl`;
  assert.throws(start, { code: "ENOTDIR" });
  assert.equal(record().current_session_file, "");
  assert.equal(record().task_session_file, realpathSync(task));
  writeFileSync(`${state}/demo.meta`, "spawn_gen=other-gen\n");
  file = task; assert.throws(start);
  assert.equal(record().current_session_file, "");
  writeFileSync(`${state}/wrong.meta`, "spawn_gen=other-gen\n");
  installTaskSessionProof(pi, state, "wrong");
  assert.throws(start);
  assert.equal(existsSync(`${state}/wrong.omp-session.json`), false);
  writeFileSync(`${state}/corrupt.meta`, "spawn_gen=proof-gen\n");
  writeFileSync(`${state}/corrupt.omp-session.json`, "{bad");
  installTaskSessionProof(pi, state, "corrupt");
  assert.throws(start);
  assert.equal(readFileSync(`${state}/corrupt.omp-session.json`, "utf8"), "{bad");
  // Relaunch replaces the old generation's binding before its JSONL exists.
  const replacement = `${linkedSessions}/replacement.jsonl`;
  const canonicalReplacement = `${realpathSync(sessions)}/replacement.jsonl`;
  writeFileSync(`${state}/demo.meta`, "spawn_gen=replacement-gen\n");
  const child = spawnSync(process.execPath, ["--input-type=module", "-"], {
    encoding: "utf8",
    env: { ...process.env, FM_SPAWN_GEN: "replacement-gen", FM_REPLACEMENT_FILE: replacement },
    input: `
      import assert from "node:assert/strict";
      import { existsSync, readFileSync, writeFileSync, realpathSync } from "node:fs";
      import { pathToFileURL } from "node:url";
      const { installTaskSessionProof } = await import(pathToFileURL(process.env.EXT).href);
      const state = process.env.FM_PROOF_CASE;
      const handlers = new Map();
      const pi = { pi: { AgentRegistry: { global() { return { list() { return globalThis.proofRefs; } }; } } }, on(event, handler) { handlers.set(event, handler); } };
      installTaskSessionProof(pi, state, "demo");
      let file = process.env.FM_REPLACEMENT_FILE;
      const ctx = { sessionManager: { getSessionFile() { return file; } } };
      globalThis.proofRefs = [{ kind: "main", session: { sessionManager: ctx.sessionManager, waitForSessionTransition() { return Promise.resolve(); } } }];
      const start = () => handlers.get("session_start")({}, ctx);
      const record = () => JSON.parse(readFileSync(state + "/demo.omp-session.json", "utf8"));
      const canonical = ${JSON.stringify(canonicalReplacement)};
      assert.equal(existsSync(file), false);
      start();
      const expected = { version: 1, spawn_gen: "replacement-gen", pid: process.pid, task_session_file: canonical, current_session_file: canonical };
      assert.deepEqual(record(), expected);
      assert.equal(existsSync(file), false);
      writeFileSync(file, "{}\\n");
      start();
      assert.deepEqual(record(), expected);
      file = ${JSON.stringify(personal)};
      start();
      assert.deepEqual(record(), { ...expected, current_session_file: realpathSync(file) });
      assert.notEqual(record().current_session_file, record().task_session_file);
      file = ${JSON.stringify(`${linkedSessions}/replacement-personal.jsonl`)};
      start();
      assert.equal(existsSync(file), false);
      assert.deepEqual(record(), { ...expected, current_session_file: ${JSON.stringify(`${realpathSync(sessions)}/replacement-personal.jsonl`)} });
      installTaskSessionProof(pi, state, "demo"); start();
      assert.equal(record().task_session_file, canonical);
      file = process.env.FM_REPLACEMENT_FILE; start();
      assert.deepEqual(record(), expected);
    `,
  });
  assert.equal(child.status, 0, child.stderr || child.error?.message);
  assert.notEqual(child.pid, process.pid);
  assert.deepEqual(record(), { version: 1, spawn_gen: "replacement-gen", pid: child.pid, task_session_file: canonicalReplacement, current_session_file: canonicalReplacement });
  delete process.env.FM_SPAWN_GEN;
  installTaskSessionProof(pi, state, "absent");
  start();
  assert.equal(existsSync(`${state}/absent.omp-session.json`), false);
} finally { console.warn = originalWarn; }
EOF
  status=$?
  expect_code 0 "$status" "omp task-session proof follows activation and fails closed"
  pass ".omp task-session proof: pending canonical binding survives persistence, personal resume, reload, return, and fresh-generation replacement"
}

test_watch_extension_queue_read_delivery() {
  local scenario out status
  for scenario in drained owed consumed release-consume mixed same-close handoff late-handoff external host-drained host-owed advisor-tail advisor-tail-draft outstanding-end dropped removed edited failure timeout slow slow-pending slow-turn slow-turn-new-row query-close unreadable utf8 restore-alone restore-after restore-before restore-edited restore-queued restore-busy restore-new-row restore-drained restore-end-owed restore-end-drained restore-end-new-row restore-end-queued stuck-watcher stuck-restored stuck-new-row stuck-drained stuck-failure stuck-restored-failure stuck-restored-failures stuck-restored-failures-turn stuck-restored-failure-held stuck-restored-failure-no-turn stuck-restored-failure-refused stuck-episodes stranded-owed stranded-unmarked stranded-drained stranded-draft-after stranded-draft-before stranded-two stranded-human stranded-busy stranded-settling stranded-bounded stranded-tracked; do
    out=$(run_watch_queue_read_scenario "$scenario")
    status=$?
    expect_code 0 "$status" "omp queue-read scenario $scenario: $out"
    [ -z "$out" ] || fail "omp queue-read scenario $scenario printed output: $out"
  done
  pass ".omp watch extension: one idle queue-read boundary covers partial acknowledgements, recovery, replacement, token release, failures and slow queries"
}

# Only the omp process that holds the session lock may record itself as the
# loaded session or arm a watcher. A descendant omp (an `omp -p` child a turn
# runs) auto-discovers the same extensions from the same directory; it used to
# overwrite the marker with its own pid, and its death left the dead pid in the
# marker, so the supervision proof read "not loaded" under a healthy session.
test_primary_extensions_ignore_a_descendant_session() {
  local repo home out status
  repo="$TMP_ROOT/descendant/repo"; home="$TMP_ROOT/descendant/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  # The session lock names this shell, an ancestor of the node process below.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    WATCH_EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" FM_SESSIONSTART_OFF=1 node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
writeFileSync(`${state}/.lock`, `${process.ppid}\n`);
const record = "sha256:parent-session-build\n" + process.ppid + "\n";
for (const marker of [".omp-turnend-extension-loaded", ".omp-watch-extension-loaded"]) writeFileSync(`${state}/${marker}`, record);
const load = async (file) => {
  const handlers = new Map(); let tool = null;
  const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage() {}, sendMessage() {} };
  (await import(pathToFileURL(file).href)).default(pi);
  return { handlers, tool };
};
const guard = await load(process.env.GUARD_EXT);
const watch = await load(process.env.WATCH_EXT);
const ctx = { sessionManager: { getSessionId: () => "child" } };
await guard.handlers.get("session_start")({ type: "session_start" }, ctx);
await watch.handlers.get("session_start")({ type: "session_start" }, ctx);
await guard.handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, ctx);
await watch.handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "x" }, ctx);
for (const marker of [".omp-turnend-extension-loaded", ".omp-watch-extension-loaded"]) {
  if (readFileSync(`${state}/${marker}`, "utf8") !== record) throw new Error(`a descendant session overwrote ${marker}: ${readFileSync(`${state}/${marker}`, "utf8")}`);
}
const arm = await watch.tool.execute();
if (!/read-only/.test(arm.content[0].text)) throw new Error(`a descendant session armed a watcher: ${arm.content[0].text}`);
if (existsSync(`${state}/.watch.lock`)) throw new Error("a descendant session took the watcher lock");
await watch.handlers.get("session_shutdown")({}, ctx);
await guard.handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "descendant omp session must not claim the home: $out"
  [ -z "$out" ] || fail "descendant omp session test printed output: $out"
  pass ".omp extensions: a descendant omp session neither records itself as the loaded session nor arms a watcher"
}

# A local secondmate's own omp records its task-session proof in the parent
# home. A descendant `omp -p` run from that home inherits the launch generation
# and loads the same watch extension, but it is not the lock-owning session.
test_secondmate_watch_proof_ignores_a_descendant_omp() {
  local repo home parent out status proof before
  repo="$TMP_ROOT/secondmate-descendant/repo"; home="$TMP_ROOT/secondmate-descendant/home"
  parent="$TMP_ROOT/secondmate-descendant/parent"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$parent/state" "$TMP_ROOT/secondmate-descendant/sessions"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'spawn_gen=secondmate-gen\n' > "$parent/state/sm.meta"
  : > "$TMP_ROOT/secondmate-descendant/sessions/task.jsonl"
  proof="$parent/state/sm.omp-session.json"
  jq -nc --argjson pid "$$" --arg task "$TMP_ROOT/secondmate-descendant/sessions/task.jsonl" \
    '{version:1,spawn_gen:"secondmate-gen",pid:$pid,task_session_file:$task,current_session_file:$task}' > "$proof"
  before=$(cat "$proof")
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" FM_SPAWN_GEN=secondmate-gen FM_SESSIONSTART_OFF=1 \
    WATCH_EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" CHILD_SESSION="$TMP_ROOT/secondmate-descendant/sessions/child.jsonl" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
writeFileSync(process.env.CHILD_SESSION, "{}\n");
const handlers = new Map();
const sessionManager = { getSessionId: () => "child", getSessionFile: () => process.env.CHILD_SESSION };
const registry = { list: () => [{ kind: "main", session: { sessionManager, waitForSessionTransition: () => Promise.resolve() } }] };
const pi = {
  on(event, handler) { (handlers.get(event) ?? handlers.set(event, []).get(event)).push(handler); },
  registerCommand() {}, registerTool() {}, sendUserMessage() {}, sendMessage() {},
  pi: { AgentRegistry: { global: () => registry } },
};
// The child loads while the home lock is still missing; the secondmate session
// itself (an ancestor of this process) claims it before the child session starts.
(await import(pathToFileURL(process.env.WATCH_EXT).href)).default(pi);
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.ppid}\n`);
const ctx = { sessionManager };
for (const event of ["session_start", "session_shutdown"]) {
  for (const handler of handlers.get(event) ?? []) await handler({ type: event }, ctx);
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "descendant omp of a local secondmate must load cleanly: $out"
  [ "$(cat "$proof")" = "$before" ] \
    || fail "a descendant omp rewrote its secondmate's task-session proof: $(cat "$proof")"
  pass ".omp extensions: a descendant omp neither rebinds nor clears its local secondmate's task-session proof"
}

# The secondmate's own omp must publish its proof whenever no ancestor holds the
# home lock: before it claims the lock, once it owns it, and after a reboot left
# the lock naming a pid an unrelated live process now has.
test_secondmate_watch_proof_publishes_for_the_secondmate_itself() {
  local repo home parent out status stranger lock_case
  repo="$TMP_ROOT/secondmate-self/repo"; home="$TMP_ROOT/secondmate-self/home"
  parent="$TMP_ROOT/secondmate-self/parent"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state" "$parent/state" "$TMP_ROOT/secondmate-self/sessions"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/bin/fm-watch-arm.sh"
  chmod +x "$repo/bin/fm-watch-arm.sh"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  printf 'sm\n' > "$home/.fm-secondmate-home"
  printf 'spawn_gen=secondmate-gen\n' > "$parent/state/sm.meta"
  sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS" >/dev/null 2>&1 &
  stranger=$!
  if ! fm_test_record_process "$TMP_ROOT/secondmate-self/stranger.process" "$stranger" \
    || ! fm_test_track_process "$TMP_ROOT/secondmate-self/stranger.process" "sleep $FM_TEST_STUB_MAX_BLOCK_SECONDS"; then
    kill "$stranger" 2>/dev/null; fail 'could not register the stranger lock holder'
  fi
  for lock_case in missing self stranger; do
    rm -f "$home/state/.lock" "$parent/state/sm.omp-session.json"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_DATA_OVERRIDE="$home/data" FM_SPAWN_GEN=secondmate-gen FM_SESSIONSTART_OFF=1 LOCK_CASE="$lock_case" STRANGER="$stranger" \
      WATCH_EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" SESSION="$TMP_ROOT/secondmate-self/sessions/$lock_case.jsonl" \
      PROOF="$parent/state/sm.omp-session.json" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { readFileSync, realpathSync, writeFileSync } from "node:fs";
const lock = `${process.env.FM_HOME}/state/.lock`;
if (process.env.LOCK_CASE === "self") writeFileSync(lock, `${process.pid}\n`);
if (process.env.LOCK_CASE === "stranger") writeFileSync(lock, `${process.env.STRANGER}\n`);
writeFileSync(process.env.SESSION, "{}\n");
const handlers = new Map();
const sessionManager = { getSessionId: () => "self", getSessionFile: () => process.env.SESSION };
const registry = { list: () => [{ kind: "main", session: { sessionManager, waitForSessionTransition: () => Promise.resolve() } }] };
const pi = {
  on(event, handler) { (handlers.get(event) ?? handlers.set(event, []).get(event)).push(handler); },
  registerCommand() {}, registerTool() {}, sendUserMessage() {}, sendMessage() {},
  pi: { AgentRegistry: { global: () => registry } },
};
(await import(pathToFileURL(process.env.WATCH_EXT).href)).default(pi);
const ctx = { sessionManager };
for (const handler of handlers.get("session_start") ?? []) await handler({ type: "session_start" }, ctx);
let proof;
try { proof = JSON.parse(readFileSync(process.env.PROOF, "utf8")); } catch (error) { throw new Error(`no task-session proof published: ${error.message}`); }
if (proof.pid !== process.pid || proof.spawn_gen !== "secondmate-gen" || proof.current_session_file !== realpathSync(process.env.SESSION)) {
  throw new Error(`task-session proof does not name this session: ${JSON.stringify(proof)}`);
}
process.exit(0);
EOF
)
    status=$?
    if [ "$status" -ne 0 ]; then
      kill "$stranger" 2>/dev/null
      expect_code 0 "$status" "a local secondmate with lock $lock_case must publish its task-session proof: $out"
    fi
  done
  kill "$stranger" 2>/dev/null
  wait "$stranger" 2>/dev/null
  pass ".omp extensions: a local secondmate publishes its task-session proof with the lock missing, its own, or naming an unrelated live pid"
}

# The turn-end guard used to record itself only while the extension loaded,
# before the session-start hook claimed the lock, so a lock that was foreign or
# absent at that moment left a marker naming a dead pid until the next restart.
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries() {
  local repo home out status
  repo="$TMP_ROOT/marker-heal/repo"; home="$TMP_ROOT/marker-heal/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 0
SH
  chmod +x "$repo/bin/fm-turnend-guard.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" GUARD_EXT="$repo/.omp/extensions/fm-primary-turnend-guard.ts" \
    node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawn } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const state = `${process.env.FM_HOME}/state`;
const marker = `${state}/.omp-turnend-extension-loaded`;
const pidOf = () => readFileSync(marker, "utf8").split("\n")[1];
// A live session that is not this process holds the lock while the extension loads.
const other = spawn("sleep", ["60"], { stdio: "ignore" });
writeFileSync(`${state}/.lock`, `${other.pid}\n`);
const handlers = new Map();
const pi = { on(e, h) { handlers.set(e, h); }, sendMessage() {} };
(await import(pathToFileURL(process.env.GUARD_EXT).href)).default(pi);
const ctx = { sessionManager: { getSessionId: () => "s1" } };
await handlers.get("session_start")({ type: "session_start" }, ctx);
if (existsSync(marker)) throw new Error("a foreign live lock holder must not be recorded as this session's marker");
// The session-start hook then claims the lock for this process.
writeFileSync(`${state}/.lock`, `${process.pid}\n`);
await handlers.get("before_agent_start")({ type: "before_agent_start", prompt: "hi" }, ctx);
if (pidOf() !== String(process.pid)) throw new Error(`the marker was not recorded once the lock was claimed: ${readFileSync(marker, "utf8")}`);
// A stale record (a dead build or pid) is repaired at the next turn boundary.
writeFileSync(marker, "sha256:stale\n999999\n");
await handlers.get("session_stop")({ type: "session_stop", stop_hook_active: true }, ctx);
if (pidOf() !== String(process.pid)) throw new Error(`the stale marker was not repaired at the turn boundary: ${readFileSync(marker, "utf8")}`);
other.kill();
await handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "turn-end marker self-repair: $out"
  [ -z "$out" ] || fail "turn-end marker self-repair test printed output: $out"
  pass ".omp turn-end guard: the loaded marker follows the lock owner at turn boundaries instead of only at load"
}

# A session generation stopped with no successor session_start is not a dead
# end: after the successor grace the extension binds a fresh generation and
# arms exactly once; a real session_start inside the grace arms nothing twice;
# and an arm call on a stopped generation heals at once instead of refusing.
# Every transition, and the expired bound, is in the lifecycle record.
test_watch_extension_heals_a_generation_stopped_without_a_successor() {
  local repo home out status
  repo="$TMP_ROOT/watch-heal/repo"; home="$TMP_ROOT/watch-heal/home"
  install_omp_extension_fixture "$repo"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
trap 'if [ -e "$FM_HOME/state/.delay-stop" ]; then sleep 0.7; fi; exit 0' TERM
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import fs, { writeFileSync, readFileSync, existsSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const sent = [];
const pi = {
  on(e, h) { handlers.set(e, h); },
  registerCommand() {},
  registerTool(t) { tool = t; },
  sendUserMessage(message) { sent.push(message); },
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const lifecycle = () => readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 50 && arms() < 1; i += 1) await sleep(50);
if (arms() !== 1) throw new Error(`startup should arm once, saw ${arms()}`);

// 1. Shutdown with no successor: one self-heal arm after the grace, no more.
await handlers.get("session_shutdown")({}, {});
await sleep(150);
if (arms() !== 1) throw new Error(`a heal fired before the successor grace: ${arms()} arms`);
for (let i = 0; i < 60 && arms() < 2; i += 1) await sleep(50);
if (arms() !== 2) throw new Error(`a stopped generation with no successor was not healed: ${arms()} arms`);
await sleep(900);
if (arms() !== 2) throw new Error(`the self-heal armed more than once: ${arms()} arms`);
const healed = await tool.execute();
if (!/^watcher: unchanged/.test(healed.content[0].text)) throw new Error(`the healed generation does not own its arm: ${healed.content[0].text}`);
const record = lifecycle();
for (const needle of ["event=session_shutdown", "event=generation-stop", "event=bound-expired", "waiter=omp-watch-extension", "waited-on=session_start", "bound=400ms", "outcome=self-heal", "event=generation-create", "cause=self-heal", "event=self-heal"]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}

// 2. Shutdown then a real session_start inside the grace: one arm, no heal.
await handlers.get("session_shutdown")({}, {});
await handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 60 && arms() < 3; i += 1) await sleep(50);
await sleep(900);
if (arms() !== 3) throw new Error(`a successor session_start must arm exactly once with no heal: ${arms()} arms`);
if ((lifecycle().match(/event=self-heal /g) ?? []).length + (lifecycle().match(/event=self-heal$/gm) ?? []).length !== 1) {
  throw new Error(`a heal fired despite a successor session_start:\n${lifecycle()}`);
}

// 3. An arm call on a stopped generation heals at once instead of refusing.
await handlers.get("session_shutdown")({}, {});
const armed = await tool.execute();
if (/shutting down/.test(armed.content[0].text)) throw new Error(`an arm call on a stopped generation was refused: ${armed.content[0].text}`);
if (!/^watcher: started/.test(armed.content[0].text)) throw new Error(`an arm call did not heal and arm: ${armed.content[0].text}`);
await sleep(900);
if (arms() !== 4) throw new Error(`the arm-call heal and the timed heal both armed: ${arms()} arms`);
if (!lifecycle().includes("cause=arm-call")) throw new Error(`the arm-call heal is not recorded:\n${lifecycle()}`);
const rebound = (module) => {
  const handlers = new Map(); const box = {};
  module.default({
    on(e, h) { handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { box.tool = t; },
    sendUserMessage(message) { sent.push(message); },
  });
  return { handlers, box };
};
const waitForArms = async (expected) => {
  for (let i = 0; i < 60 && arms() < expected; i++) await sleep(50);
  await sleep(900);
  if (arms() !== expected) throw new Error(`factory recovery expected ${expected} arms, saw ${arms()}`);
};
const successorModule = await import(`${pathToFileURL(process.env.EXT).href}?rebound`);
writeFileSync(`${home}/state/.delay-stop`, "");
const shutdown = handlers.get("session_shutdown")({}, {});
const successor = rebound(successorModule);
await sleep(500);
if (arms() !== 4) throw new Error("factory recovery raced pending predecessor retirement");
await shutdown;
await waitForArms(5);
const successorArm = await successor.box.tool.execute();
if (!successorArm.details.ok || !successorArm.details.message.includes("unchanged")) throw new Error("factory successor did not own the automatic recovery");
const forwarded = await tool.execute();
if (!forwarded.details.ok || !forwarded.details.message.includes("unchanged")) throw new Error("predecessor tool did not forward to the healed factory");
await successor.handlers.get("session_shutdown")({}, {});
const started = rebound(successorModule);
await started.handlers.get("session_start")({}, {});
await waitForArms(6);
await started.handlers.get("session_shutdown")({}, {});
const repaired = rebound(successorModule);
await repaired.box.tool.execute();
await waitForArms(7);
await repaired.handlers.get("session_shutdown")({}, {});
writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
const foreign = rebound(successorModule);
await sleep(900);
if (arms() !== 7) throw new Error("factory recovery armed under a foreign lock");
const refused = await foreign.box.tool.execute();
if (refused.details.ok || !refused.details.message.includes("read-only")) throw new Error("foreign factory recovery did not preserve lock ownership");
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
await foreign.handlers.get("session_shutdown")({}, {});
const unhandled = [];
process.on("unhandledRejection", (error) => unhandled.push(String(error)));
const originalWrite = fs.writeFileSync;
let injected = 0;
let fault = true;
writeFileSync(`${home}/state/.omp-watch-extension-loaded`, "stale\n");
fs.writeFileSync = function(path, ...args) {
  if (fault && String(path) === `${home}/state/.omp-watch-extension-loaded`) {
    fault = false;
    injected++;
    throw Object.assign(new Error("transient owner write failure"), { code: "EIO" });
  }
  return originalWrite.call(this, path, ...args);
};
syncBuiltinESMExports();
for (let i = 0; i < 100 && !injected; i++) await sleep(20);
await sleep(100);
if (injected !== 1 || arms() !== 7) throw new Error("timed owner failure did not stop activation");
const failures = sent.filter((message) => message.includes("transient owner write failure"));
if (failures.length !== 1) throw new Error("timed activation lost its failure wake");
if (unhandled.length) throw new Error(`unhandled activation rejection: ${unhandled.join("; ")}`);
const beforeRepair = lifecycle().split("\n").filter((line) => line.includes("event=generation-activate") && line.includes("cause=arm-call")).length;
const repair = await foreign.box.tool.execute();
if (!repair.details.ok) throw new Error("timed activation failure poisoned arm repair");
if (lifecycle().split("\n").filter((line) => line.includes("event=generation-activate") && line.includes("cause=arm-call")).length !== beforeRepair + 1) throw new Error("failed activation consumed the recovery obligation");
await waitForArms(8);
fs.writeFileSync = originalWrite;
syncBuiltinESMExports();
const liveReplacement = rebound(successorModule);
await waitForArms(9);
const liveArm = await liveReplacement.box.tool.execute();
if (!liveArm.details.ok || !liveArm.details.message.includes("unchanged")) throw new Error("live factory retirement did not recover without session_start");
await liveReplacement.handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension self-heal: $out"
  [ -z "$out" ] || fail "omp watch extension self-heal test printed output: $out"
  pass ".omp watch extension: a generation stopped without a successor heals once; a real successor or arm call never double-arms"
}

# Loading the extension twice in one process (auto-discovery plus -e) leaves
# exactly one live generation and one arm: the earlier instance retires, its
# events are ignored, and its arm tool forwards to the current instance.
test_watch_extension_is_single_instance_per_home() {
  local repo home out status
  repo="$TMP_ROOT/watch-single/repo"; home="$TMP_ROOT/watch-single/home"
  install_omp_extension_fixture "$repo"
  install_counting_arm "$repo"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const makePi = () => {
  const handlers = new Map(); const box = { tool: null };
  return { handlers, box, pi: {
    on(e, h) { handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { box.tool = t; },
    sendUserMessage() { return undefined; },
  } };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const mod = await import(pathToFileURL(process.env.EXT).href);
const first = makePi(); mod.default(first.pi);
const second = makePi(); mod.default(second.pi);
// Both instances see the same session events, as a double load would.
await first.handlers.get("session_start")({ type: "session_start" }, {});
await second.handlers.get("session_start")({ type: "session_start" }, {});
for (let i = 0; i < 50 && arms() < 1; i += 1) await sleep(50);
await sleep(600);
if (arms() !== 1) throw new Error(`a double load armed ${arms()} cycles`);
const viaFirst = await first.box.tool.execute();
if (!/^watcher: unchanged/.test(viaFirst.content[0].text)) throw new Error(`the tool of the superseded instance did not reach the live owner: ${viaFirst.content[0].text}`);
const viaSecond = await second.box.tool.execute();
if (!/^watcher: unchanged/.test(viaSecond.content[0].text)) throw new Error(`the current instance lost its arm: ${viaSecond.content[0].text}`);
// A shutdown seen by the superseded instance is ignored: the live cycle keeps running.
await first.handlers.get("session_shutdown")({}, {});
await sleep(900);
if (arms() !== 1) throw new Error(`the superseded instance changed the live cycle: ${arms()} arms`);
const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
for (const needle of ["event=factory-bind", "superseded=1", "event=instance-retired", "event=session_start-ignored", "event=arm-forwarded", "event=session_shutdown-ignored"]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}
const shutdown = second.handlers.get("session_shutdown")({}, {});
const repair = second.box.tool.execute();
const third = makePi(); mod.default(third.pi);
await third.handlers.get("session_start")({}, {});
const repaired = await repair;
await shutdown;
if (!/^watcher: unchanged/.test(repaired.content[0].text)) throw new Error(`stale continuation did not reach successor: ${repaired.content[0].text}`);
for (let i = 0; i < 50 && arms() < 2; i++) await sleep(50);
await sleep(900);
if (arms() !== 2) throw new Error(`arm continuation stole ownership from successor: ${arms()} arms`);
const current = await third.box.tool.execute();
if (!/^watcher: unchanged/.test(current.content[0].text)) throw new Error(`successor lost ordinary arm ownership: ${current.content[0].text}`);
await third.handlers.get("session_shutdown")({}, {});
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension single instance: $out"
  [ -z "$out" ] || fail "omp watch extension single-instance test printed output: $out"
  pass ".omp watch extension: a double load keeps one live generation, one arm, and forwards the superseded tool"
}

# The repair call judges ownership by a live arm child, never by a recorded one:
# an arm child whose process ended while a descendant still holds its output
# pipe is replaced, and the call reports started, even inside the output drain
# window (held long here so the repair lands inside it). A live child of the
# current owner is left alone.
test_watch_extension_repairs_a_stale_arm_owner() {
  local repo home out status
  repo="$TMP_ROOT/watch-stale/repo"; home="$TMP_ROOT/watch-stale/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ ! -e "$FM_HOME/state/.first-arm-ended" ]; then
  : > "$FM_HOME/state/.first-arm-ended"
  # The arm process ends, but a descendant keeps its output pipe open.
  sleep 60 &
  printf '%s\n' "$!" > "$FM_HOME/state/.pipe-holder"
  exit 0
fi
exec sleep 60
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_ARM_READY_TIMEOUT_MS=3000 FM_WATCH_ARM_RETIRE_TIMEOUT_MS=5000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage() { return undefined; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, { isIdle: () => true });
for (let i = 0; i < 100 && arms() < 1; i += 1) await sleep(50);
await sleep(500);
if (arms() !== 1) throw new Error(`expected one arm, saw ${arms()}`);
const holder = Number(readFileSync(`${home}/state/.pipe-holder`, "utf8"));
try {
  // The first arm process ended; its pipe holder keeps "close" from firing.
  process.kill(holder, 0);
  const repaired = await tool.execute();
  console.log(`repair: ${repaired.content[0].text}`);
  if (/^watcher: unchanged/.test(repaired.content[0].text)) throw new Error(`a dead arm owner was reported unchanged: ${repaired.content[0].text}`);
  if (!/^watcher: started omp extension arm child 2;/.test(repaired.content[0].text)) throw new Error(`the repair did not start a new arm: ${repaired.content[0].text}`);
  for (let i = 0; i < 100 && arms() < 2; i += 1) await sleep(50);
  if (arms() !== 2) throw new Error(`the repair did not start a live arm: ${arms()} arms`);
  const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
  if (!record.includes("event=arm-owner-stale")) throw new Error(`the lifecycle record lacks arm-owner-stale:\n${record}`);
  // The replacement is live and belongs to the current owner: a second call leaves it alone.
  await sleep(300);
  const again = await tool.execute();
  if (!/^watcher: unchanged/.test(again.content[0].text)) throw new Error(`a live arm child was replaced: ${again.content[0].text}`);
  if (arms() !== 2) throw new Error(`a live arm child was replaced: ${arms()} arms`);
} finally {
  try { process.kill(holder); } catch {}
  await handlers.get("session_shutdown")({}, {});
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension stale arm owner: $out"
  case "$out" in *"repair: watcher: started omp extension arm child 2;"*) ;; *) fail "the stale-owner repair did not report started: $out" ;; esac
  pass ".omp watch extension: a dead arm owner is replaced and reported started, a live one is left alone"
}

# A recorded arm child whose pid is gone before Node reaps it (exit state still
# unset) is logged as ended-unreaped, gets no SIGTERM, and is replaced.
test_watch_extension_labels_an_ended_unreaped_arm_owner() {
  local repo home out status
  repo="$TMP_ROOT/watch-unreaped/repo"; home="$TMP_ROOT/watch-unreaped/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
exec sleep 60
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { ChildProcess } from "node:child_process";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null;
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage() { return undefined; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const armPids = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).map((l) => Number(l.slice(4))) : [];
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, { isIdle: () => true });
for (let i = 0; i < 100 && armPids().length < 1; i += 1) await sleep(50);
await sleep(500);
const [stalePid] = armPids();
if (!stalePid) throw new Error("the first arm did not start");
const realKill = process.kill;
const realChildKill = ChildProcess.prototype.kill;
const childKills = [];
try {
  // The pid is gone to a liveness probe while the handle still has no exit state.
  process.kill = function (pid, signal) {
    if (Number(pid) === stalePid && signal === 0) {
      const error = new Error("kill ESRCH"); error.code = "ESRCH"; throw error;
    }
    return realKill.call(process, pid, signal);
  };
  ChildProcess.prototype.kill = function (signal) {
    if (this.pid === stalePid) childKills.push(signal ?? "SIGTERM");
    return realChildKill.call(this, signal);
  };
  const repaired = await tool.execute();
  process.kill = realKill;
  ChildProcess.prototype.kill = realChildKill;
  if (!/^watcher: started omp extension arm child 2;/.test(repaired.content[0].text)) throw new Error(`the repair did not start a new arm: ${repaired.content[0].text}`);
  if (childKills.length) throw new Error(`an ended arm child was sent ${childKills.join(",")}`);
  const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
  if (!record.includes(`event=arm-owner-stale pid=${stalePid} exit=ended-unreaped`)) throw new Error(`the lifecycle record lacks the ended-unreaped label:\n${record}`);
  if (record.includes("exit=alive-unverified")) throw new Error(`an ended arm child was labelled alive:\n${record}`);
} finally {
  process.kill = realKill;
  ChildProcess.prototype.kill = realChildKill;
  try { process.kill(stalePid); } catch {}
  await handlers.get("session_shutdown")({}, {});
}
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension ended-unreaped arm owner: $out"
  [ -z "$out" ] || fail "omp watch extension ended-unreaped test printed output: $out"
  pass ".omp watch extension: an ended-unreaped arm owner is labelled so, not killed, and replaced"
}

# The arm ends at its process exit, not at "close": an arm whose process exits
# while a descendant still holds its output pipe is observed without a repair
# call. An exit after "watcher: started" earns the bounded retry, and an exit
# after a wake line delivers that captured wake and arms its successor.
test_watch_extension_observes_an_arm_exit_held_open_by_a_descendant() {
  local repo home out status
  repo="$TMP_ROOT/watch-exit/repo"; home="$TMP_ROOT/watch-exit/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
n=$(($(wc -l < "${FM_ARM_LOG:-/dev/null}" 2>/dev/null || echo 0) + 1))
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$n"
case "$n" in
  1) ;;
  2)
    while [ ! -e "$FM_HOME/state/.fire-wake" ]; do sleep 0.1; done
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
    fm_wake_append signal omp-exit 'signal: omp-exit done' || exit 1
    printf 'signal: omp-exit done\n' ;;
  *) exec sleep 60 ;;
esac
# The arm process ends, but a descendant keeps its output pipe open.
sleep 60 &
printf '%s\n' "$!" >> "$FM_HOME/state/pipe-holders"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=60000 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=2 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = []; let tool = null;
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage(m) { sent.push(m); return undefined; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (check, what) => { for (let i = 0; i < 160 && !check(); i += 1) await sleep(50); if (!check()) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(sent)}`); };
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const holders = () => existsSync(`${home}/state/pipe-holders`) ? readFileSync(`${home}/state/pipe-holders`, "utf8").trim().split("\n").filter(Boolean).map(Number) : [];
const idle = { isIdle: () => true };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
try {
  await handlers.get("session_start")({ type: "session_start" }, idle);
  // The first arm exits after "watcher: started" with its pipe held open: the retry runs on its own.
  await until(() => arms() === 2, "the retry after an exit held open by a descendant");
  for (const holder of holders()) process.kill(holder, 0);
  // The retried arm exits after a wake line with its pipe held open: the captured wake is delivered.
  writeFileSync(`${home}/state/.fire-wake`, "");
  await until(() => sent.some((m) => m.includes("signal: omp-exit done")), "the captured wake");
  await until(() => arms() === 3, "the successor after the captured wake");
  if (holders().length !== 2) throw new Error(`expected two pipe holders, saw ${holders().length}`);
  if (sent.some((m) => m.includes("FAILED"))) throw new Error(`the observed exits were reported failed: ${JSON.stringify(sent)}`);
  const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
  if (!record.includes("waited-on=arm-output-drain")) throw new Error(`the lifecycle record lacks the output drain:\n${record}`);
  if (tool === null) throw new Error("the arm tool was not registered");
} finally {
  for (const holder of holders()) { try { process.kill(holder); } catch {} }
  await handlers.get("session_shutdown")({}, idle);
}
console.log("exit-ok");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension arm exit: $out"
  case "$out" in *exit-ok*) ;; *) fail "the arm exit test did not finish: $out" ;; esac
  pass ".omp watch extension: an arm exit held open by a descendant is observed, retried, and its wake delivered with no repair call"
}

# omp's agent registry tells the primary session ("main") from a task or
# subagent helper session. A helper that loads the extension in the same
# process never takes the home, never re-arms, and never receives a forwarded
# arm or a wake, while it lives or after it ends: the wake reaches the primary.
test_watch_extension_keeps_the_home_from_a_helper_session() {
  local repo home out status
  repo="$TMP_ROOT/watch-helper/repo"; home="$TMP_ROOT/watch-helper/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
while [ ! -e "$FM_HOME/state/.fire-wake" ]; do sleep 0.1; done
rm -f "$FM_HOME/state/.fire-wake"
. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
fm_wake_append signal omp-helper 'signal: omp-helper done' || exit 1
printf 'signal: omp-helper done\n'
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const refs = [];
const registry = { AgentRegistry: { global: () => ({ list: () => refs }) } };
const makePi = () => {
  const handlers = new Map(); const box = { tool: null, sent: [] };
  return { handlers, box, pi: {
    pi: registry,
    on(e, h) { handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { box.tool = t; },
    sendUserMessage(m) { box.sent.push(m); return undefined; },
  } };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (check, what) => { for (let i = 0; i < 100 && !check(); i += 1) await sleep(50); if (!check()) throw new Error(`timed out waiting for ${what}`); };
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const arm = (target, ctx) => target.box.tool.execute("call", {}, undefined, undefined, ctx);
const primarySession = {}; const helperSession = {};
const primaryCtx = { isIdle: () => true, sessionManager: primarySession };
const helperCtx = { isIdle: () => true, sessionManager: helperSession };
const mod = await import(pathToFileURL(process.env.EXT).href);
// The primary binds before its session is registered, as omp loads extensions first.
const primary = makePi(); mod.default(primary.pi);
refs.push({ kind: "main", session: { sessionManager: primarySession } });
await primary.handlers.get("session_start")({ type: "session_start" }, primaryCtx);
await until(() => arms() === 1, "the primary arm");
// A helper session loads the extension in the same process and runs.
const helper = makePi(); mod.default(helper.pi);
refs.push({ kind: "sub", session: { sessionManager: helperSession } });
await helper.handlers.get("session_start")({ type: "session_start" }, helperCtx);
await helper.handlers.get("before_agent_start")({}, helperCtx);
const viaHelper = await arm(helper, helperCtx);
if (!/^watcher: unchanged/.test(viaHelper.content[0].text)) throw new Error(`a helper arm call changed the primary arm: ${viaHelper.content[0].text}`);
await sleep(600);
if (arms() !== 1) throw new Error(`a live helper took the home: ${arms()} arms`);
const viaPrimary = await arm(primary, primaryCtx);
if (!/^watcher: unchanged/.test(viaPrimary.content[0].text)) throw new Error(`the primary lost its arm to a live helper: ${viaPrimary.content[0].text}`);
// With the helper live, a wake reaches the primary.
writeFileSync(`${home}/state/.fire-wake`, "");
await until(() => primary.box.sent.some((m) => m.includes("signal: omp-helper done")), "the wake on the primary");
await until(() => arms() === 2, "the primary successor");
// The helper ends; nothing moves to it or away from the primary.
refs.splice(1, 1);
await helper.handlers.get("session_shutdown")({}, helperCtx);
await sleep(600);
if (arms() !== 2) throw new Error(`an ended helper changed the primary arm: ${arms()} arms`);
const afterHelper = await arm(primary, primaryCtx);
if (!/^watcher: unchanged/.test(afterHelper.content[0].text)) throw new Error(`the primary arm call went elsewhere: ${afterHelper.content[0].text}`);
if (helper.box.sent.length !== 0) throw new Error(`a helper received a wake: ${JSON.stringify(helper.box.sent)}`);
const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
for (const needle of ["waiting=primary-session", "event=session_start-ignored reason=not-primary-session", "event=session_shutdown-ignored reason=not-primary-session"]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}
if (record.includes("event=home-claimed") || record.includes("event=instance-retired")) throw new Error(`a helper took the home:\n${record}`);
await primary.handlers.get("session_shutdown")({}, primaryCtx);
console.log("helper-ok");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension helper session: $out"
  case "$out" in *helper-ok*) ;; *) fail "the helper session test did not finish: $out" ;; esac
  pass ".omp watch extension: a helper session never takes the home or the wakes, and a wake reaches the primary"
}

# A rebind for the primary session (a second factory bind while the primary
# runs) takes the home at the primary's next event. The instance it replaced
# no longer receives events and gets nothing afterwards: not the home after a
# session replacement, not an arm, and not a wake.
test_watch_extension_rebound_primary_keeps_the_home() {
  local repo home out status
  repo="$TMP_ROOT/watch-rebind/repo"; home="$TMP_ROOT/watch-rebind/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
while [ ! -e "$FM_HOME/state/.fire-wake" ]; do sleep 0.1; done
rm -f "$FM_HOME/state/.fire-wake"
. "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
fm_wake_append signal omp-rebind 'signal: omp-rebind done' || exit 1
printf 'signal: omp-rebind done\n'
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const refs = [];
const registry = { AgentRegistry: { global: () => ({ list: () => refs }) } };
const makePi = () => {
  const handlers = new Map(); const box = { tool: null, sent: [] };
  return { handlers, box, pi: {
    pi: registry,
    on(e, h) { handlers.set(e, h); },
    registerCommand() {},
    registerTool(t) { box.tool = t; },
    sendUserMessage(m) { box.sent.push(m); return undefined; },
  } };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (check, what) => { for (let i = 0; i < 100 && !check(); i += 1) await sleep(50); if (!check()) throw new Error(`timed out waiting for ${what}`); };
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const primarySession = {};
const ctx = { isIdle: () => true, sessionManager: primarySession };
const mod = await import(pathToFileURL(process.env.EXT).href);
const before = makePi(); mod.default(before.pi);
refs.push({ kind: "main", session: { sessionManager: primarySession } });
await before.handlers.get("session_start")({ type: "session_start" }, ctx);
await until(() => arms() === 1, "the first arm");
// The rebind: from here on only the new instance receives the session events.
const after = makePi(); mod.default(after.pi);
await sleep(300);
if (arms() !== 1) throw new Error(`a bind that has not proven the primary session changed the arm: ${arms()} arms`);
await after.handlers.get("before_agent_start")({}, ctx);
await until(() => arms() === 2, "the arm of the rebound instance");
// The primary session is replaced (/new): the new instance keeps the home.
await after.handlers.get("session_shutdown")({}, ctx);
await after.handlers.get("session_start")({ type: "session_start" }, ctx);
await until(() => arms() === 3, "the arm after the session replacement");
await sleep(900);
if (arms() !== 3) throw new Error(`the home moved after the session replacement: ${arms()} arms`);
const current = await after.box.tool.execute("call", {}, undefined, undefined, ctx);
if (!/^watcher: unchanged/.test(current.content[0].text)) throw new Error(`the rebound instance lost the home: ${current.content[0].text}`);
writeFileSync(`${home}/state/.fire-wake`, "");
await until(() => after.box.sent.some((m) => m.includes("signal: omp-rebind done")), "the wake on the rebound instance");
if (before.box.sent.length !== 0) throw new Error(`the replaced instance received a wake: ${JSON.stringify(before.box.sent)}`);
const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
for (const needle of ["waiting=primary-session", "event=home-claimed", "cause=turn-start"]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}
await after.handlers.get("session_shutdown")({}, ctx);
console.log("rebind-ok");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension rebound primary: $out"
  case "$out" in *rebind-ok*) ;; *) fail "the rebound primary test did not finish: $out" ;; esac
  pass ".omp watch extension: a rebound primary keeps the home and the instance it replaced gets nothing"
}

# A session event that fails to bind its generation is not a dead end: the
# failure is recorded and surfaced as a watcher FAILED wake, and the bounded
# self-heal arms once the cause is gone, with no fm_watch_arm_omp call.
test_watch_extension_heals_a_failed_session_bind() {
  local repo home out status
  repo="$TMP_ROOT/watch-bind-fail/repo"; home="$TMP_ROOT/watch-bind-fail/home"
  install_omp_extension_fixture "$repo"
  install_counting_arm "$repo"
  mkdir -p "$home/state"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); const sent = [];
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool() {}, sendUserMessage(m) { sent.push(m); return undefined; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (check, what) => { for (let i = 0; i < 100 && !check(); i += 1) await sleep(50); if (!check()) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(sent)}`); };
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const idle = { isIdle: () => true };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
// The loaded-build marker cannot be written while the session binds.
const marker = `${home}/state/.omp-watch-extension-loaded`;
rmSync(marker, { force: true });
mkdirSync(marker);
await handlers.get("session_start")({ type: "session_start" }, idle).catch(() => {});
await until(() => sent.some((m) => m.includes("could not bind the session generation")), "the surfaced bind failure");
if (arms() !== 0) throw new Error(`the failed bind armed ${arms()} cycles`);
rmSync(marker, { recursive: true });
await until(() => arms() === 1, "the self-heal arm");
const record = readFileSync(`${home}/state/extensions/omp-primary-watch/lifecycle.log`, "utf8");
for (const needle of ["event=session-bind-failed", "cause=session_start", "event=self-heal "]) {
  if (!record.includes(needle)) throw new Error(`the lifecycle record lacks ${needle}:\n${record}`);
}
await handlers.get("session_shutdown")({}, idle);
console.log("bind-heal-ok");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension failed session bind: $out"
  case "$out" in *bind-heal-ok*) ;; *) fail "the failed session bind test did not finish: $out" ;; esac
  pass ".omp watch extension: a failed session bind is surfaced and the bounded self-heal arms without a repair call"
}

# Readiness is judged by liveness and progress, not by a fixed total time: a
# successor that is slow to report keeps running and is reported as still
# starting, a cycle whose process dies is reported as failed and replaced by the
# next repair call, and a live child that is still starting is not replaced.
test_watch_extension_judges_readiness_by_liveness() {
  local repo home out status
  repo="$TMP_ROOT/watch-ready/repo"; home="$TMP_ROOT/watch-ready/home"
  install_omp_extension_fixture "$repo"
  mkdir -p "$home/state"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
n=$(($(wc -l < "${FM_ARM_LOG:-/dev/null}" 2>/dev/null || echo 0) + 1))
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
case "$n" in
  1)  # The first cycle reports, then ends with a wake.
    printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-1\n' "$$"
    sleep 0.3
    . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
fm_wake_append signal omp-ready 'signal: omp-ready done' || exit 1
printf 'signal: omp-ready done\n'
    exit 0 ;;
  2)  # A slow successor: it burns CPU for longer than the notice window, then reports.
    end=$((SECONDS + 2))
    while [ "$SECONDS" -lt "$end" ]; do :; done
    : > "$FM_HOME/state/.slow-ready-reported"
    printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-2\n' "$$"
    exec sleep 60 ;;
  3)  # A dead successor: its process ends without ever reporting.
    sleep 0.3
    kill -9 "$$" ;;
  *)
    printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$n"
    exec sleep 60 ;;
esac
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    FM_ARM_LOG="$home/arms.log" FM_OMP_ARM_READY_TIMEOUT_MS=300 \
    FM_WATCH_REARM_RETRY_LIMIT=1 FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 \
    EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { writeFileSync, readFileSync, existsSync } from "node:fs";
const home = process.env.FM_HOME;
writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
const handlers = new Map(); let tool = null; const sent = [];
const pi = { on(e, h) { handlers.set(e, h); }, registerCommand() {}, registerTool(t) { tool = t; }, sendUserMessage(m) { sent.push(m); return undefined; } };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const until = async (check, what, rounds = 200) => { for (let i = 0; i < rounds && !check(); i += 1) await sleep(50); if (!check()) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(sent)}`); };
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const idle = { isIdle: () => true };
const mod = await import(pathToFileURL(process.env.EXT).href);
mod.default(pi);
await handlers.get("session_start")({ type: "session_start" }, idle);
// The slow successor passes the 300ms notice window; the wake goes out saying so.
await until(() => sent.some((m) => m.includes("signal: omp-ready done")) && sent.some((m) => m.includes("still starting")), "the still-starting wake");
if (existsSync(`${home}/state/.slow-ready-reported`)) throw new Error("the wake waited for the slow successor to report");
if (sent.some((m) => m.includes("FAILED"))) throw new Error(`a slow but progressing successor was reported failed: ${JSON.stringify(sent)}`);
// It is still alive and starting: a repair call leaves it alone.
const during = await tool.execute(idle);
if (!/^watcher: unchanged/.test(during.content[0].text)) throw new Error(`a live starting successor was replaced: ${during.content[0].text}`);
if (arms() !== 2) throw new Error(`a live starting successor was replaced: ${arms()} arms`);
// It finishes startup well past the notice window and was never dropped.
await until(() => existsSync(`${home}/state/.slow-ready-reported`), "the slow successor own report");
await sleep(300);
const after = await tool.execute(idle);
if (!/^watcher: unchanged/.test(after.content[0].text)) throw new Error(`the slow successor lost ownership after reporting: ${after.content[0].text}`);
if (sent.some((m) => m.includes("FAILED"))) throw new Error(`the slow successor was reported failed: ${JSON.stringify(sent)}`);
// The running cycle dies. Its replacement dies too without ever reporting: that is reported, not hidden.
const running = Number(readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")[1].replace("arm=", ""));
process.kill(running, "SIGKILL");
await until(() => sent.some((m) => m.includes("FAILED")), "the report of the dead cycle");
await sleep(300);
const repaired = await tool.execute(idle);
console.log(`dead: ${repaired.content[0].text}`);
if (/^watcher: unchanged/.test(repaired.content[0].text)) throw new Error(`a dead cycle was reported owned: ${repaired.content[0].text}`);
if (!repaired.details.ok) throw new Error(`the repair after a dead cycle failed: ${repaired.content[0].text}`);
await until(() => arms() >= 4, "a live replacement");
await handlers.get("session_shutdown")({}, idle);
console.log("slow-ok");
process.exit(0);
EOF
)
  status=$?
  expect_code 0 "$status" "omp watch extension readiness by liveness: $out"
  case "$out" in *slow-ok*) ;; *) fail "the readiness test did not finish: $out" ;; esac
  pass ".omp watch extension: a slow but progressing successor is not dropped and a live starting child is not replaced"
}

test_watch_extension_repairs_after_handoff_publication_failure() {
  local repair repo home out status
  for repair in tool command factory; do
    repo="$TMP_ROOT/watch-persist-$repair/repo"; home="$TMP_ROOT/watch-persist-$repair/home"
    install_omp_extension_fixture "$repo"
    mkdir -p "$home/state"
    cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --handling-delivered ] && exit 0
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$$"
if [ ! -e "$FM_HOME/state/.fired" ]; then
  : > "$FM_HOME/state/.fired"
  . "$FM_ROOT_OVERRIDE/bin/fm-wake-lib.sh"
  fm_wake_append check publication-failure 'check: publication failure wake' || exit 1
  printf 'check: publication failure wake\n'
  exit 0
fi
exec sleep 30
SH
    chmod +x "$repo/bin/fm-watch-arm.sh"
    out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
      FM_ARM_LOG="$home/arms.log" FM_OMP_SUCCESSOR_GRACE_MS=400 FM_OMP_ARM_READY_TIMEOUT_MS=3000 \
      REPAIR="$repair" EXT="$repo/.omp/extensions/fm-primary-omp-watch.ts" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const waitFor = async (predicate) => {
  for (let i = 0; i < 60 && !predicate(); i++) await sleep(50);
  if (!predicate()) throw new Error("timed out waiting for publication failure fixture");
};
const arms = () => existsSync(process.env.FM_ARM_LOG) ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0;
const makePi = () => {
  const handlers = new Map(), commands = new Map(), sent = [], box = {};
  return { handlers, commands, sent, box, pi: {
    on(e, h) { handlers.set(e, h); },
    registerCommand(name, command) { commands.set(name, command); },
    registerTool(t) { box.tool = t; },
    sendUserMessage(message) { sent.push(message); },
  } };
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.EXT).href);
const first = makePi(); mod.default(first.pi);
const ctx = { isIdle: () => true };
await first.handlers.get("session_start")({}, ctx);
await waitFor(() => first.sent.length === 1 && arms() === 2);
const handoff = `${process.env.FM_HOME}/state/extensions/omp-primary-watch/session-replacement-actionable.json`;
mkdirSync(handoff);
let owner = first;
if (process.env.REPAIR === "factory") {
  owner = makePi(); mod.default(owner.pi);
} else {
  await first.handlers.get("session_shutdown")({}, ctx);
}
rmSync(handoff, { recursive: true });
if (process.env.REPAIR === "command") {
  const notifications = [];
  await owner.commands.get("fm-watch-arm-omp").handler("", { ...ctx, ui: { notify(message) { notifications.push(message); } } });
  if (notifications.length !== 1 || !notifications[0].startsWith("watcher: started")) throw new Error("command repair was poisoned by publication failure");
} else {
  const repaired = await owner.box.tool.execute();
  if (!repaired.details.ok || !repaired.details.message.startsWith("watcher: started")) throw new Error("tool repair was poisoned by publication failure");
}
await waitFor(() => owner.sent.some((message) => message.includes("could not persist a replacement-session actionable wake")));
const failures = owner.sent.filter((message) => message.includes("could not persist a replacement-session actionable wake"));
if (failures.length !== 1) throw new Error("repair lost or duplicated its persistence failure");
const queued = spawnSync("bash", [`${process.env.FM_ROOT_OVERRIDE}/bin/fm-wake-drain.sh`, "--queued"], { env: process.env, encoding: "utf8" });
if (queued.status !== 0 || queued.stdout.trim().split("\t").slice(4).join("\t") !== "check: publication failure wake") throw new Error("publication failure repair lost the durable actionable row");
await owner.handlers.get("message_start")({ message: { role: "user", content: failures[0] } }, ctx);
await sleep(900);
if (arms() !== 3) throw new Error("publication failure repair double-armed");
const unchanged = await owner.box.tool.execute();
if (!unchanged.details.ok || !unchanged.details.message.includes("unchanged")) throw new Error("repaired watcher lost ordinary arm ownership");
await owner.handlers.get("session_shutdown")({}, ctx);
process.exit(0);
EOF
)
    status=$?
    expect_code 0 "$status" "omp publication failure $repair repair: $out"
    [ -z "$out" ] || fail "omp publication failure $repair repair printed output: $out"
  done
  pass ".omp watch extension: publication failure retains the wake and permits tool, command, and factory repair"
}

test_watch_lifecycle_deadline_diagnostics() {
  local repo="$TMP_ROOT/omp-expiry-root" out status
  install_omp_extension_fixture "$repo"
  out=$(node "$ROOT/tests/watch-lifecycle-expiry.mjs" omp "$repo" 2>&1)
  status=$?
  expect_code 0 "$status" "omp lifecycle deadline diagnostics: $out"
  pass "omp explicit shutdown logs its retirement expiry; readiness has no wall-clock cutoff"
}

test_task_session_proof_tracks_active_session
test_watch_lifecycle_deadline_diagnostics
test_watch_extension_marks_host_closes_without_headlines boundary
test_watch_extension_marks_host_closes_without_headlines note
test_watch_extension_marks_host_closes_without_headlines archived
test_watch_extension_marks_host_closes_without_headlines diagnostic
test_watch_extension_marks_host_closes_without_headlines restore-boundary
test_watch_extension_marks_host_closes_without_headlines restore-diagnostic
test_watch_extension_redelivers_merged_host_notes rows
test_watch_extension_redelivers_merged_host_notes empty
test_watch_extension_replays_host_marks_from_the_handoff diagnostic
test_watch_extension_replays_host_marks_from_the_handoff boundary
test_watch_extension_delivers_a_split_host_close_whole
test_watch_extension_migrates_legacy_handoffs
test_watch_extension_queue_read_delivery
test_primary_extensions_ignore_a_descendant_session
test_secondmate_watch_proof_ignores_a_descendant_omp
test_secondmate_watch_proof_publishes_for_the_secondmate_itself
test_turnend_marker_follows_the_lock_owner_at_turn_boundaries
test_watch_extension_heals_a_generation_stopped_without_a_successor
test_watch_extension_is_single_instance_per_home
test_watch_extension_repairs_a_stale_arm_owner
test_watch_extension_labels_an_ended_unreaped_arm_owner
test_watch_extension_observes_an_arm_exit_held_open_by_a_descendant
test_watch_extension_keeps_the_home_from_a_helper_session
test_watch_extension_rebound_primary_keeps_the_home
test_watch_extension_heals_a_failed_session_bind
test_watch_extension_judges_readiness_by_liveness
test_watch_extension_repairs_after_handoff_publication_failure
