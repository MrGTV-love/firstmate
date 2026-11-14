#!/usr/bin/env bash
# PROFILE-COVERS for a recorded successor branch.
#
# unit:   the production profile builder grants one exact literal ref (with its
#         lock and reflog) per recorded successor and nothing more; the profile
#         text diff is exactly the successor's literal allow lines. Runs anywhere.
# kernel: the same grant under the real kernel confinement on the Scott task
#         fixture, with /usr/bin/sandbox-exec. It reports SKIPPED-UNVERIFIED, never
#         pass, where a profile cannot be applied (a worker's own sandbox refuses
#         a nested sandbox-exec, exit 71) or off macOS. The macOS CI job
#         macos-stock-bash runs it with FM_REQUIRE_KERNEL_PROOF=1, which turns the
#         skip into a failure, so only a green run there is the kernel proof.
# Cases live in tests/fm-write-confinement-successor.py.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-write-confinement-successor)
rc=0
out=$(python3 -I "$ROOT/tests/fm-write-confinement-successor.py" "$ROOT" "$TMP_ROOT/unit" unit 2>&1) || rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || fail "the successor profile unit cases failed (exit $rc)"
pass "PROFILE-COVERS (profile text): the generated profile gains exactly the successor's literal allow lines and nothing else under refs/heads"
for validator in validators oracle; do
  rc=0
  out=$(python3 -I "$ROOT/tests/fm-write-confinement-successor-$validator.py" "$ROOT" "$TMP_ROOT/$validator" 2>&1) || rc=$?
  printf '%s\n' "$out"
  [ "$rc" = 0 ] || fail "the successor $validator checks failed (exit $rc)"
done
pass "PROFILE-COVERS (validators): the profile comparison sees a removed deny line, and the kernel judgment tells a confinement refusal from an unrelated git failure"
rc=0
out=$(python3 -I "$ROOT/tests/fm-write-confinement-successor.py" "$ROOT" "$TMP_ROOT/kernel" kernel 2>&1) || rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || fail "the successor kernel proof failed (exit $rc)"
case "$out" in
  *SKIPPED-UNVERIFIED*) printf 'skip: PROFILE-COVERS kernel proof is UNVERIFIED here; it is met only by the green macOS CI result\n' ;;
  *) pass "PROFILE-COVERS (kernel): with the new profile the successor is allowed and an unrelated name, another task's branch and prefix- or suffix-sharing names are refused; with the old profile the successor is refused" ;;
esac
