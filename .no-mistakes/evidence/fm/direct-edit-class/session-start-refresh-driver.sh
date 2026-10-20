#!/usr/bin/env bash
# Drives the REAL bin/fm-session-start.sh instruction-refresh path with the REAL
# AGENTS.md before (base commit) and after (this branch) the change.
set -u
WORK=$1 EVDIR=$2
# shellcheck disable=SC1091
. "$WORK/helpers.sh"
BASE_SHA=03bff4bceb03a4aae3ef38975be1b2ae41ba55df

rec=$(new_world real-agents)
IFS='|' read -r root home fakebin <<EOF
$rec
EOF
make_fake_toolchain "$fakebin"
make_fake_ps_harness "$fakebin" pi

# 1. Session starts under the BASE AGENTS.md.
git -C "$ROOT" show "$BASE_SHA:AGENTS.md" > "$root/AGENTS.md"
startup=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --source startup)
assert_contains "$startup" "SESSION START - $home" "startup did not run"
baseline=$(cat "$home/state/.session-start-agents-baseline")
printf 'baseline file after startup:\n%s\n' "$baseline"
[ "$(printf '%s\n' "$baseline" | sed -n 2p)" = "$(hash_file_for_test "$root/AGENTS.md")" ] \
  || fail "baseline hash is not the base AGENTS.md hash"
pass "startup recorded the base-commit AGENTS.md hash as the session baseline"

# 2. Control: base file unchanged -> compact must NOT refresh.
ctl=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
assert_not_contains "$ctl" "CURRENT AGENTS.md - INSTRUCTION REFRESH" "unchanged base file refreshed"
assert_not_contains "$ctl" "Direct-edit class" "base file leaked the new paragraph"
pass "control: base AGENTS.md on disk -> compact emits no refresh and no direct-edit paragraph"

# 3. The branch's AGENTS.md lands on disk (the changed file, byte for byte).
cp "$ROOT/AGENTS.md" "$root/AGENTS.md"
cmp -s "$ROOT/AGENTS.md" "$root/AGENTS.md" || fail "copy differs"
printf '%s\n' "$(git -C "$ROOT" rev-parse HEAD)" > "$EVDIR/driver-head.txt"
compact=$(FM_FAKE_HARNESS=pi run_pi_session_start "$home" "$root" "$fakebin:$BASE_PATH" --reemit --source compact)
printf '%s\n' "$compact" > "$EVDIR/session-start-compact-refresh-output.txt"
assert_contains "$compact" "CURRENT AGENTS.md - INSTRUCTION REFRESH" "drifted compact did not refresh"
assert_contains "$compact" "Direct-edit class (captain-set 2026-10-19, revisable)." "refresh lacks the new heading"
assert_contains "$compact" "Two kinds of work on this repository's own shared tracked material skip the brief, the worker, the capacity slot and the acceptance section" "refresh lacks the class sentence"
assert_contains "$compact" "except the direct-edit class in section 7; when the fleet is empty" "refresh lacks the section 1 exception"
[ "$(cat "$home/state/.session-start-agents-baseline")" = "$baseline" ] || fail "baseline was rebased"
pass "changed AGENTS.md -> compact emits the refresh with the direct-edit paragraph and the section 1 exception"

# 4. Whole file delivered intact, contiguous, after the supersede preface.
python3 -I - "$ROOT/AGENTS.md" "$EVDIR/session-start-compact-refresh-output.txt" <<'PY' || fail "refresh body is not the full AGENTS.md"
import sys
a = open(sys.argv[1], encoding="utf-8").read()
o = open(sys.argv[2], encoding="utf-8").read()
assert a in o, "full AGENTS.md is not a contiguous block of the refresh output"
hdr = o.index("CURRENT AGENTS.md - INSTRUCTION REFRESH")
assert o.index(a) > hdr, "AGENTS.md block precedes refresh header"
print("full AGENTS.md (%d bytes) is a contiguous block after the refresh header" % len(a.encode()))
PY
pass "refresh body is the complete branch AGENTS.md, byte-identical"
