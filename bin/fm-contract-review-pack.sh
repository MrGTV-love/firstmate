#!/usr/bin/env bash
# Build the clean reviewer input for an independent review of a definition-of-done
# contract, and check afterwards that the reviewer read only what it was given.
# The rules live in .agents/skills/contract-review/SKILL.md (the one owner); this
# script is the only code path that assembles contract-review reviewer input.
#
# usage:
#   fm-contract-review-pack.sh [build] --contract <file> [--request <file>]
#       [--context <file>]... [--root <repo-root>] [--exclude <path>]...
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
#   The author's sections are dropped by heading. A heading the builder does not
#   recognise stops the build with exit 3 naming it, and nothing is written.
#   The manifest of excluded paths is <out-root>.excluded-paths, outside the pack.
#   It always holds the real path of every input file (the contract, the request,
#   each context file), the register and history paths when given, and every
#   --exclude path. The policy is --policy, else $FM_CONTRACT_REVIEW_POLICY, else
#   the skill next to this script.
# check: reads the report's `Inputs read` list and, when given, the run log, and
#   prints INPUT LEAK lines plus ROUND VOID (exit 3) when the list is missing or a
#   listed path is not an authorized input; prints INPUT CLEAN (exit 0) otherwise.
#   An authorized input is judged by what it is: a file inside the pack, a file in
#   the assess-done-and-grade or define-done-and-grading skill directory, the
#   review rubric, or a file the manifest's root tracks (git ls-files, or
#   <rev>:<path> that git can read). A path in the manifest's excluded set is
#   refused even when it is tracked. A gitignored file is not tracked.
#   Skill directory: $REVIEW_SKILLS_DIR, default ~/.agents/skills. Rubric:
#   $REVIEW_RUBRIC, else $REVIEW_FM_ROOT/docs/review-rubric.md (the entrypoint's
#   own variables), else this repository's docs/review-rubric.md.
# Exit codes: 0 ok, 2 usage or bad input, 3 unrecognised section or input leak.
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
# named by KEEP_OUT, the dropped section names to DROPPED_OUT and the unrecognised
# headings to UNKNOWN_OUT. Headings of level 1 and 2 start a section and must be
# recognised; a level 3 heading under a kept section is dropped when it names an
# author section. Text inside a code fence is never a heading.
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
BEGIN { mode = "keep"; parent = "keep"; seen_heading = 0; fence = 0; pre = 1 }
{
  line = $0
  if (line ~ /^(```|~~~)/) fence = !fence
  level = 0
  if (!fence) {
    if (line ~ /^### /) level = 3
    else if (line ~ /^## /) level = 2
    else if (line ~ /^# /) level = 1
  }
  if (level == 1 && !seen_heading) {
    seen_heading = 1
    print line > KEEP_OUT
    next
  }
  if (level == 1 || level == 2) {
    seen_heading = 1
    pre = 0
    t = norm(substr(line, level + 2))
    c = classify(t)
    parent = c
    if (c == "keep") mode = "keep"
    else if (c == "drop") { mode = "drop"; print substr(line, level + 2) > DROPPED_OUT }
    else { mode = "drop"; print substr(line, level + 2) > UNKNOWN_OUT }
    if (mode == "keep") print line > KEEP_OUT
    next
  }
  if (level == 3) {
    t = norm(substr(line, 5))
    if (parent == "keep" && classify(t) != "drop") mode = "keep"
    else { mode = "drop"; if (parent == "keep") print substr(line, 5) > DROPPED_OUT }
    if (mode == "keep") print line > KEEP_OUT
    next
  }
  if (mode == "keep") {
    if (pre && tolower(line) ~ PREAMBLE_DROP) { print "preamble line: " line > DROPPED_OUT; next }
    print line > KEEP_OUT
  }
}
'

SECTION_KEEP="request|context|captain's intent|captain intent|rulings|terms|amendment|definition of done|how you're graded|how you are graded|assumptions|decisive scenario|out of scope|known limits|hard gates|execution constraints|honesty rule|supporting"
SECTION_DROP="author self-check|author's all-green|author all-green|all-green|author's|author notes|boundary dispositions|contract review|review history|revision log|revision history|self-check|prior findings|prior review|responses|response to|suggested attack|open findings|finding register|register"
PREAMBLE_DROP='contract review|reviewed:|all-green|self-check|review exit|prior finding|revision log'

filter_sections() { # <in> <keep-out> <dropped-out> <unknown-out>
  : >"$2"
  : >"$3"
  : >"$4"
  awk -v KEEP_OUT="$2" -v DROPPED_OUT="$3" -v UNKNOWN_OUT="$4" \
    -v KEEP="$SECTION_KEEP" -v DROP="$SECTION_DROP" -v PREAMBLE_DROP="$PREAMBLE_DROP" \
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

  filter_sections "$contract" "$scratch/keep" "$scratch/dropped" "$scratch/unknown"
  if [ -s "$scratch/unknown" ]; then
    local name
    while IFS= read -r name; do
      echo "fm-contract-review-pack: unrecognised section: $name" >&2
    done <"$scratch/unknown"
    echo "fm-contract-review-pack: no pack written; rename the section to a recognised one or add it to the builder" >&2
    exit 3
  fi
  grep -qi '^#\{1,3\} definition of done' "$scratch/keep" || die "contract has no Definition Of Done section: $contract"

  for f in ${contexts[@]+"${contexts[@]}"}; do
    filter_sections "$f" "$scratch/ctx.keep" "$scratch/ctx.dropped" "$scratch/ctx.unknown"
    if [ -s "$scratch/ctx.dropped" ] && grep -qv '^preamble line:' "$scratch/ctx.dropped"; then
      die "context file holds an author section: $f"
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
    state == 0 && tolower($0) ~ /^[#*[:space:]-]*inputs read[*:[:space:]]*$/ { state = 1; next }
    state == 0 && tolower($0) ~ /^[#*[:space:]-]*inputs read[*]*:[*]*[ \t]+[^ \t]/ {
      line = $0
      sub(/^[^:]*:[*]*[ \t]+/, "", line)
      n = split(line, parts, /,[ \t]*/)
      for (i = 1; i <= n; i++) { t = entry(parts[i]); if (t != "") print t }
      state = 2
      next
    }
    state == 1 {
      if ($0 ~ /^[ \t]*$/) { if (items) state = 2; next }
      if ($0 ~ /^#/ || (items && $0 !~ /^[ \t]*([-*+]|[0-9]+[.)]|`|\/|~)/)) { state = 2; next }
      items = 1
      t = entry($0)
      if (t != "") print t
    }
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

  local leaks=0 count=0 entry path revpath rel rev excluded x ok why
  local list
  list=$(inputs_read "$report" | grep -e '/' -e '\.' || true)
  if [ -z "$list" ]; then
    echo "INPUT LEAK: no Inputs read list in $report"
    echo "ROUND VOID: the report must list every file the reviewer opened under Inputs read"
    exit 3
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    count=$((count + 1))
    rev=''
    path=$entry
    if printf '%s' "$entry" | grep -Eq '^[0-9A-Za-z_./-]+:[^:]+$' && ! printf '%s' "$entry" | grep -Eq '^(/|~|\./|\.\./)' &&
      printf '%s' "${entry%%:*}" | grep -Eq '^([0-9a-fA-F]{7,40}|HEAD|[A-Za-z][A-Za-z0-9_./-]*)$' && [ ! -e "$entry" ]; then
      rev=${entry%%:*}
      path=${entry#*:}
    fi
    revpath=''
    case "$path" in
      /* | "~"*) ;;
      *)
        if [ -z "$rev" ] && [ -e "$pack/$path" ]; then path="$pack/$path"
        elif [ -n "$root" ]; then revpath=${path#./}; path="$root/$path"
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
    if [ -n "$excluded" ]; then
      why="excluded path $excluded"
    elif [ -z "$rev" ] && path_under "$path" "$pack"; then
      ok=1
    elif [ -z "$rev" ] && { [ "$path" = "$rubric_real" ] || path_under "$path" "$assess_dir" || path_under "$path" "$define_dir"; }; then
      ok=1
    elif [ -n "$rev" ] && [ "$revpath" = "docs/review-rubric.md" ]; then
      ok=1
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
