#!/usr/bin/env bash
# Build the clean reviewer input for an independent review of a definition-of-done
# contract, and check afterwards that the reviewer read only what it was given.
# The rules live in .agents/skills/contract-review/SKILL.md (the one owner); this
# script is the only code path that assembles contract-review reviewer input.
#
# usage:
#   fm-contract-review-pack.sh [build] --contract <file> [--request <file>]
#       [--context <file>]... [--root <repo-root>]
#       [--exclude <path>]...
#       [--register <path>] [--history <path>] [--policy <file>]
#       [--out-root <dir>] [--label <text>]
#   fm-contract-review-pack.sh check --pack <dir> --report <file>
#       [--log <file>] [--manifest <file>]
#
# build: prints the pack directory on stdout, and nothing else there.
#   The pack is <out-root>/pack. <out-root> is a fresh mktemp -d unless --out-root
#   names a directory that does not exist or is empty. A non-empty --out-root, or
#   one that already holds a pack or a review.md, is refused.
#   The pack holds contract.md (a short header plus the policy's reviewer block,
#   copied byte for byte between its two marker lines), target.md (the contract
#   without the author's sections), request.md and context-<name> for each
#   --request and --context file, head.txt, ci-evidence.md and an empty diff.patch,
#   which is the layout data/review-lane/run-review.sh takes (pass diff.patch).
#   The author's sections are dropped by heading. A level 1 or 2 heading (ATX `#`/`##`
#   or setext, a title line over `===` or `---`) the builder does not recognise stops
#   the build with exit 3 naming it, and nothing is written. So does a code fence that
#   never closes.
#   Under a kept section, a sub-heading the builder does not recognise (an unknown
#   level 3 heading, a level 4 or deeper heading or a bold-only line) stays in
#   target.md where it is, and so does a preamble line it does not drop; each is
#   listed in the manifest as unrecognised. No contract text is dropped without a
#   dropped line in the manifest.
#   The request and each context file go through the same filter and are copied
#   whole; one that holds text the filter would drop (an author section or an author
#   preamble line) is refused with exit 2, and one whose unrecognised heading names
#   author history (findings, answered, response, self-check, all-green, revision log,
#   prior) is refused with exit 3.
#   The manifest of excluded paths is <out-root>.excluded-paths, outside the pack.
#   It always holds the real path of every input file (the contract, the request,
#   each context file), the register and history paths when given, and every
#   --exclude path. The policy is --policy, else $FM_CONTRACT_REVIEW_POLICY, else
#   the skill next to this script.
# check: reads the report's `Inputs read` list and, when given, the run log, and
#   prints INPUT LEAK lines plus ROUND VOID (exit 3) when the list is missing or a
#   listed path is not an authorized input; prints INPUT CLEAN (exit 0) otherwise.
#   The list must sit under a Markdown heading of its own; an `Inputs read` bold line,
#   `Label:` line or inline list with no heading voids the round. The list runs to the
#   next heading of its own level or higher, and a line in it that does not start with a
#   path is skipped.
#   An authorized input is judged by what it is: a file inside the pack, the
#   SKILL.md of the assess-done-and-grade or define-done-and-grading skill (no other
#   file in either skill folder), the review rubric, or a file the manifest's root tracks (git ls-files, or
#   <rev>:<path> that git can read), and <pinned rubric revision>:docs/review-rubric.md.
#   A path in the manifest's excluded set is
#   refused even when it is tracked. A gitignored file is not tracked.
#   Two exact exemptions: the pinned rubric read by URL (raw.githubusercontent.com or
#   github.com blob URL of this repository's origin at exactly the rubric revision the
#   entrypoint pins; any other URL, repository or revision is a leak), and the run's own
#   report and log (--report, --log, and the entrypoint's work-root review.md for this
#   pack; no other review.md).
#   Skill directory: $REVIEW_SKILLS_DIR, default ~/.agents/skills. Rubric:
#   $REVIEW_RUBRIC, else $REVIEW_FM_ROOT/docs/review-rubric.md (the entrypoint's
#   own variables), else this repository's docs/review-rubric.md.
# Exit codes: 0 ok, 2 usage or bad input, 3 unrecognised section, unclosed fence or input leak.
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

# Section filter. Reads the contract on stdin, writes the kept text to the file
# named by KEEP_OUT, the dropped section names to DROPPED_OUT, the unrecognised
# level 1 and 2 headings to UNKNOWN_OUT, the kept but unrecognised sub-headings
# and preamble lines to UNREC_OUT and the normalised title of every kept heading to
# TITLES_OUT. Headings of level 1 and 2, ATX or setext, start a
# section and must be recognised; a level 3 heading is dropped when it names an
# author section. Text inside a code fence is never a heading, a backtick fence opens
# only when no backtick follows its marker run on that line, a fence closes only
# on a run of its own marker at least as long as the opening one, and a fence still
# open at the end exits 3.
# shellcheck disable=SC2016 # awk program, not shell
SECTION_AWK='
function norm(t) {
  t = tolower(t)
  gsub(/\342\200\231/, "'"'"'", t)
  gsub(/^[ \t]+|[ \t]+$/, "", t)
  return t
}
function classify(t,   i, n, parts) {
  n = split(DROP, parts, "|")
  for (i = 1; i <= n; i++) if (parts[i] != "" && index(t, parts[i]) == 1) return "drop"
  n = split(KEEP, parts, "|")
  for (i = 1; i <= n; i++) if (parts[i] != "" && index(t, parts[i]) == 1) return "keep"
  return "unknown"
}
function runlen(s, ch,   n) {
  n = 0
  while (substr(s, n + 1, 1) == ch) n++
  return n
}
function keep_heading(s) {
  print s > KEEP_OUT
  print norm(title) > TITLES_OUT
  if (ul != "") print ul > KEEP_OUT
}
{ L[++N] = $0 }
END {
  mode = "keep"; parent = "keep"; ptitle = "preamble"; seen_heading = 0; fence = 0; pre = 1
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
    level = 0; title = ""; ul = ""
    if (!body) {
      if (rest ~ /^####+[ \t]/) level = 4
      else if (rest ~ /^### /) { level = 3; title = substr(rest, 5) }
      else if (rest ~ /^## /) { level = 2; title = substr(rest, 4) }
      else if (rest ~ /^# /) { level = 1; title = substr(rest, 3) }
      else if (i < N && L[i + 1] ~ /^ ? ? ?(=+|-+)[ \t]*$/ && line !~ /^[ \t]*$/ && line !~ /^(    |\t)/ &&
        line !~ /^[ \t]*([-*+>|]|[0-9]+[.)])([ \t]|$)/) {
        ul = L[++i]
        level = (ul ~ /=/) ? 1 : 2
        title = line
      }
    }
    if (level == 1 && !seen_heading) {
      seen_heading = 1
      keep_heading(line)
      continue
    }
    if (level == 1 || level == 2) {
      seen_heading = 1
      pre = 0
      c = classify(norm(title))
      parent = c
      ptitle = title
      if (c == "keep") mode = "keep"
      else if (c == "drop") { mode = "drop"; print title > DROPPED_OUT }
      else { mode = "drop"; print title > UNKNOWN_OUT }
      if (mode == "keep") keep_heading(line)
      continue
    }
    if (level == 3) {
      c = classify(norm(title))
      if (parent == "keep" && c != "drop") mode = "keep"
      else mode = "drop"
      if (c == "drop") print title > DROPPED_OUT
      if (mode == "keep") {
        if (c == "unknown") print line " (under: " ptitle ")" > UNREC_OUT
        keep_heading(line)
      }
      continue
    }
    if (mode == "keep") {
      if (pre && tolower(line) ~ PREAMBLE_DROP) { print "preamble line: " line > DROPPED_OUT; continue }
      if (level == 4 || (!body && (line ~ /^[ \t]*\*\*[^*]+\*\*:?[ \t]*$/ || line ~ /^[ \t]*__[^_]+__:?[ \t]*$/))) print line " (under: " ptitle ")" > UNREC_OUT
      else if (pre && line !~ /^[ \t]*$/) print "preamble line: " line > UNREC_OUT
      print line > KEEP_OUT
    }
  }
  if (fence) {
    print "fm-contract-review-pack: " SRC ": the code fence opened at line " fline " never closes; no pack written" > "/dev/stderr"
    exit 3
  }
}
'

SECTION_KEEP="request|context|captain's intent|captain intent|rulings|terms|amendment|definition of done|how you're graded|how you are graded|assumptions|decisive scenario|out of scope|known limits|hard gates|execution constraints|honesty rule|supporting"
SECTION_DROP="author self-check|author's all-green|author all-green|all-green|author's|author notes|boundary dispositions|contract review|review history|revision log|revision history|self-check|prior findings|prior review|responses|response to|suggested attack|open findings|finding register|register"
# A preamble line that holds author text. Whole words only, so Authority, Authorized and
# Authoritative stay. The contract drops such a line wherever the word sits in it. A request
# or context file is the captain's or Main's text, which may name these terms as its subject
# ("Run a contract review"), so it is refused only for the author shapes: a term used as a
# label (`Self-check:`, `Author:`), or a term attributed to an author or worker
# (`Author's analysis`, `Worker self-check`).
PREAMBLE_DROP='(^|[^a-z0-9])(authors?|contract review|all-green|self-check|review exit|prior findings?|revision log)([^a-z0-9]|$)|reviewed:'
PREAMBLE_TERMS='self-checks?|all-green|contract reviews?|review exits?|prior findings?|revision logs?'
PREAMBLE_REFUSE="(^|[^a-z0-9])((authors?|workers?)[^a-z0-9]*s?[ ]+($PREAMBLE_TERMS|analysis|notes?|candidates?|dispositions?|findings?|responses?)([^a-z0-9]|\$)|(authors?|$PREAMBLE_TERMS)[ ]*:)|reviewed:"

# An unrecognised heading in a request or context file that names author history anywhere
# in its text. Free owner headings ("Current review authority") hold none of these words.
HISTORY_HEADING='(^|[^a-z0-9])(findings?|answered|responses?|self-checks?|all-green|revision logs?|prior)([^a-z0-9]|$)'

filter_sections() { # <in> <keep-out> <dropped-out> <unknown-out> <unrecognised-out> <titles-out> [preamble-pattern]
  local pre=${7:-$PREAMBLE_DROP}
  : >"$2"
  : >"$3"
  : >"$4"
  : >"$5"
  : >"$6"
  awk -v SRC="$1" -v KEEP_OUT="$2" -v DROPPED_OUT="$3" -v UNKNOWN_OUT="$4" -v UNREC_OUT="$5" -v TITLES_OUT="$6" \
    -v KEEP="$SECTION_KEEP" -v DROP="$SECTION_DROP" -v PREAMBLE_DROP="$pre" \
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
  local contract='' request='' root='' policy='' out_root='' label=''
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
      --label) [ $# -ge 2 ] || die "--label needs text"; label=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -n "$contract" ] || die "--contract is required"
  [ -f "$contract" ] && [ -r "$contract" ] || die "contract file not readable: $contract"
  [ -z "$request" ] || { [ -f "$request" ] && [ -r "$request" ] || die "request file not readable: $request"; }
  local f
  for f in ${contexts[@]+"${contexts[@]}"}; do
    [ -f "$f" ] && [ -r "$f" ] || die "context file not readable: $f"
  done
  [ -z "$root" ] || [ -d "$root" ] || die "root is not a directory: $root"
  [ -n "$policy" ] || policy=${FM_CONTRACT_REVIEW_POLICY:-$FM_ROOT/.agents/skills/contract-review/SKILL.md}
  [ -f "$policy" ] && [ -r "$policy" ] || die "policy file not readable: $policy"

  local scratch
  scratch=$(mktemp -d) || die "cannot create a scratch directory"
  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" EXIT

  policy_block "$policy" >"$scratch/block" || die "policy must hold exactly one reviewer block between its marker lines: $policy"
  [ -s "$scratch/block" ] || die "policy reviewer block is empty: $policy"

  filter_sections "$contract" "$scratch/keep" "$scratch/dropped" "$scratch/unknown" "$scratch/unrec" "$scratch/titles" || exit 3
  if [ -s "$scratch/unknown" ]; then
    local name
    while IFS= read -r name; do
      echo "fm-contract-review-pack: unrecognised section: $name" >&2
    done <"$scratch/unknown"
    echo "fm-contract-review-pack: no pack written; rename the section to a recognised one or add it to the builder" >&2
    exit 3
  fi
  grep -q '^definition of done' "$scratch/titles" || die "contract has no Definition Of Done section: $contract"

  for f in ${request:+"$request"} ${contexts[@]+"${contexts[@]}"}; do
    filter_sections "$f" "$scratch/ctx.keep" "$scratch/ctx.dropped" "$scratch/ctx.unknown" "$scratch/ctx.unrec" "$scratch/ctx.titles" "$PREAMBLE_REFUSE" || exit 3
    [ ! -s "$scratch/ctx.dropped" ] || die "request or context file holds author text the builder would drop ($(head -1 "$scratch/ctx.dropped")): $f"
    { cat "$scratch/ctx.unknown"; grep -v '^preamble line: ' "$scratch/ctx.unrec" | sed 's/ (under: [^)]*)$//'; } |
      grep -iE "$HISTORY_HEADING" >"$scratch/ctx.history"
    if [ -s "$scratch/ctx.history" ]; then
      while IFS= read -r name; do
        echo "fm-contract-review-pack: unrecognised section: $name (author history in $f)" >&2
      done <"$scratch/ctx.history"
      echo "fm-contract-review-pack: no pack written; move the author history out of the request or context file" >&2
      exit 3
    fi
  done

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
    printf '# Review of the definition-of-done contract%s\n\n' "${label:+: $label}"
    # shellcheck disable=SC2016 # literal backticks in generated Markdown
    printf 'Target: `target.md` in this folder (the diff slot, `diff.patch`, is empty). It is the definition of done under review. There is no PR and no CI; `ci-evidence.md` says so.\n'
    if [ -n "$request" ]; then
      # shellcheck disable=SC2016 # literal backticks in generated Markdown
      printf 'The request is `request.md`.\n'
    elif grep -q '^request' "$scratch/titles"; then
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
    echo "# fm-contract-review-pack manifest: paths the reviewer must never read"
    printf 'pack\t%s\n' "$(real "$pack")"
    [ -z "$root" ] || printf 'root\t%s\n' "$(real "$root")"
    printf 'exclude\t%s\n' "$(real "$contract")"
    [ -z "$request" ] || printf 'exclude\t%s\n' "$(real "$request")"
    for f in ${contexts[@]+"${contexts[@]}"} ${excludes[@]+"${excludes[@]}"}; do
      printf 'exclude\t%s\n' "$(real "$f")"
    done
    while IFS= read -r f; do
      printf 'dropped\t%s\n' "$f"
    done <"$scratch/dropped"
    while IFS= read -r f; do
      printf 'unrecognised\t%s\n' "$f"
    done <"$scratch/unrec"
  } >"$manifest"

  # shellcheck disable=SC2064
  trap "rm -rf '$scratch'" EXIT
  echo "fm-contract-review-pack: pack=$pack head=$head diff=diff.patch manifest=$manifest" >&2
  printf '%s\n' "$pack"
}

# Print the entries of the report's `Inputs read` list, one per line.
inputs_read() { # <report>
  awk '
    function entry(s,   t) {
      sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", s)
      gsub(/^[ \t]+/, "", s)
      if (substr(s, 1, 1) == "`") {
        t = substr(s, 2)
        sub(/`.*/, "", t)
      } else {
        t = s
        sub(/[ \t].*/, "", t)
      }
      gsub(/^[`*"(<]+|[`*",;:.)>]+$/, "", t)
      return t
    }
    function hlevel(s,   n) {
      n = 0
      while (substr(s, n + 1, 1) == "#") n++
      return n
    }
    {
      l = $0
      sub(/^ ? ? ?/, "", l)
      low = tolower(l)
    }
    # The list starts at a heading of its own. Any other `Inputs read` line (bold, a
    # `Label:` line or an inline list) has no heading and voids the round (exit 4).
    low ~ /^#+[ \t]+[*]*([0-9]+[.)][ \t]*)?[*]*inputs read[*[:space:]]*(\([^)]*\))?[*:[:space:]]*$/ { start = hlevel(l); state = 1; next }
    low ~ /^[#*[:space:]-]*([0-9]+[.)][[:space:]]*)?[*]*inputs read[*]*(:|[*[:space:]]*(\([^)]*\))?[*:[:space:]]*$)/ { noheading = 1; next }
    # Inside the list: every line up to the next heading of the same or a higher level is
    # read, and a line that does not start with a path is skipped.
    state == 1 {
      if (l ~ /^#/ && hlevel(l) <= start) { state = 2; next }
      line = $0
      sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/, "", line)
      if (line ~ /^`?[^ \t`]*[\/]/ || line ~ /^`?~/ || line ~ /^`?[A-Za-z0-9_.-]+\.[A-Za-z0-9]+(`|[ \t]|$)/) {
        t = entry($0)
        if (t != "") print t
      }
    }
    END { exit noheading ? 4 : 0 }
  ' "$1"
}

manifest_lines() { # <manifest> <kind>
  awk -F '\t' -v k="$2" '$1 == k { print $2 }' "$1"
}

path_under() { # <path> <dir>: true when path equals dir or lies below it
  [ "$1" = "$2" ] && return 0
  case "$1" in "$2"/*) return 0 ;; esac
  return 1
}

cmd_check() {
  local pack='' report='' log='' manifest=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --pack) [ $# -ge 2 ] || die "--pack needs a directory"; pack=$2; shift 2 ;;
      --report) [ $# -ge 2 ] || die "--report needs a file"; report=$2; shift 2 ;;
      --log) [ $# -ge 2 ] || die "--log needs a file"; log=$2; shift 2 ;;
      --manifest) [ $# -ge 2 ] || die "--manifest needs a file"; manifest=$2; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) die "unknown argument: $1" ;;
    esac
  done
  [ -d "$pack" ] || die "pack is not a directory: $pack"
  [ -f "$report" ] && [ -r "$report" ] || die "report not readable: $report"
  [ -z "$log" ] || { [ -f "$log" ] && [ -r "$log" ] || die "log not readable: $log"; }
  pack=$(real "$pack")
  [ -n "$manifest" ] || manifest="$(dirname "$pack").excluded-paths"
  [ -f "$manifest" ] && [ -r "$manifest" ] || die "manifest not readable: $manifest"
  [ "$(manifest_lines "$manifest" pack | head -1)" = "$pack" ] || die "manifest does not belong to this pack: $manifest"

  local root skills fmroot rubric rubric_real
  root=$(manifest_lines "$manifest" root | head -1)
  skills=${REVIEW_SKILLS_DIR:-$HOME/.agents/skills}
  fmroot=${REVIEW_FM_ROOT:-$FM_ROOT}
  rubric=${REVIEW_RUBRIC:-$fmroot/docs/review-rubric.md}
  rubric_real=$(real "$rubric")
  local assess_dir define_dir
  assess_dir=$(real "$skills/assess-done-and-grade")
  define_dir=$(real "$skills/define-done-and-grading")

  local rubric_rev slug origin report_real log_real work_report
  rubric_rev=${REVIEW_RUBRIC_REV:-$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$fmroot" log -1 --format=%H -- docs/review-rubric.md 2>/dev/null)}
  origin=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$fmroot" remote get-url origin 2>/dev/null || true)
  slug=$(printf '%s' "$origin" | sed -nE 's#^(https?://[^/]*github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+)$#\2#p' | sed -E 's#\.git$##')
  report_real=$(real "$report")
  log_real=''
  [ -z "$log" ] || log_real=$(real "$log")
  work_report=$(real "${REVIEW_WORK_ROOT:-$fmroot/data/review-lane/work}/$(basename "$(dirname "$pack")")-$(basename "$pack")/review.md")
  local leaks=0 count=0 entry prev path revpath rel rev excluded x ok why
  local list raw rc=0
  raw=$(inputs_read "$report") || rc=$?
  if [ "$rc" = 4 ]; then
    echo "INPUT LEAK: an Inputs read list in $report has no heading of its own"
    echo "ROUND VOID: the report must list every file the reviewer opened, one per line, under an Inputs read heading"
    exit 3
  fi
  list=$(printf '%s\n' "$raw" | grep -e '/' -e '\.' || true)
  if [ -z "$list" ]; then
    echo "INPUT LEAK: no Inputs read list in $report"
    echo "ROUND VOID: the report must list every file the reviewer opened under Inputs read"
    exit 3
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    rev=''
    # A trailing line reference (path:12, path:12-40, path:L10-L40, path#L10) names the same file.
    prev=''
    while [ "$prev" != "$entry" ]; do
      prev=$entry
      entry=$(printf '%s' "$entry" | sed -E 's/(:[0-9]+(-[0-9]+)?|:L[0-9]+(-L?[0-9]+)?|#L[0-9]+(-L?[0-9]+)?)$//')
    done
    case "$entry" in
      http://* | https://*)
        if [ -n "$slug" ] && [ -n "$rubric_rev" ] &&
          { [ "$entry" = "https://raw.githubusercontent.com/$slug/$rubric_rev/docs/review-rubric.md" ] ||
            [ "$entry" = "https://github.com/$slug/blob/$rubric_rev/docs/review-rubric.md" ]; }; then
          continue
        fi
        leaks=$((leaks + 1))
        echo "INPUT LEAK: $entry: a URL other than the pinned rubric revision of this repository"
        continue
        ;;
    esac
    path=$entry
    revpath=''
    if printf '%s' "$entry" | grep -Eq '^[0-9A-Za-z_./-]+:[^:]+$' && ! printf '%s' "$entry" | grep -Eq '^(/|~|\./|\.\./)' &&
      printf '%s' "${entry%%:*}" | grep -Eq '^([0-9a-fA-F]{7,40}|HEAD|[A-Za-z][A-Za-z0-9_./-]*)$' && [ ! -e "$entry" ]; then
      rev=${entry%%:*}
      path=${entry#*:}
      revpath=${path#./}
    fi
    case "$path" in
      /* | "~"*) ;;
      *)
        if [ -z "$rev" ] && [ -e "$pack/$path" ]; then path="$pack/$path"
        elif [ -n "$root" ]; then path="$root/$path"
        else path="$pack/$path"
        fi
        ;;
    esac
    path=$(real "$path")
    ok=0
    why='not an authorized input (not in the pack, not a named reference, not tracked by the root)'
    excluded=''
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      if path_under "$path" "$x"; then excluded=$x; break; fi
    done <<EOF
$(manifest_lines "$manifest" exclude)
EOF
    if [ "$path" = "$report_real" ] || { [ -n "$log_real" ] && [ "$path" = "$log_real" ]; } || [ "$path" = "$work_report" ]; then
      ok=1
    elif [ -n "$excluded" ]; then
      why="excluded path $excluded"
    elif [ -z "$rev" ] && path_under "$path" "$pack"; then
      ok=1
    elif [ -z "$rev" ] && { [ "$path" = "$rubric_real" ] || [ "$path" = "$assess_dir/SKILL.md" ] || [ "$path" = "$define_dir/SKILL.md" ]; }; then
      ok=1
    elif [ -n "$rev" ] && [ -n "$rubric_rev" ] && [ "$rev" = "$rubric_rev" ] && [ "$revpath" = "docs/review-rubric.md" ]; then
      ok=1
    elif [ -n "$rev" ] && [ "$revpath" = "docs/review-rubric.md" ]; then
      why="the review rubric at a revision other than the pinned one"
    elif [ -n "$root" ]; then
      if [ -n "$rev" ]; then
        if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$root" cat-file -e "$rev:$revpath" 2>/dev/null; then ok=1; fi
      elif path_under "$path" "$root"; then
        rel=${path#"$root"/}
        if env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git -C "$root" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
          ok=1
        else
          why="untracked or gitignored file under the root"
        fi
      fi
    fi
    if [ "$ok" = 0 ]; then
      leaks=$((leaks + 1))
      echo "INPUT LEAK: $entry: $why"
    fi
  done <<EOF
$list
EOF
  if [ -n "$log" ]; then
    while IFS= read -r x; do
      [ -n "$x" ] || continue
      if grep -qF -- "$x" "$log"; then
        leaks=$((leaks + 1))
        echo "INPUT LEAK: $x: excluded path named in the run log"
      fi
    done <<EOF
$(manifest_lines "$manifest" exclude)
EOF
  fi
  if [ "$leaks" -gt 0 ]; then
    echo "ROUND VOID: $leaks input leak(s); rerun on a fresh pack, and do not count this round"
    exit 3
  fi
  echo "INPUT CLEAN: $count listed input(s), all authorized"
}

case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  check) shift; cmd_check "$@" ;;
  build) shift; cmd_build "$@" ;;
  '') usage; exit 2 ;;
  *) cmd_build "$@" ;;
esac
