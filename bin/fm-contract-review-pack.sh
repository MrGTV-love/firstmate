#!/usr/bin/env bash
# Build the clean reviewer input for an independent review of a definition-of-done
# contract, and check afterwards, from the run's session transcript, that the reviewer
# read only what it was given. The review rules live in .agents/skills/contract-review/SKILL.md;
# this script owns the allow-list of known contract sections (CONTRACT_SECTIONS,
# CONTRACT_SUBSECTIONS and QUALIFIER_WORDS below) and is the only code path in this
# repository that assembles contract-review reviewer input.
#
# usage:
#   fm-contract-review-pack.sh [build] --contract <file> [--request <file>]
#       [--context <file>]... --root <repo-root> [--exclude <path>]...
#       [--register <path>] [--history <path>] [--policy <file>] [--out-root <dir>]
#       [--work-root <dir>]
#   fm-contract-review-pack.sh check --pack <dir> --log <session-transcript>
#       [--manifest <file>]
#
# build: prints the pack directory on stdout, and nothing else there.
#   The pack is <out-root>/pack. <out-root> is a fresh mktemp -d unless --out-root names a
#   directory that does not exist or is empty; a non-empty --out-root is refused.
#   The pack holds contract.md (a short header plus the policy's reviewer block, copied byte
#   for byte between its two marker lines), target.md, request.md and context-<name> for
#   each --request and --context file, head.txt, ci-evidence.md and an empty diff.patch,
#   which is the layout data/review-lane/run-review.sh takes (pass diff.patch).
#   target.md is built only from the contract's known sections, each copied byte for byte.
#   A heading is known when its name, after lower-casing, is on CONTRACT_SECTIONS, alone or
#   followed by a qualifier made only of QUALIFIER_WORDS, numbers, short ids such as a2 or
#   r19, corr=<hex> and the punctuation ( ) , ; : and dashes. After the first heading, a
#   known name followed only by any parenthetical, or by a comma or colon and text, is that
#   known section too (Main 1947), and the excluded record lists it as qualified; a known
#   name followed by free words is not. Inside a known section a
#   sub-heading must be on CONTRACT_SUBSECTIONS or, inside the Definition Of Done, have the
#   one owned criterion-title form "<title> - mandatory" or "<title> - supporting" (any dash)
#   with no CRITERION_TITLE_TERMS word in <title>; a known section name nested deeper starts
#   that section.
#   Headings are ATX (# to ######), setext (a line over === or ---) and bold-only lines
#   (**Name** or __Name__), which count as the deepest sub-heading; text in a code fence is
#   never a heading.
#   The file's first level 1 heading is its known section when it is one, and otherwise the
#   title, which is dropped and listed; the one owned title form "# Definition of done: <key>"
#   (a key of letters, digits, dots, dashes and underscores), which every contract in this
#   home opens with, is the title.
#   Dropped and listed by heading in the excluded record (dropped lines): the title; every
#   section whose heading is not known, with everything below it; and text outside any
#   known section.
#   Refused with exit 3, nothing written: an unknown sub-heading inside a known section
#   (dropping it could drop part of a criterion); a first level 1 heading that starts with a
#   known section name but is not one (it is neither proven a section nor proven a title); a
#   criterion sub-section name (on CONTRACT_SUBSECTIONS only) outside a known section; a
#   Definition Of Done that holds no text; and a code fence that never closes.
#   A contract with no Definition Of Done section exits 2.
#   The request and each context file are admitted whole by role (Main or the owner supplies
#   them), with no filter, and the excluded record lists each as admitted-whole-by-role.
#   Known limit: who wrote a text cannot be proven from the text, so author text placed in a
#   request, a context file or a known contract section reaches the reviewer. It must never
#   be put there.
#   The excluded record is <out-root>.excluded-paths, outside the pack. It always holds the
#   real path of every input file (the contract, the request, each context file), the
#   register and history paths when given, and every --exclude path. It also records the
#   reviewer's work folder by the entrypoint's one rule (data/review-lane/run-review.sh line
#   63, its owner): <work-root>/<basename of the pack's parent>-<basename of the pack>, which
#   for <out-root>/pack is <work-root>/<out-root basename>-pack; --work-root defaults to
#   $REVIEW_WORK_ROOT, else /private/tmp/fm-review-work, the entrypoint's own default, so pass
#   the same work root to both, and give the entrypoint the pack folder itself. A pack runs
#   in place, from <out-root>/pack: a pack copied or moved elsewhere is refused by the check,
#   which is the intended fail-closed result. The policy is
#   --policy, else the skill next to this script.
# check: reads the run's session transcript (--log: the entrypoint's omp-session folder,
#   or one of its .jsonl files) and judges every read it records. The report's own
#   Inputs read list is the reviewer's declaration and is not evidence.
#   Judged reads: read and edit paths (a trailing :selector such as :raw:1-11 or :-1 is
#   removed one segment at a time; the read is authorized when the path or one of these
#   shorter forms is), and grep, glob and find roots.
#   Every session record must name a folder under the recorded work folder, else the round
#   is void: the transcript never chooses its own work folder.
#   Authorized: anything inside the pack; the recorded work folder, except the entrypoint's
#   OPERATIONAL-BOUNDARIES.md copy there; the transcript itself;
#   the SKILL.md of assess-done-and-grade or define-done-and-grading, by path or as
#   skill://<name>; the review rubric, by path or by the pinned raw.githubusercontent.com
#   or github.com blob URL of this repository's origin; a file the manifest's root tracks;
#   and a search root under the root whose search reaches no untracked file (and, unless the
#   call sets gitignore true, no ignored file). A path in the excluded record is refused
#   even when tracked. Every other read, search or scheme is an INPUT LEAK, including every
#   agent://, artifact://, proc:// and history:// record: none can be proven to be this run's.
#   Not provable, so never clean: a bash or eval call, any other tool that can read, and a
#   subagent whose transcript the log does not hold (a single-file log never holds one).
#   Prints INPUT LEAK lines and ROUND VOID (exit 3) on any leak; otherwise INPUT UNVERIFIED
#   lines and ROUND UNVERIFIED (exit 4) when a read cannot be proven; otherwise INPUT CLEAN
#   (exit 0). A log that records no tool call exits 2.
#   Skill directory: $REVIEW_SKILLS_DIR, default ~/.agents/skills. Rubric: $REVIEW_RUBRIC,
#   else $REVIEW_FM_ROOT/docs/review-rubric.md (the entrypoint's own variables), else this
#   repository's docs/review-rubric.md; its pinned revision is $REVIEW_RUBRIC_REV, else the
#   last commit that touched it.
# Exit codes: 0 ok, 2 usage or bad input, 3 refused build or input leak, 4 unverified reads.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

die() {
  echo "fm-contract-review-pack: $*" >&2
  exit 2
}

usage() {
  sed -n '2,/^set -u/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

# Real path of a file that may not exist (symlinks resolved on the existing part).
real() {
  python3 -I -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "$1"
}

sha_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

BLOCK_BEGIN='<!-- reviewer-block:begin -->'
BLOCK_END='<!-- reviewer-block:end -->'

# The allow-list of known contract sections. A change here changes what every reviewer sees.
CONTRACT_SECTIONS="request|context|captain's intent|captain intent|rulings|rulings on this contract|terms|amendment|definition of done|how you're graded|how you are graded|assumptions|decisive scenario|out of scope|known limits|hard gates|execution constraints|honesty rule|mandatory items|supporting items"
CONTRACT_SUBSECTIONS="mandatory|mandatory items|supporting|supporting items|hard gates|honesty rule|out of scope"
QUALIFIER_WORDS="verbatim from main steer task neutral facts with sources disclosed not criteria execution constraints withdrawn and revision"
# Words that, anywhere in a criterion title, mark it as author material rather than a criterion
# (Main 1904 F1); such a title is an unknown sub-heading.
CRITERION_TITLE_TERMS="responses|response|answered|findings|finding|owner background|contract review|review history|revision log|revision history|author|author's|authors|self-check|all-green|boundary dispositions|prior review|suggested attack|register|notes from"

# Section filter, run under LC_ALL=C so byte escapes match. Reads the contract and writes the
# admitted text to KEEP_OUT, one excluded-record line per drop to DROP_OUT, one line per
# refusal to REFUSE_OUT, and the base name of every admitted section to NAMES_OUT.
# shellcheck disable=SC2016 # awk program, not shell
SECTION_AWK='
function norm(t) {
  t = tolower(t)
  gsub(/\342\200\231/, "'"'"'", t)
  gsub(/[ \t]+#+[ \t]*$/, "", t)
  gsub(/^[ \t]+|[ \t:]+$/, "", t)
  return t
}
function qual_ok(q,   n, i, w, ws) {
  gsub(/\342\200\224|\342\200\223/, " ", q)
  gsub(/[(),;:]/, " ", q)
  n = split(q, ws, /[ \t]+/)
  for (i = 1; i <= n; i++) {
    w = ws[i]
    if (w == "" || w == "-" || w ~ /^[0-9]+$/ || w ~ /^corr=[0-9a-f]+$/ || w ~ /^[a-z][0-9]+$/) continue
    if (index(" " QW " ", " " w " ") == 0) return 0
  }
  return 1
}
# The allow-listed base name a heading carries, or "".
function known(t, list,   n, i, parts, b, q) {
  t = norm(t)
  n = split(list, parts, "|")
  for (i = 1; i <= n; i++) {
    b = parts[i]
    if (b == "") continue
    if (t == b) return b
    if (index(t, b) == 1) {
      q = substr(t, length(b) + 1)
      if (q ~ /^[ \t(,:]/ && qual_ok(q)) return b
    }
  }
  return ""
}
# known() for every heading after the first: a known name followed only by a qualifier (a
# parenthetical, or a comma or colon and text) is that known section too (Main 1947).
function known_q(t, list,   b, n, i, parts, q) {
  b = known(t, list)
  if (b != "") return b
  t = norm(t)
  n = split(list, parts, "|")
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || index(t, parts[i]) != 1) continue
    q = substr(t, length(parts[i]) + 1)
    if (q ~ /^[ \t]*(\(.*\)|[,:][ \t]*[^ \t].*)$/) return parts[i]
  }
  return ""
}
# List an admitted heading that carries a qualifier, so the excluded record shows the match.
function note_qualified(t, b) {
  if (norm(t) != b) print "qualified\t" t2 " (as: " b ")" > DROP_OUT
}
function criterion(t,   title, n, i, parts) {
  t = norm(t)
  gsub(/\342\200\224|\342\200\223/, "-", t)
  if (t !~ /[^ \t][ \t]+-[ \t]*(mandatory|supporting)$/) return 0
  title = t
  sub(/[ \t]+-[ \t]*(mandatory|supporting)$/, "", title)
  n = split(CT, parts, "|")
  for (i = 1; i <= n; i++)
    if (parts[i] != "" && (" " title " ") ~ ("[^a-z0-9]" parts[i] "[^a-z0-9]")) return 0
  return 1
}
# True when a heading starts with a known section name, whatever follows it.
function starts_known(t,   n, i, parts) {
  t = norm(t)
  n = split(SECTIONS, parts, "|")
  for (i = 1; i <= n; i++)
    if (parts[i] != "" && index(t, parts[i]) == 1 && substr(t, length(parts[i]) + 1) !~ /^[a-z0-9]/) return 1
  return 0
}
function runlen(s, ch,   n) {
  n = 0
  while (substr(s, n + 1, 1) == ch) n++
  return n
}
function outside_flush(where) {
  if (outside) print "dropped\ttext outside a known section (" outside " line(s) " where ")" > DROP_OUT
  outside = 0
}
{ L[++N] = $0 }
END {
  fence = 0; titled = 0; insec = 0; seclv = 0; dropto = 0; outside = 0; secname = ""; dodseen = 0; dodbody = 0
  for (i = 1; i <= N; i++) {
    line = L[i]
    match(line, /^ ? ? ?/)
    rest = substr(line, RLENGTH + 1)
    infence = fence
    if (fence) {
      n = runlen(rest, fch)
      if (n >= flen && substr(rest, n + 1) ~ /^[ \t]*$/) fence = 0
    } else if (rest ~ /^~~~/ || (rest ~ /^```/ && substr(rest, runlen(rest, "`") + 1) !~ /`/)) {
      fch = substr(rest, 1, 1); flen = runlen(rest, fch); fence = 1; fline = i
    }
    body = infence || fence
    lv = 0; t = ""; two = 0
    if (!body) {
      if (rest ~ /^#+([ \t]|$)/ && runlen(rest, "#") <= 6) {
        lv = runlen(rest, "#"); t = substr(rest, lv + 1)
      } else if (i < N && L[i + 1] ~ /^ ? ? ?(=+|-+)[ \t]*$/ && line !~ /^[ \t]*$/ && line !~ /^(    |\t)/ &&
        line !~ /^[ \t]*([-*+>|]|[0-9]+[.)])([ \t]|$)/) {
        lv = (L[i + 1] ~ /=/) ? 1 : 2; t = line; two = 1
      } else if (line ~ /^[ \t]*(\*\*[^*]+\*\*|__[^_]+__):?[ \t]*$/) {
        lv = 7; t = line; gsub(/^[ \t]*(\*\*|__)|(\*\*|__):?[ \t]*$/, "", t)
      }
    }
    if (!lv) {
      if (dropto) continue
      if (insec) {
        print line > KEEP_OUT
        if (secname == "definition of done" && line !~ /^[ \t]*$/) dodbody++
        continue
      }
      if (line !~ /^[ \t]*$/) outside++
      continue
    }
    head = line
    if (two) head = line "\n" L[i + 1]
    t2 = t; gsub(/^[ \t]+|[ \t]+$/, "", t2)
    # The first level 1 heading is its known section when it is one; otherwise it is the
    # title, unless it starts with a known name it is not, which is ambiguous (Main 1904 F2).
    if (!titled && lv == 1) {
      titled = 1
      if (known(t, SECTIONS) == "") {
        outside_flush("before the title")
        # The one owned title form, "Definition of done: <key>", is the title (Main 1942 M2).
        if (starts_known(t) && norm(t) !~ /^definition of done:[ \t]+[a-z0-9][a-z0-9._-]*$/) print "a first heading that starts with a known section name but is not one: " t2 > REFUSE_OUT
        else print "dropped\ttitle: " t2 > DROP_OUT
        if (two) i++
        continue
      }
    }
    titled = 1
    if (dropto && lv <= dropto) dropto = 0
    if (dropto) { if (two) i++; continue }
    if (insec && lv > seclv) {
      if ((sb = known_q(t, SUBS)) != "" || (secname == "definition of done" && criterion(t))) {
        if (sb != "") note_qualified(t, sb)
        print head > KEEP_OUT
        if (two) i++
        continue
      }
      # A known section name nested deeper starts that section; anything else is refused.
      if (known_q(t, SECTIONS) == "") {
        print "unknown heading inside a known section: " t2 " (under: " sectitle ")" > REFUSE_OUT
        dropto = lv
        if (two) i++
        continue
      }
    }
    b = known_q(t, SECTIONS)
    outside_flush("before \"" t2 "\"")
    if (b == "" && known_q(t, SUBS) != "") {
      # A criterion sub-section name outside a known section would drop its criteria (Main 1904 F3).
      print "a criterion sub-section name outside a known section: " t2 > REFUSE_OUT
      insec = 0; dropto = lv
      if (two) i++
      continue
    }
    if (b != "") {
      note_qualified(t, b)
      insec = 1; seclv = lv; secname = b; sectitle = t2
      if (b == "definition of done") dodseen = 1
      print b > NAMES_OUT
      print head > KEEP_OUT
    } else {
      insec = 0; dropto = lv
      print "dropped\t" t2 > DROP_OUT
    }
    if (two) i++
  }
  outside_flush("at the end")
  if (fence) print "the code fence opened at line " fline " never closes" > REFUSE_OUT
  if (dodseen && !dodbody) print "the Definition Of Done holds no criterion text" > REFUSE_OUT
}
'

filter_sections() { # <file> <keep> <drop> <refuse> <names>
  : >"$2"; : >"$3"; : >"$4"; : >"$5"
  LC_ALL=C awk -v KEEP_OUT="$2" -v DROP_OUT="$3" -v REFUSE_OUT="$4" -v NAMES_OUT="$5" \
    -v SECTIONS="$CONTRACT_SECTIONS" -v SUBS="$CONTRACT_SUBSECTIONS" -v QW="$QUALIFIER_WORDS" -v CT="$CRITERION_TITLE_TERMS" \
    "$SECTION_AWK" <"$1"
}

policy_block() { # <policy> -> block with marker lines on stdout, nonzero unless exactly one pair
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b { nb++; if (nb == 1) on = 1 }
    on { print }
    $0 == e { ne++; on = 0 }
    END { exit !(nb == 1 && ne == 1) }' "$1"
}

cmd_build() {
  local contract='' request='' root='' policy='' out_root='' work_root=${REVIEW_WORK_ROOT:-/private/tmp/fm-review-work}
  local -a contexts=() excludes=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --contract) [ $# -ge 2 ] || die "--contract needs a file"; contract=$2; shift 2 ;;
      --request) [ $# -ge 2 ] || die "--request needs a file"; request=$2; shift 2 ;;
      --context) [ $# -ge 2 ] || die "--context needs a file"; contexts+=("$2"); shift 2 ;;
      --root) [ $# -ge 2 ] || die "--root needs a directory"; root=$2; shift 2 ;;
      --exclude | --register | --history)
        [ $# -ge 2 ] || die "$1 needs a path"; excludes+=("$2"); shift 2 ;;
      --policy) [ $# -ge 2 ] || die "--policy needs a file"; policy=$2; shift 2 ;;
      --out-root) [ $# -ge 2 ] || die "--out-root needs a directory"; out_root=$2; shift 2 ;;
      --work-root) [ $# -ge 2 ] || die "--work-root needs a directory"; work_root=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$contract" ] || die "--contract is required"
  [ -n "$work_root" ] || die "--work-root is empty"
  [ -n "$root" ] || die "--root is required: the repository checkout the reviewer reads, so the check can judge every read against it"
  [ -f "$contract" ] && [ -r "$contract" ] || die "contract file not readable: $contract"
  [ -z "$request" ] || { [ -f "$request" ] && [ -r "$request" ] || die "request file not readable: $request"; }
  local f
  for f in ${contexts[@]+"${contexts[@]}"}; do
    [ -f "$f" ] && [ -r "$f" ] || die "context file not readable: $f"
  done
  [ -d "$root" ] || die "root is not a directory: $root"
  [ -n "$policy" ] || policy=$FM_ROOT/.agents/skills/contract-review/SKILL.md
  [ -f "$policy" ] && [ -r "$policy" ] || die "policy file not readable: $policy"

  local scratch
  scratch=$(mktemp -d) || die "cannot create a scratch directory"
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" EXIT

  policy_block "$policy" >"$scratch/block" || die "policy must hold exactly one reviewer block between its marker lines: $policy"
  [ -s "$scratch/block" ] || die "policy reviewer block is empty: $policy"

  filter_sections "$contract" "$scratch/keep" "$scratch/dropped" "$scratch/refused" "$scratch/names" || die "section filter failed on $contract"
  if [ -s "$scratch/refused" ]; then
    local why
    while IFS= read -r why; do
      echo "fm-contract-review-pack: refused: $why" >&2
    done <"$scratch/refused"
    echo "fm-contract-review-pack: no pack written; give the text a known heading (CONTRACT_SECTIONS or CONTRACT_SUBSECTIONS in this script) or move it out of the contract" >&2
    exit 3
  fi
  grep -qx 'definition of done' "$scratch/names" || die "contract has no Definition Of Done section: $contract"

  # Out root: fresh mktemp -d unless a nonexistent or empty directory is named.
  local created_root=0 pack manifest
  if [ -z "$out_root" ]; then
    out_root=$(mktemp -d) || die "cannot create an output directory"
    created_root=1
  elif [ -e "$out_root" ]; then
    [ -d "$out_root" ] || die "out-root is not a directory: $out_root"
    if [ -n "$(ls -A "$out_root" 2>/dev/null)" ]; then
      die "out-root is not empty (it may hold a review or another pack): $out_root"
    fi
  else
    mkdir -p "$out_root" || die "cannot create out-root: $out_root"
    created_root=1
  fi
  out_root=$(cd "$out_root" && pwd -P)
  pack="$out_root/pack"
  manifest="$out_root.excluded-paths"
  [ ! -e "$manifest" ] || die "manifest already exists: $manifest"
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'; rm -f '$manifest'; if [ $created_root = 1 ]; then rm -rf '$out_root'; else rm -rf '$pack'; fi" EXIT
  mkdir "$pack" || die "cannot create pack directory: $pack"

  cp "$scratch/keep" "$pack/target.md"
  [ -z "$request" ] || cp "$request" "$pack/request.md"
  local names='' base
  for f in ${contexts[@]+"${contexts[@]}"}; do
    base=context-$(basename "$f")
    [ ! -e "$pack/$base" ] || die "two context files share the name $(basename "$f")"
    cp "$f" "$pack/$base"
    names="$names, $base"
  done
  : >"$pack/diff.patch"
  local head
  head=$(sha_of "$pack/target.md" | cut -c1-40)
  printf '%s\n' "$head" >"$pack/head.txt"
  printf '%s\n' "Not applicable: this is a definition-of-done document review. There is no PR, no head commit and no CI. The 'head' passed to the review lane is the first 40 hex digits of sha256(target.md), recorded in head.txt." >"$pack/ci-evidence.md"
  {
    printf '# Review of the definition-of-done contract\n\n'
    # shellcheck disable=SC2016 # literal backticks in generated Markdown
    printf 'Target: `target.md` in this folder (the diff slot, `diff.patch`, is empty). It is the definition of done under review. There is no PR and no CI; `ci-evidence.md` says so.\n'
    if [ -n "$request" ]; then
      # shellcheck disable=SC2016 # literal backticks in generated Markdown
      printf 'The request is `request.md`.\n'
    elif grep -qx 'request' "$scratch/names"; then
      # shellcheck disable=SC2016 # literal backticks in generated Markdown
      printf 'There is no separate request file: the request is the REQUEST section of `target.md`.\n'
    fi
    if [ -n "$names" ]; then
      printf 'Context in this folder: %s.\n' "${names#, }"
    fi
    printf '\n'
    cat "$scratch/block"
  } >"$pack/contract.md"

  {
    echo "# fm-contract-review-pack excluded record: paths the reviewer must never read, and contract text it was not given"
    printf 'pack\t%s\n' "$(real "$pack")"
    printf 'root\t%s\n' "$(real "$root")"
    # The reviewer's work folder, named the way the entrypoint names it from REVIEW_WORK_ROOT.
    printf 'work\t%s\n' "$(real "$work_root/$(basename "$(dirname "$pack")")-$(basename "$pack")")"
    printf 'exclude\t%s\n' "$(real "$contract")"
    [ -z "$request" ] || printf 'exclude\t%s\n' "$(real "$request")"
    for f in ${contexts[@]+"${contexts[@]}"} ${excludes[@]+"${excludes[@]}"}; do
      printf 'exclude\t%s\n' "$(real "$f")"
    done
    cat "$scratch/dropped"
    [ -z "$request" ] || printf 'admitted-whole-by-role\trequest\t%s\n' "$(real "$request")"
    for f in ${contexts[@]+"${contexts[@]}"}; do
      printf 'admitted-whole-by-role\tcontext\t%s\n' "$(real "$f")"
    done
  } >"$manifest"

  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" EXIT
  echo "fm-contract-review-pack: pack=$pack head=$head diff=diff.patch manifest=$manifest" >&2
  printf '%s\n' "$pack"
}

# The transcript judge. Arguments: pack, log, manifest, skills dir, rubric path, rubric
# revision, origin slug. Prints the verdict lines and exits 0, 2, 3 or 4 (see the header).
# shellcheck disable=SC2016 # python program, not shell
CHECK_PY='
import json, os, re, subprocess, sys

pack, log, manifest, skills, rubric, rubric_rev, slug = sys.argv[1:8]
real = os.path.realpath
pack = real(pack)
root = None
work_rec = None
excludes = []
for line in open(manifest, encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if f[0] == "root" and len(f) > 1 and root is None:
        root = real(f[1])
    elif f[0] == "exclude" and len(f) > 1:
        excludes.append(real(f[1]))
    elif f[0] == "work" and len(f) > 1 and work_rec is None:
        work_rec = real(f[1])
if root is None:
    print("fm-contract-review-pack: manifest has no root; rebuild the pack with --root: " + manifest, file=sys.stderr)
    sys.exit(2)
if work_rec is None:
    print("fm-contract-review-pack: excluded record has no work folder; rebuild the pack: " + manifest, file=sys.stderr)
    sys.exit(2)
named_skills = ("assess-done-and-grade", "define-done-and-grading")
skill_files = {real(os.path.join(skills, s, "SKILL.md")) for s in named_skills}
rubric_real = real(rubric) if rubric else ""
log_real = real(log)

def under(p, d):
    return p == d or p.startswith(d.rstrip("/") + "/")

genv = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR")}
def git(*args):
    return subprocess.run(["git", "-C", root] + list(args), env=genv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def tracked(rel):
    return git("ls-files", "--error-unmatch", "--", rel).returncode == 0
def untracked_below(rel, ignored_too):
    args = ["ls-files", "--others", "--directory"] + ([] if ignored_too else ["--exclude-standard"]) + ["--", rel or "."]
    r = git(*args)
    return r.returncode != 0 or r.stdout.strip() != ""

files = []
if os.path.isdir(log):
    for d, _, names in os.walk(log):
        files += [os.path.join(d, n) for n in sorted(names) if n.endswith(".jsonl")]
else:
    files.append(log)
child_names = set()
if os.path.isdir(log):
    child_names = {os.path.basename(f)[:-6] for f in files if os.path.dirname(real(f)) != log_real}

work = work_rec
calls = 0
judged = 0
leaks = []
unverified = []
NOT_READS = {"write", "todo", "wait", "ask", "notebook_edit"}
# Internal records no read can prove belong to this run (Main 1904 F4).
INTERNAL = ("agent", "artifact", "proc", "history")

def excluded(p):
    for x in excludes:
        if under(p, x) or (os.path.isdir(p) and under(x, p)):
            return x
    return None

def why_file(p):
    x = excluded(p)
    if x:
        return "excluded path " + x
    if under(p, pack) or under(p, log_real):
        return None
    if work and under(p, work):
        if p == os.path.join(work, "OPERATIONAL-BOUNDARIES.md"):
            return "the entrypoint copy of OPERATIONAL-BOUNDARIES.md, which is not an authorized input"
        return None
    if p in skill_files or (rubric_real and p == rubric_real):
        return None
    if under(p, root):
        if p != root and tracked(os.path.relpath(p, root)):
            return None
        return "untracked or gitignored file under the root"
    return "outside the allowed inputs"

def why_search(p, ignored_too):
    x = excluded(p)
    if x:
        return "a search that reaches excluded path " + x
    if under(p, pack) or under(p, log_real):
        return None
    if work and under(p, work):
        opb = os.path.join(work, "OPERATIONAL-BOUNDARIES.md")
        if under(opb, p) and os.path.exists(opb):
            return "a search of the work folder, which holds the entrypoint copy of OPERATIONAL-BOUNDARIES.md"
        return None
    if os.path.isfile(p):
        return why_file(p)
    if under(p, root):
        rel = "" if p == root else os.path.relpath(p, root)
        if untracked_below(rel, ignored_too):
            return "a search that reaches untracked " + ("or ignored " if ignored_too else "") + "files under the root"
        return None
    return "a search outside the allowed inputs"

def judge_read(raw, cwd):
    m = re.match(r"^([a-z][a-z0-9+.-]*)://(.*)$", raw)
    if m:
        scheme, rest = m.group(1), m.group(2)
        if scheme == "skill":
            name = rest.rstrip("/")
            if name in named_skills or (name.endswith("/SKILL.md") and name[:-9] in named_skills):
                return None
            return "a skill path other than the SKILL.md of the two named skills"
        if scheme in ("http", "https"):
            pinned = ["https://raw.githubusercontent.com/%s/%s/docs/review-rubric.md" % (slug, rubric_rev),
                      "https://github.com/%s/blob/%s/docs/review-rubric.md" % (slug, rubric_rev)]
            if slug and rubric_rev and raw in pinned:
                return None
            return "a URL other than the pinned rubric revision of this repository"
        if scheme in INTERNAL:
            return "an internal " + scheme + ":// record, which cannot be proven to belong to this run"
        return "a " + scheme + ":// read outside the allowed inputs"
    p = os.path.normpath(os.path.join(cwd, os.path.expanduser(raw)))
    first = None
    while True:
        w = why_file(real(p))
        if w is None:
            return None
        first = first or w
        head, sep, tail = p.rpartition(":")
        if not sep or "/" in tail or not head:
            return first
        p = head

def search_roots(raw, cwd):
    for part in [x.strip() for x in str(raw).split(";")]:
        if not part:
            continue
        comps = []
        for c in os.path.expanduser(part).split("/"):
            if re.search(r"[*?\[{]", c):
                break
            comps.append(c)
        yield os.path.normpath(os.path.join(cwd, "/".join(comps) or "."))

for f in files:
    cwd = None
    try:
        lines = open(f, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as e:
        unverified.append((f, "transcript file cannot be read: " + str(e)))
        continue
    for line in lines:
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        if o.get("type") == "session" and o.get("cwd"):
            cwd = o["cwd"]
            # The work folder comes from the excluded record, never from the transcript (Main 1904 F5).
            if not under(real(cwd), work):
                leaks.append((cwd, "the session ran outside the recorded work folder " + work))
        msg = o.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None
        if not isinstance(content, list):
            continue
        for c in content:
            if not isinstance(c, dict) or c.get("type") != "toolCall":
                continue
            calls += 1
            name = c.get("name") or ""
            a = c.get("arguments") if isinstance(c.get("arguments"), dict) else {}
            if cwd is None:
                unverified.append((f, "a tool call before any session record, so its folder is not known"))
                cwd = work
            here = a.get("cwd") or cwd
            if name in ("read", "edit"):
                p = str(a.get("path") or "")
                if not p:
                    continue
                judged += 1
                w = judge_read(p, here)
                if w:
                    leaks.append((p, w))
            elif name in ("grep", "glob", "find"):
                # Only an explicit gitignore setting proves a search skips ignored files.
                g = a.get("gitignore")
                ignored_too = not (g is True or str(g).lower() == "true")
                for d in search_roots(a.get("path") or ".", here):
                    judged += 1
                    w = why_search(real(d), ignored_too)
                    if w:
                        leaks.append((d, w))
            elif name == "task":
                for t in a.get("tasks") or []:
                    n = (t or {}).get("name") or "?"
                    if n not in child_names:
                        unverified.append(("subagent " + n, "its transcript is not in the log, so its reads cannot be audited"))
            elif name in NOT_READS:
                continue
            else:
                unverified.append((name + " call", "its reads are not recorded as paths, so they cannot be audited"))

if calls == 0:
    print("fm-contract-review-pack: log records no tool call, so it is not a session transcript and the run reads cannot be audited: " + log, file=sys.stderr)
    sys.exit(2)

def uniq(xs):
    seen = []
    for x in xs:
        if x not in seen:
            seen.append(x)
    return seen

if leaks:
    for p, w in uniq(leaks):
        print("INPUT LEAK: %s: %s" % (p, w))
    print("ROUND VOID: %d input leak(s); rerun on a fresh pack, and do not count this round" % len(uniq(leaks)))
    sys.exit(3)
if unverified:
    for p, w in uniq(unverified):
        print("INPUT UNVERIFIED: %s: %s" % (p, w))
    print("ROUND UNVERIFIED: the transcript holds reads that cannot be proven; the round is not clean")
    sys.exit(4)
print("INPUT CLEAN: %d recorded read(s), all authorized" % judged)
'

cmd_check() {
  local pack='' log='' manifest=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --pack) [ $# -ge 2 ] || die "--pack needs a directory"; pack=$2; shift 2 ;;
      --log) [ $# -ge 2 ] || die "--log needs the run's session transcript"; log=$2; shift 2 ;;
      --manifest) [ $# -ge 2 ] || die "--manifest needs a file"; manifest=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -d "$pack" ] || die "pack is not a directory: $pack"
  [ -n "$log" ] || die "--log is required: the run's session transcript (the entrypoint's omp-session folder or one of its .jsonl files)"
  { [ -f "$log" ] || [ -d "$log" ]; } && [ -r "$log" ] || die "log not readable: $log"
  pack=$(real "$pack")
  [ -n "$manifest" ] || manifest="$(dirname "$pack").excluded-paths"
  [ -f "$manifest" ] && [ -r "$manifest" ] || die "manifest not readable: $manifest"
  [ "$(awk -F '\t' '$1 == "pack" { print $2; exit }' "$manifest")" = "$pack" ] || die "manifest does not belong to this pack: $manifest"

  local skills fmroot rubric rubric_rev origin slug
  skills=${REVIEW_SKILLS_DIR:-$HOME/.agents/skills}
  fmroot=${REVIEW_FM_ROOT:-$FM_ROOT}
  rubric=${REVIEW_RUBRIC:-$fmroot/docs/review-rubric.md}
  rubric_rev=${REVIEW_RUBRIC_REV:-$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$fmroot" log -1 --format=%H -- docs/review-rubric.md 2>/dev/null)}
  origin=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$fmroot" remote get-url origin 2>/dev/null || true)
  slug=$(printf '%s' "$origin" | sed -nE 's#^(https?://[^/]*github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' | sed -E 's#\.git$##')
  python3 -I -c "$CHECK_PY" "$pack" "$log" "$manifest" "$skills" "$rubric" "$rubric_rev" "$slug"
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  check) shift; cmd_check "$@" ;;
  build) shift; cmd_build "$@" ;;
  '') usage; exit 2 ;;
  *) cmd_build "$@" ;;
esac
