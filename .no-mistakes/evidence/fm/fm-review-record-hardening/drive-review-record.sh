#!/usr/bin/env bash
# Live drive of bin/fm-review-record.py (new = $1/bin, old = $2/bin) in a throwaway FM_HOME.
set -u
NEW=$1; OLD=$2
H=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
URL=https://github.com/example/repo/pull/9
AG='{"all":["gpt-5.1-codex"]}'
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-rr-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
run() { # label bindir home args...
  local label=$1 bin=$2 home=$3; shift 3
  printf '\n$ [%s] fm-review-record.py %s\n' "$label" "$*"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$bin/fm-review-record.py" "$@"; printf '(exit %s)\n' "$?"
}
rev() { # label bin home verdict report trigger_flag trigger_val
  run "$1" "$2" "$3" review --pr "$URL" --head "$H" --verdict "$4" --reader-model claude-opus-5-5 --author-groups "$AG" \
    --loosens-deny-allow-list no --widens-guard "${6:-no}" --customer-data-billing-spend no --report "$5"
}
mkrep() { printf 'VERDICT: %s head=%s\nReader evidence.\n' "$2" "$3" > "$1"; }

echo "=== I1 / probe P2: captain-word H, FAIL H, PASS H with --widens-guard yes ==="
for side in old new; do
  bin=$NEW/bin; [ $side = old ] && bin=$OLD/bin
  home=$T/i1-$side; mkdir -p "$home/state"
  mkrep "$home/fail.md" FAIL "$H"; mkrep "$home/pass.md" PASS "$H"
  run "$side" "$bin" "$home" captain-word --pr "$URL" --head "$H" --words 'Merge this PR.'
  rev "$side" "$bin" "$home" FAIL "$home/fail.md"
  rev "$side" "$bin" "$home" PASS "$home/pass.md" yes
  run "$side" "$bin" "$home" verify --pr "$URL" --head "$H"
done

echo; echo "=== I1 edge: same sequence, trigger-free PASS still clears the FAIL (new) ==="
home=$T/i1-edge; mkdir -p "$home/state"
mkrep "$home/fail.md" FAIL "$H"; mkrep "$home/pass.md" PASS "$H"
run new "$NEW/bin" "$home" captain-word --pr "$URL" --head "$H" --words 'Merge this PR.'
rev new "$NEW/bin" "$home" FAIL "$home/fail.md"
rev new "$NEW/bin" "$home" PASS "$home/pass.md"
run new "$NEW/bin" "$home" verify --pr "$URL" --head "$H"

echo; echo "=== I1 recovery: new captain-word after the triggered PASS stands (new) ==="
home=$T/i1-renew; mkdir -p "$home/state"
mkrep "$home/fail.md" FAIL "$H"; mkrep "$home/pass.md" PASS "$H"
run new "$NEW/bin" "$home" captain-word --pr "$URL" --head "$H" --words 'Merge this PR.'
rev new "$NEW/bin" "$home" FAIL "$home/fail.md"
rev new "$NEW/bin" "$home" PASS "$home/pass.md" yes
run new "$NEW/bin" "$home" captain-word --pr "$URL" --head "$H" --words 'Merge despite the trigger.'
run new "$NEW/bin" "$home" verify --pr "$URL" --head "$H"

echo; echo "=== I2: report checks (new); each bad case must exit 2 and append nothing ==="
home=$T/i2; mkdir -p "$home/state"
for bad in missing symlink verdict-mismatch head-mismatch directory empty no-newline-prefix; do
  r=$T/i2-$bad.md; rm -rf "$r"
  case $bad in
    missing) : ;;
    symlink) mkrep "$T/i2-target.md" PASS "$H"; ln -s "$T/i2-target.md" "$r" ;;
    verdict-mismatch) mkrep "$r" FAIL "$H" ;;
    head-mismatch) mkrep "$r" PASS "$H2" ;;
    directory) mkdir "$r" ;;
    empty) : > "$r" ;;
    no-newline-prefix) printf 'Summary first\nVERDICT: PASS head=%s\n' "$H" > "$r" ;;
  esac
  before=$(cat "$home/state/review-records.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  echo; echo "-- case: $bad (rows before: $before)"
  rev new "$NEW/bin" "$home" PASS "$r"
  after=$(cat "$home/state/review-records.jsonl" 2>/dev/null | wc -l | tr -d ' ')
  echo "rows after: $after"
done
echo; echo "-- same missing report on OLD code (shows the gap I2 closes)"
home_old=$T/i2-old; mkdir -p "$home_old/state"
rev old "$OLD/bin" "$home_old" PASS "$T/does-not-exist.md"
run old "$OLD/bin" "$home_old" verify --pr "$URL" --head "$H"
echo; echo "-- good report records report_sha256 (new)"
mkrep "$T/good.md" PASS "$H"
rev new "$NEW/bin" "$home" PASS "$T/good.md"
echo "shasum: $(shasum -a 256 "$T/good.md" | cut -d' ' -f1)"
run new "$NEW/bin" "$home" latest --pr "$URL" | sed "s#$T#\$T#g"
echo "-- edit report after recording; verify uses recorded evidence"
printf 'tampered\n' >> "$T/good.md"
run new "$NEW/bin" "$home" verify --pr "$URL" --head "$H"
echo; echo "-- history from old code (rows without report_sha256) still verifies on new code"
run new "$NEW/bin" "$home_old" verify --pr "$URL" --head "$H"
