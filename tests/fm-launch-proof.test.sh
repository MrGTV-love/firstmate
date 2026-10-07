#!/usr/bin/env bash
# Launch proof: live kernel environments, exact native-resume boundaries, and
# conservative refusal on ambiguous or unavailable process identity.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(mktemp -d)
PID=
cleanup() { [ -z "$PID" ] || kill "$PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
export FM_HOME="$TMP/home"
mkdir -p "$FM_HOME/state"
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/fm-launch-proof-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
start_probe() {
  rm -f "$TMP/ready"
  FM_SPAWN_GEN=$1 FM_PROOF_NOTE=${3:-} python3 -c 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(120)' "$TMP/ready" "${2:-}" &
  PID=$!
  for _ in $(seq 1 200); do
    [ ! -f "$TMP/ready" ] || return 0
    sleep 0.01
  done
  fail 'process environment probe did not start'
}
test_launch_proof_recorded_native_identity() {
start_probe ''
[ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'readable bare process must be unmanaged'
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe '' 'FM_SPAWN_GEN=expected'
[ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'argv text must not impersonate a launch environment pin'
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe '' '' 'ordinary value FM_SPAWN_GEN=expected'
[ "$(fm_launch_proof_pid "$PID" expected)" = unmanaged ] || fail 'text inside another environment value must not impersonate a launch pin'
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe '' '' $'ordinary value\nFM_SPAWN_GEN=expected'
[ "$(fm_launch_proof_pid "$PID" expected)" = unknown ] || fail 'an ambiguous multiline environment must not authenticate a launch pin'
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe expected
[ "$(fm_launch_proof_pid "$PID" expected)" = managed ] || fail 'live matching incarnation must be managed'
[ "$(fm_launch_proof_pid "$PID" different)" = unmanaged ] || fail 'another incarnation must not authenticate this launch'
kill "$PID"; wait "$PID" 2>/dev/null || true
[ "$(fm_launch_proof_pid "$PID" expected)" = unknown ] || fail 'gone process must never authorize recovery'
PID=
pass 'live process environment distinguishes managed, missing, mismatched, and gone launches'

META="$FM_HOME/state/t.meta"
WORKTREE="$TMP/worktree"
mkdir -p "$WORKTREE" "$FM_HOME/data/t"
mkdir -p "$TMP/foreign-state" "$FM_HOME/state/path-component"
ln -s "$FM_HOME/state" "$TMP/state-alias"
proof_meta() {
  printf 'window=lab:w1:p1\nharness=%s\nworktree=%s\n' "$1" "$WORKTREE" > "$META"
  [ -z "${2:-}" ] || printf 'launch_proof=%s\nspawn_gen=%s\n' "$2" "${3:-}" >> "$META"
}
proof_meta omp
BRIEF="$(fm_brief_worker_role "$FM_HOME/state" t)"$'\n\nTask assigned by Firstmate.'
fm_operational_input_encode launch-brief "$BRIEF" MESSAGE
jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"recorded",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
# shellcheck disable=SC2153 # fm_operational_input_encode assigns MESSAGE by name.
jq -nc --arg text "$MESSAGE" '{type:"message",message:{role:"user",content:[{type:"text",text:$text}]}}' \
  >> "$WORKTREE/recorded.jsonl"
jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"personal",cwd:$cwd}' > "$WORKTREE/personal.jsonl"
jq -nc '{type:"message",message:{role:"user",content:"personal prompt"}}' >> "$WORKTREE/personal.jsonl"
INFO=
fm_backend_herdr_cli() { printf '%s' "$INFO"; }
PARENTS=
ps() {
  if [ "$*" = '-axo pid=,ppid=' ] && [ -n "$PARENTS" ]; then
    printf '%s\n' "$PARENTS"
  else
    command ps "$@"
  fi
}
process() { # <argv-json> [pid]
  INFO=$(jq -nc --argjson argv "$1" --argjson pid "${2:-2}" --arg cwd "$WORKTREE" \
    --arg ref "$WORKTREE/recorded.jsonl" '
    ($argv | map(if . == "--resume=/a/session.jsonl" or . == "--resume=session-ref"
      then "--resume=" + $ref else . end)) as $args
    | {result:{type:"pane_process_info",process_info:{pane_id:"w1:p1",
      foreground_processes:[{argv:$args,pid:$pid,cwd:$cwd}]}}}')
}
assert_proof() { [ "$(fm_launch_proof_herdr "$META")" = "$1" ] || fail "$2"; }
process '["omp","--resume=/a/session.jsonl"]'
assert_proof unmanaged 'bare restored omp must be recoverable'
cp "$WORKTREE/recorded.jsonl" "$WORKTREE/header-first.jsonl"
for slot in \
  '{"type":"title","v":1,"title":"","updatedAt":"","pad":""}' \
  '{"type":"title","v":1,"title":"Worker task","source":"auto","updatedAt":"2026-10-06","pad":" "}' \
  '{"type":"title","v":1,"title":"Named task","source":"user","updatedAt":"","pad":""}'; do
  printf '%s\n' "$slot" > "$WORKTREE/recorded.jsonl"
  cat "$WORKTREE/header-first.jsonl" >> "$WORKTREE/recorded.jsonl"
  assert_proof unmanaged 'a validated native title slot must preserve task-owned startup proof'
done
for slot in \
  '{"type":"custom","v":1,"title":"","updatedAt":"","pad":""}' \
  '{"type":"title","v":2,"title":"","updatedAt":"","pad":""}' \
  '{"type":"title","v":1,"title":null,"updatedAt":"","pad":""}' \
  '{"type":"title","v":1,"title":"","updatedAt":null,"pad":""}' \
  '{"type":"title","v":1,"title":"","updatedAt":"","pad":null}' \
  '{"type":"title","v":1,"title":"","updatedAt":""}' \
  '{"type":"title","v":1,"title":"","updatedAt":"","pad":"","source":null}' \
  '{"type":"title","v":1,"title":"","updatedAt":"","pad":"","source":"other"}' \
  '[]' \
  'malformed'; do
  printf '%s\n' "$slot" > "$WORKTREE/recorded.jsonl"
  cat "$WORKTREE/header-first.jsonl" >> "$WORKTREE/recorded.jsonl"
  assert_proof unknown 'an invalid or arbitrary preamble must not skip to task-owned startup'
done
jq -nc '{type:"title",v:1,title:"",updatedAt:"",pad:""}' > "$WORKTREE/title-slot"
cat "$WORKTREE/title-slot" "$WORKTREE/title-slot" "$WORKTREE/header-first.jsonl" > "$WORKTREE/recorded.jsonl"
assert_proof unknown 'repeated native title slots must not skip to a later session header'
cat "$WORKTREE/title-slot" "$WORKTREE/personal.jsonl" > "$WORKTREE/recorded.jsonl"
assert_proof unknown 'a valid title slot must not authenticate a personal conversation'
cp "$WORKTREE/header-first.jsonl" "$WORKTREE/recorded.jsonl"
assert_proof unmanaged 'header-first native sessions must remain compatible'
pass 'native title slots accept semantic empty and named titles and reject invalid, arbitrary and repeated preambles'
printf 'kind=scout\n' >> "$META"
cat "$WORKTREE/title-slot" "$WORKTREE/header-first.jsonl" > "$WORKTREE/recorded.jsonl"
assert_proof unmanaged 'native title-slot startup must use the shared scout ownership parser'
proof_meta omp
cp "$WORKTREE/header-first.jsonl" "$WORKTREE/recorded.jsonl"
process '["omp","--resume","/a/session.jsonl"]'
assert_proof unknown 'split omp resume arguments must not authorize native restoration recovery'
process '["omp","--config","overlay","--auto-approve","--resume=/a/session.jsonl"]'
assert_proof unknown 'legacy absence must not restart a configured resume'
process '["omp","--resume="]'
assert_proof unknown 'empty resume identity must not authorize recovery'
process '["omp","a prompt mentioning --resume=/a/session.jsonl"]'
assert_proof unknown 'quoted resume text must not count as a restored launch'
process '["claude","--resume","foreign"]'
assert_proof unknown 'foreign foreground agent must not authorize recorded omp recovery'
INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"foreign","foreground_processes":[]}}}'
assert_proof unknown 'mismatched endpoint must stay unknown'
process '["omp","--resume=/a/session.jsonl"]'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes += .result.process_info.foreground_processes')
assert_proof unknown 'two foreground agents must refuse recovery'
pass 'native resume proof requires exact recorded harness, endpoint, cwd, bare argv and persisted startup provenance'

process '["omp","--resume=/a/session.jsonl"]' 200
PARENTS=$'200 1\n201 200'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 200
  | .result.process_info.foreground_processes =
    [{argv:["omp","__omp_worker_mnemopi_embed"],pid:201}] + .result.process_info.foreground_processes')
assert_proof unmanaged 'foreground helpers must not hide the bare restored group leader'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 999')
assert_proof unknown 'a missing group leader must not be inferred from its children'

start_probe expected
proof_meta omp env-v1 expected
process '["node","/installed/agent.js"]' "$PID"
PARENTS=$(printf '%s 1\n2 %s\n' "$PID" "$PID")
INFO=$(printf '%s' "$INFO" | jq --argjson pid "$PID" '
  .result.process_info.foreground_process_group_id = $pid
  | .result.process_info.foreground_processes =
    [{argv:["helper"],pid:2}] + .result.process_info.foreground_processes')
assert_proof managed 'kernel launch proof must support interpreter-based agents with foreground helpers'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 999
  | .result.process_info.foreground_processes += [{pid:999,name:"bash",argv0:"sh",argv:["sh"]}]')
PARENTS=$(printf '%s 999\n999 1\n2 %s\n' "$PID" "$PID")
assert_proof managed 'a launcher shell must not hide the marked primary agent'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_process_group_id = 2')
assert_proof unknown 'a marked child must never authenticate an unreadable foreground leader'
for harness in $(fm_control_harnesses) claude-custom; do
  proof_meta "$harness"
  printf 'spawn_gen=expected\n' >> "$META"
  process '["node","/installed/agent.js"]' "$PID"
  assert_proof managed "matching incarnation must attribute a legacy managed $harness launch"
  proof_meta "$harness"
  printf 'spawn_gen=different\n' >> "$META"
  assert_proof unknown "mismatched incarnation must not attribute a legacy $harness interpreter launch"
done
proof_meta omp env-v2 expected
assert_proof unknown 'matching incarnation must not bypass an unsupported proof boundary'
kill "$PID"; wait "$PID" 2>/dev/null || true
PID=
PARENTS=
pass 'foreground agent ancestry owns launch proof, independently of shells, helpers and executable packaging'

proof_meta codex
process '["codex","resume","session-ref"]'
assert_proof unknown 'legacy non-omp resume must not authorize recovery'
proof_meta omp
process '["node","/installed/omp/entry.js","--resume=session-ref"]'
assert_proof unknown 'legacy node entry points must not authorize omp recovery'
process '["python3","/installed/omp/entry.py","--resume=session-ref"]'
assert_proof unknown 'legacy Python entry points must not authorize omp recovery'
process '["/installed/omp/versions/1.0","--resume=session-ref"]'
assert_proof unknown 'legacy omp path components must not replace exact executable identity'
process '["omp","--resume=session-ref"]'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes[0].name = "node"')
assert_proof unknown 'a reported interpreter must not authenticate legacy omp argv'
process '["omp","--resume=session-ref"]'
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes[0].argv0 = "python3"')
assert_proof unknown 'a reported interpreter argv0 must not authenticate legacy omp argv'
process '["/installed/bin/omp","--resume=session-ref"]'
assert_proof unmanaged 'an exact omp executable basename and equals-form resume must remain recoverable'
proof_meta omp env-v2
assert_proof unknown 'an unsupported proof boundary must not fall back to legacy argv'
pass 'legacy recovery is limited to exact compiled omp equals-form resume with recorded task startup provenance'

start_probe expected
proof_meta omp env-v1 different
process '["node","/foreign/agent.js"]' "$PID"
assert_proof unknown 'a mismatched incarnation must not authorize foreign interpreter recovery'
process '["omp","a prompt"]' "$PID"
assert_proof unknown 'a mismatched incarnation alone must not authorize attributed personal omp'
process '["omp","--resume=session-ref"]' "$PID"
assert_proof unmanaged 'a mismatched incarnation remains recoverable only with recorded bare native provenance'
for harness in $(fm_control_harnesses) claude-custom omp-custom unrecognized; do
  [ "$harness" != omp ] || continue
  proof_meta "$harness" env-v1 different
  process "[\"$harness\",\"a prompt\"]" "$PID"
  assert_proof unknown "a mismatched incarnation must not authorize recorded $harness recovery"
  proof_meta "$harness" env-v1 expected
  process '["node","/installed/agent.js"]' "$PID"
  assert_proof managed "matching incarnation must remain managed for recorded $harness"
done
kill "$PID"; wait "$PID" 2>/dev/null || true
start_probe ''
proof_meta omp env-v1 expected
process '["python3","/foreign/script.py"]' "$PID"
assert_proof unknown 'unmarked foreign Python must not authorize recorded omp recovery'
process '["node","/foreign/agent.js"]' "$PID"
assert_proof unknown 'unmarked foreign node must not authorize recorded omp recovery'
process '["claude","--resume","foreign"]' "$PID"
assert_proof unknown 'unmarked foreign Claude must not authorize recorded omp recovery'
process '["unknown-agent"]' "$PID"
assert_proof unknown 'unmarked unknown executable must not authorize recovery'
process '["omp","a prompt"]' "$PID"
assert_proof unknown 'unmarked attributed personal omp argv must not authorize recovery'
process '["/installed/bin/omp","a prompt"]' "$PID"
assert_proof unknown 'unmarked personal omp executable path must not authorize recovery'
process '["node","/installed/agent.js"]' "$PID"
INFO=$(printf '%s' "$INFO" | jq '.result.process_info.foreground_processes[0].name = "omp"')
assert_proof unknown 'unmarked omp process name alone must not supply recorded-task attribution'
process '["/installed/bin/omp","--resume=session-ref"]' "$PID"
assert_proof unmanaged 'unmarked exact recorded native startup remains recoverable'
INFO=$(printf '%s' "$INFO" | jq --arg cwd "$TMP" '.result.process_info.foreground_processes[0].cwd = $cwd')
assert_proof unknown 'matching persisted startup must not authorize a foreground process in another cwd'
process '["omp","--resume=session-ref"]' "$PID"
INFO=$(printf '%s' "$INFO" | jq 'del(.result.process_info.foreground_processes[0].cwd)')
assert_proof unknown 'missing actual foreground cwd must refuse recovery'
process "[\"omp\",\"--resume=$WORKTREE/personal.jsonl\"]" "$PID"
assert_proof unknown 'same-cwd personal native conversation must not authorize recovery'
for version in legacy env-v1; do
  proof_meta omp
  [ "$version" != env-v1 ] || proof_meta omp env-v1 expected
  process '["omp","--resume=session-ref"]' "$PID"
  cp "$WORKTREE/recorded.jsonl" "$WORKTREE/saved.jsonl"
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"header-only",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version header-only conversation must not authenticate native recovery"
  printf 'malformed json\n' >> "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version malformed native conversation must remain unknown"
  jq -s --arg cwd "$TMP" '.[0].cwd = $cwd | .[]' "$WORKTREE/saved.jsonl" > "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version native header in another worktree must not authenticate recovery"
  cat "$WORKTREE/personal.jsonl" "$WORKTREE/saved.jsonl" > "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version later quoted launch message must not replace initial user provenance"
  jq -s '.[0], {type:"message",message:{role:"user",content:null}}, .[1]' \
    "$WORKTREE/saved.jsonl" > "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version unreadable initial user content must not learn a later launch envelope"
  jq -s 'null, .[]' "$WORKTREE/saved.jsonl" > "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version invalid initial header must not learn a later session header"
  fm_operational_input_encode launch-brief "A prompt mentioning $FM_HOME/state/t.inbox" OTHER_MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"generic",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version generic launch envelope mentioning the right path is not task provenance"
  OTHER_BRIEF="$(fm_brief_worker_role "$FM_HOME/state" another-task)"$'\n\nTask assigned by Firstmate.'
  fm_operational_input_encode launch-brief "$OTHER_BRIEF" OTHER_MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"foreign-task",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
  assert_proof unknown "$version another task's real generated launch role must remain unknown"
  for worker_kind in ship scout; do
    printf 'kind=%s\n' "$worker_kind" >> "$META"
    for role_state in "$TMP/state-alias" "$FM_HOME/state/." "$FM_HOME/state/path-component/.." "$FM_HOME/state/" \
      "$(CDPATH='' cd -P -- "$FM_HOME/state" && pwd -P)"; do
      OTHER_BRIEF="$(fm_brief_worker_role "$role_state" t)"$'\n\nTask assigned by Firstmate.'
      fm_operational_input_encode launch-brief "$OTHER_BRIEF" OTHER_MESSAGE
      jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"alias",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
      jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
      assert_proof unmanaged "$version $worker_kind equivalent inbox directory spelling must preserve task ownership"
      [ "$(fm_launch_proof_herdr "$TMP/state-alias/t.meta")" = unmanaged ] \
        || fail "$version $worker_kind equivalent metadata directory spelling must preserve task ownership"
    done
    for role_state in "$TMP/foreign-state" "$TMP/missing-state"; do
      OTHER_BRIEF="$(fm_brief_worker_role "$role_state" t)"$'\n\nTask assigned by Firstmate.'
      fm_operational_input_encode launch-brief "$OTHER_BRIEF" OTHER_MESSAGE
      jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"foreign-home",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
      jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
      assert_proof unknown "$version $worker_kind matching task ID in another or unavailable inbox directory must remain unknown"
    done
    OTHER_BRIEF="$(fm_brief_worker_role "$TMP/state-alias" another-task)"$'\n\nTask assigned by Firstmate.'
    fm_operational_input_encode launch-brief "$OTHER_BRIEF" OTHER_MESSAGE
    jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"foreign-task-alias",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
    jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
    assert_proof unknown "$version $worker_kind resolved directory identity must not relax the exact task ID"
    OTHER_BRIEF="$(fm_brief_worker_role "$TMP/state-alias" t)"$'\n\nTask assigned by Firstmate.'
    OTHER_BRIEF=${OTHER_BRIEF/You are a crewmate/You are a supervisor}
    fm_operational_input_encode launch-brief "$OTHER_BRIEF" OTHER_MESSAGE
    jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"altered-role",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
    jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
    assert_proof unknown "$version $worker_kind equivalent inbox spelling must not relax the remaining role contract"
  done
  mkdir -p "$WORKTREE/data"
  printf '# Standing charter\nServe this recorded secondmate home.\n' > "$WORKTREE/data/charter.md"
  printf 'kind=secondmate\nhome=%s\n' "$WORKTREE" >> "$META"
  fm_operational_input_encode launch-brief "$(cat "$WORKTREE/data/charter.md")" OTHER_MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"secondmate",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
  assert_proof unmanaged "$version exact recorded secondmate charter must preserve legitimate native recovery"
  cp "$WORKTREE/recorded.jsonl" "$WORKTREE/secondmate-header-first.jsonl"
  cat "$WORKTREE/title-slot" "$WORKTREE/secondmate-header-first.jsonl" > "$WORKTREE/recorded.jsonl"
  assert_proof unmanaged "$version native title-slot secondmate charter must remain recoverable"
  printf '# A different charter\n' > "$WORKTREE/data/charter.md"
  assert_proof unknown "$version a different secondmate charter must not authenticate native recovery"
  rm "$WORKTREE/data/charter.md"
  printf '# Fallback secondmate brief\nServe this task.\n' > "$FM_HOME/data/t/brief.md"
  fm_operational_input_encode launch-brief "$(cat "$FM_HOME/data/t/brief.md")" OTHER_MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"fallback",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
  assert_proof unmanaged "$version recorded secondmate launch fallback must remain recoverable"
  ln -s "$WORKTREE/data/missing-charter.md" "$WORKTREE/data/charter.md"
  assert_proof unmanaged "$version dangling charter symlink must use the same fallback as spawn"
  rm "$WORKTREE/data/charter.md"
  mkdir "$WORKTREE/data/charter.md"
  assert_proof unmanaged "$version charter directory must use the same fallback as spawn"
  rmdir "$WORKTREE/data/charter.md"
  printf '# Symlinked charter\nServe this secondmate home.\n' > "$WORKTREE/data/real-charter.md"
  ln -s "$WORKTREE/data/real-charter.md" "$WORKTREE/data/charter.md"
  assert_proof unknown "$version a regular-file charter symlink must supersede the fallback brief"
  fm_operational_input_encode launch-brief "$(cat "$WORKTREE/data/charter.md")" OTHER_MESSAGE
  jq -nc --arg cwd "$WORKTREE" '{type:"session",version:3,id:"symlinked-charter",cwd:$cwd}' > "$WORKTREE/recorded.jsonl"
  jq -nc --arg text "$OTHER_MESSAGE" '{type:"message",message:{role:"user",content:$text}}' >> "$WORKTREE/recorded.jsonl"
  assert_proof unmanaged "$version exact regular-file charter symlink must preserve native recovery"
  rm "$WORKTREE/data/charter.md"
  cp "$WORKTREE/saved.jsonl" "$WORKTREE/recorded.jsonl"
done
pass 'versioned and legacy provenance reject generic, foreign, malformed and personal sessions while preserving exact secondmate startup'
proof_meta claude-custom env-v1 expected
process '["/installed/claude/versions/1.0","a prompt"]' "$PID"
assert_proof unknown 'unmarked recorded Claude must not authorize unmanaged recovery'
process '["omp","a prompt"]' "$PID"
assert_proof unknown 'an attributed but different harness family must not authorize recovery'
proof_meta unrecognized env-v1 expected
assert_proof unknown 'an unsupported recorded harness must not authorize recovery'
for harness in $(fm_control_harnesses) omp-custom; do
  [ "$harness" != omp ] || continue
  proof_meta "$harness" env-v1 expected
  process "[\"$harness\",\"a prompt\"]" "$PID"
  assert_proof unknown "missing incarnation must not authorize recorded $harness recovery"
done
kill "$PID"; wait "$PID" 2>/dev/null || true
PID=
pass 'env-v1 unmanaged recovery requires recorded native startup while matching pins remain managed for every harness'
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi
test_launch_proof_recorded_native_identity
