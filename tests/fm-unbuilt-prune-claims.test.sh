#!/usr/bin/env bash
# No text of this repository may say or imply that an hourly or scheduled
# `treehouse prune` exists, unless the same sentence says it is not built.
#
# Why: bin/fm-merge-prune.sh and docs/configuration.md once told readers that a
# scheduled bulk treehouse prune net existed and was unchanged. No commit ever
# built it, so a reader trusted a net that was absent. This file is the guard
# that keeps such a sentence from coming back. Its own fixtures spell the old
# sentences from fragments at run time (see expand), so a plain grep for the old
# wording finds only sentences that say the net is not built.
#
# Usage:
#   tests/fm-unbuilt-prune-claims.test.sh               run the cases
#   tests/fm-unbuilt-prune-claims.test.sh --scan [ROOT] run only the check on ROOT
#                                                       (default: this repository);
#                                                       prints each member as
#                                                       file:line: sentence, exit 1
#
# The check scans bin docs .agents tests README.md AGENTS.md CONTRIBUTING.md
# skills .github under ROOT (never data/, whose evidence logs quote old text).
# It joins each comment block or paragraph into sentences. A sentence is a member
# when it (a) names `prune` within 60 characters of hourly, scheduled, nightly,
# daily, periodic, cron, launchd or "every hour", or (b) names `safety net`
# within 60 characters of `treehouse`, `prune` or one of those timing words (the
# timing words are in (b) so that a timed safety net is caught without the word
# prune). A member passes only when the same sentence holds one closed
# phrase: "no hourly", "no scheduled", "is not built" or "never built". A bare
# "not" or "unchanged" never counts. The matching rule is the one line marked
# `matching-rule` in the scanner below; the cases delete it in a scratch copy
# to prove they notice. This script never calls `treehouse`.
set -u

fm_unbuilt_scan() {
  python3 -I - "$@" <<'PY'
import bisect
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
EXCLUDE = ["tests/fm-unbuilt-prune-claims.test.sh"]
SCAN = ["bin", "docs", ".agents", "tests", "README.md", "AGENTS.md", "CONTRIBUTING.md", "skills", ".github"]
if len(sys.argv) > 2 and sys.argv[2] == "--list-exclusions":
    print("\n".join(EXCLUDE))
    raise SystemExit(0)
TIMING = r"(?:hourly|scheduled|nightly|daily|periodic(?:ally)?|cron|launchd|every hour)"
NAMING = re.compile(rf"prune.{{0,60}}\b{TIMING}\b|\b{TIMING}\b.{{0,60}}prune|safety net.{{0,60}}(?:treehouse|prune|\b{TIMING}\b)|(?:treehouse|prune|\b{TIMING}\b).{{0,60}}safety net", re.I | re.S)
ALLOW = re.compile(r"no hourly|no scheduled|is not built|never built", re.I)
scanned = []


def files():
    for name in SCAN:
        base = root / name
        if base.is_file():
            yield base
        elif base.is_dir():
            for path in sorted(base.rglob("*")):
                if path.is_file() and ".git" not in path.relative_to(root).parts:
                    yield path


def paragraphs(text):
    block = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = re.sub(r"^\s*#+ ?", "", raw).strip() if raw.lstrip().startswith("#") else raw.strip()
        if line:
            block.append((number, line))
        elif block:
            yield block
            block = []
    if block:
        yield block


def members():
    for path in files():
        rel = path.relative_to(root).as_posix()
        if rel in EXCLUDE:
            continue
        data = path.read_bytes()
        if b"\0" in data[:8192]:
            continue
        scanned.append(rel)
        for block in paragraphs(data.decode("utf-8", "replace")):
            joined, starts = "", []
            for number, line in block:
                starts.append((len(joined), number))
                joined += line + " "
            offsets = [s for s, _ in starts]
            for m in re.finditer(r"\S.*?(?:(?<=[.!?])(?=\s)|$)", joined, re.S):
                sentence = m.group(0)
                hit = False
                hit = bool(NAMING.search(sentence)) and not ALLOW.search(sentence)  # matching-rule
                if hit:
                    yield rel, starts[bisect.bisect_right(offsets, m.start()) - 1][1], sentence.strip()


found = 0
for rel, number, sentence in members():
    found += 1
    print(f"{rel}:{number}: {sentence[:150]}")
if found:
    raise SystemExit(1)
print(f"fm-unbuilt-prune-claims: ok files={len(scanned)}")
PY
}

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [ "${1:-}" = "--scan" ]; then
  fm_unbuilt_scan "${2:-$REPO_ROOT}"
  exit $?
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-unbuilt-prune.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

# The three members the check must report at the base commit, as they read there.
# ~H~ and ~PAY~ are spelled out by expand, so this file never holds the old wording whole.
expand() {
  local h=hour p=pru
  h+=ly
  p+=ne
  p+=" --all --yes"
  local text=${1//\~H\~/$h}
  printf '%s\n' "${text//\~PAY\~/$p}"
}

# shellcheck disable=SC2016 # The backticks are literal sentence text, not command substitution.
OLD_BIN_9='# A merged task'"'"'s pool copy used to stay until an ~H~ safety net or a human'
# shellcheck disable=SC2016 # The backticks are literal sentence text, not command substitution.
OLD_BIN_138='# hours in case the cause cleared. The ~H~ `treehouse ~PAY~`'
OLD_BIN_139='# safety net is not duplicated.'
# shellcheck disable=SC2016 # The backticks are literal sentence text, not command substitution.
OLD_DOC_898='The ~H~ `treehouse ~PAY~` safety net is unchanged, and the prune does not alter what teardown itself preserves or refuses: the fallback acts only after teardown has refused, and the removal of a returned copy only after teardown has returned it.'
OLD_BIN_9=$(expand "$OLD_BIN_9")
OLD_BIN_138=$(expand "$OLD_BIN_138")
OLD_DOC_898=$(expand "$OLD_DOC_898")

# put_at <file> <line> <text...>: write the text lines so the first one is line <line>;
# every earlier line is a filler comment sentence that names nothing.
put_at() {
  local file=$1 line=$2 i
  shift 2
  mkdir -p "$(dirname "$file")"
  : > "$file"
  i=1
  while [ "$i" -lt "$line" ]; do
    printf '%s\n' '# Filler sentence.' >> "$file"
    i=$((i + 1))
  done
  printf '%s\n' "$@" >> "$file"
}

# old_root <dir>: the base-shaped fixture, each member at its base line number.
old_root() {
  put_at "$1/bin/fm-merge-prune.sh" 9 "$OLD_BIN_9" '# removed it.'
  put_at "$1/docs/configuration.md" 898 "$OLD_DOC_898"
  # The header sentence at line 138 needs its own file here: line 9 shares the base file.
  put_at "$1/bin/fm-merge-prune-second.sh" 138 "$OLD_BIN_138" "$OLD_BIN_139"
}

# fixed_root <dir>: the same fixture with the corrected texts of the fix.
# shellcheck disable=SC2016 # The backticks are literal sentence text, not command substitution.
fixed_root() {
  put_at "$1/bin/fm-merge-prune.sh" 9 \
    '# A merged task'"'"'s pool copy used to stay until a human or the owner'"'"'s manual' \
    '# reaper (~/.local/bin/treehouse-reap-clean)' \
    '# removed it.'
  put_at "$1/bin/fm-merge-prune-second.sh" 138 \
    "$(expand '# hours in case the cause cleared. No ~H~ `treehouse ~PAY~`')" \
    '# net is built in this repository: the owner'"'"'s manual reaper,' \
    '# ~/.local/bin/treehouse-reap-clean, run by hand on named paths, is the' \
    '# only net until the task fm-arm-prune-and-copy-sweep lands.'
  put_at "$1/docs/configuration.md" 898 \
    "$(expand 'No ~H~ `treehouse ~PAY~` net is built in this repository:')"' the owner'"'"'s manual reaper `~/.local/bin/treehouse-reap-clean`, run by hand on named paths, is the only net until the task `fm-arm-prune-and-copy-sweep` lands.' \
    'The prune does not alter what teardown itself preserves or refuses: the fallback acts only after teardown has refused, and the removal of a returned copy only after teardown has returned it.'
}

# scan_rc <script> <root>: run the check; sets SCAN_OUT and SCAN_RC.
scan_rc() {
  local rc
  SCAN_OUT=$(bash "$1" --scan "$2" 2>&1)
  rc=$?
  SCAN_RC=$rc
}

# one_sentence_rc <text...>: the check's exit status for a docs file holding the text.
one_sentence_rc() {
  local dir
  dir=$(mktemp -d "$TMP_ROOT/one.XXXXXX")
  mkdir -p "$dir/docs"
  printf '%s\n' "$@" > "$dir/docs/x.md"
  scan_rc "$SELF" "$dir"
}

test_exclusion_list_is_exactly_this_file() {
  local out
  out=$(fm_unbuilt_scan "$REPO_ROOT" --list-exclusions) || fail "exclusion listing failed"
  assert_equals "tests/fm-unbuilt-prune-claims.test.sh" "$out" \
    "the check must exclude exactly its own file and nothing else"
  pass "the check excludes exactly its own file"
}

test_repository_has_no_unbuilt_prune_claim() {
  scan_rc "$SELF" "$REPO_ROOT"
  [ "$SCAN_RC" -eq 0 ] || fail "repository names a timed prune net that is not built: $SCAN_OUT"
  case "$SCAN_OUT" in
    "fm-unbuilt-prune-claims: ok files="*) : ;;
    *) fail "check did not report its scope: $SCAN_OUT" ;;
  esac
  [ "${SCAN_OUT#*files=}" -gt 100 ] || fail "check scanned too few files: $SCAN_OUT"
  pass "no text of the repository names a timed or scheduled treehouse prune without saying it is not built"
}

test_base_shaped_texts_are_reported_by_file_and_line() {
  local root=$TMP_ROOT/old
  old_root "$root"
  scan_rc "$SELF" "$root"
  [ "$SCAN_RC" -eq 1 ] || fail "old texts did not fail the check (rc=$SCAN_RC): $SCAN_OUT"
  assert_contains "$SCAN_OUT" "bin/fm-merge-prune.sh:9: " "line 9 member not reported"
  assert_contains "$SCAN_OUT" "bin/fm-merge-prune-second.sh:138: " "line 138 member not reported"
  assert_contains "$SCAN_OUT" "docs/configuration.md:898: " "docs line 898 member not reported"
  assert_equals 3 "$(printf '%s\n' "$SCAN_OUT" | wc -l | tr -d ' ')" \
    "exactly the three members must be reported"
  pass "the three base members are reported as file:line, and only those"
}

test_corrected_texts_pass() {
  local root=$TMP_ROOT/fixed
  fixed_root "$root"
  scan_rc "$SELF" "$root"
  [ "$SCAN_RC" -eq 0 ] || fail "corrected texts still fail (rc=$SCAN_RC): $SCAN_OUT"
  pass "the same fixture with the corrected sentences passes"
}

test_matching_rule_shapes() {
  local text
  assert_equals "$(printf 'hour%s pru%s --all --yes' ly ne)" "$(expand '~H~ ~PAY~')" "expand must spell the old wording back, or the cases below prove nothing"
  while IFS= read -r text; do
    one_sentence_rc "$(expand "$text")"
    [ "$SCAN_RC" -eq 1 ] || fail "should be reported: $text"
  done <<'EOF'
A nightly treehouse prune frees pool copies.
A cron job runs treehouse prune every night.
The scheduled prune is unchanged.
Every hour the watcher runs prune.
The ~H~ prune is not run here.
The ~H~ prune is unchanged.
The safety net for pool copies is the treehouse prune.
A periodic safety net removes returned copies.
EOF
  one_sentence_rc "$(expand 'The ~H~ prune')" 'is run by the' 'watcher.'
  [ "$SCAN_RC" -eq 1 ] || fail "a sentence spread over three lines must be reported"
  while IFS= read -r text; do
    one_sentence_rc "$(expand "$text")"
    [ "$SCAN_RC" -eq 0 ] || fail "should pass: $text ($SCAN_OUT)"
  done <<'EOF'
No ~H~ prune is built.
No scheduled prune exists here.
The ~H~ prune is not built.
The nightly prune was never built.
The whole-slot reaper (`treehouse prune`) works on slots and cannot see these copies; this script does not touch slots.
Hourly hygiene job, one line (bounded by the process budget, never forced):
Firstmate installs no scheduler for `--apply`; run this one line from the host's own hourly job:
A retained copy is retried silently every six hours in case the cause cleared.
`treehouse prune` works on whole pool slots and does not see these copies, and a teardown only removes its own task's.
Aging is only a presentation safety net.
EOF
  pass "the matching rule reports each unbuilt-prune shape and spares the true neighbouring texts"
}

test_every_listed_path_is_scanned() {
  local root path
  for path in bin/x.sh docs/x.md .agents/skills/x/SKILL.md tests/other.test.sh README.md AGENTS.md CONTRIBUTING.md skills/x.md .github/x.yml; do
    root=$(mktemp -d "$TMP_ROOT/path.XXXXXX")
    mkdir -p "$root/$(dirname "$path")"
    printf '%s\n' "$OLD_DOC_898" > "$root/$path"
    scan_rc "$SELF" "$root"
    [ "$SCAN_RC" -eq 1 ] || fail "the check missed the old sentence in $path"
    assert_contains "$SCAN_OUT" "$path:1: " "member in $path not named"
  done
  root=$(mktemp -d "$TMP_ROOT/path.XXXXXX")
  mkdir -p "$root/data/x" "$root/tests"
  printf '%s\n' "$OLD_DOC_898" > "$root/data/x/report.md"
  printf '%s\n' "$OLD_DOC_898" > "$root/tests/fm-unbuilt-prune-claims.test.sh"
  scan_rc "$SELF" "$root"
  [ "$SCAN_RC" -eq 0 ] || fail "data/ and the check's own file must not be scanned: $SCAN_OUT"
  pass "every listed path is scanned; data/ and the check's own file are not"
}

# mutant <name> <sed-script>: a scratch copy of this file with the sed script applied;
# prints its path. The copy must differ from the original.
mutant() {
  local out=$TMP_ROOT/$1.sh
  sed -e "$2" "$SELF" > "$out"
  cmp -s "$SELF" "$out" && fail "mutant $1 changed nothing"
  printf '%s\n' "$out"
}

test_deleting_the_matching_rule_is_noticed() {
  local root=$TMP_ROOT/old-for-mutant m
  [ "$(grep -c '# matching-rule$' "$SELF")" -eq 1 ] || fail "the matching rule must sit on exactly one marked line"
  old_root "$root"
  scan_rc "$SELF" "$root"
  [ "$SCAN_RC" -eq 1 ] || fail "the original must fail on the old fixture"
  m=$(mutant no-rule '/# matching-rule$/d')
  [ "$(($(wc -l < "$SELF") - $(wc -l < "$m")))" -eq 1 ] || fail "the mutant must delete exactly one line"
  scan_rc "$m" "$root"
  [ "$SCAN_RC" -eq 0 ] || fail "without its matching rule the check must report nothing, which this case then catches: $SCAN_OUT"
  assert_contains "$SCAN_OUT" "fm-unbuilt-prune-claims: ok" "the mutant did not run to the end"
  pass "a copy without the matching rule passes the old texts, so the cases above fail for that reason"
}

test_widening_the_allowance_to_any_not_is_noticed() {
  local root=$TMP_ROOT/old-for-allowance m
  put_at "$root/bin/fm-merge-prune.sh" 138 "$OLD_BIN_138" "$OLD_BIN_139"
  scan_rc "$SELF" "$root"
  [ "$SCAN_RC" -eq 1 ] || fail "the original must fail on the old header sentence"
  assert_contains "$SCAN_OUT" "bin/fm-merge-prune.sh:138: " "the old header sentence was not reported"
  m=$(mutant any-not 's/never built"/never built|\\bnot\\b"/')
  scan_rc "$m" "$root"
  [ "$SCAN_RC" -eq 0 ] || fail "with any 'not' allowed the old header sentence must pass, proving the allowance is tight: $SCAN_OUT"
  pass "an allowance widened to any 'not' lets the old header sentence through, so the real allowance is tight"
}

ALL_TESTS=(
  test_exclusion_list_is_exactly_this_file
  test_repository_has_no_unbuilt_prune_claim
  test_base_shaped_texts_are_reported_by_file_and_line
  test_corrected_texts_pass
  test_matching_rule_shapes
  test_every_listed_path_is_scanned
  test_deleting_the_matching_rule_is_noticed
  test_widening_the_allowance_to_any_not_is_noticed
)
if [ "$#" -gt 0 ]; then
  fm_test_run_cases -- "$@"
else
  fm_test_run_cases "${ALL_TESTS[@]}" --
fi
