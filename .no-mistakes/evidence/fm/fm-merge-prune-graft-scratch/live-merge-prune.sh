#!/usr/bin/env bash
# Drives the real bin/fm-merge-prune.sh arm/run, with the real bin/fm-teardown.sh,
# over a squash-merged pool copy holding graft's generated output. Only GitHub
# (gh, gh-axi) and the Treehouse pool CLI are stand-ins, from the repo's own e2e
# harness (tests/fm-merge-prune.test.sh make_e2e_world).
# Usage: live-merge-prune.sh <repo-root> <label> <variant...>
#   variants: graft-teardown graft-fallback custom-ignore-fallback nested-git-fallback
R=$1 LABEL=$2; shift 2
graft_out() {
  printf '/.ignore\n/graft/\n' >> "$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)"
  printf '%s\n' "# graft's cards are gitignored but should stay greppable: ripgrep reads" "# .ignore before .gitignore, so this re-admits the tree to search only." '!graft/' 'graft/.cache/' 'graft/.graph/' > "$1/.ignore"
  mkdir -p "$1/graft/.graph" "$1/graft/.cache/session"
  printf '{"graftReads":0,"sourceReads":3,"savedTokens":0,"injectedPointers":[],"nudges":0}\n' > "$1/graft/.cache/session/a.json"
  printf '{"syncedAt":null}\n' > "$1/graft/.cache/stats.json"
  printf '# work.txt\n\n_No extracted symbols in this file._\n' > "$1/graft/work.md"
  printf '{"nodes":[],"edges":[]}\n' > "$1/graft/.graph/wiring.json"
}
drive() {  # <variant>
  local v=$1
  make_e2e_world
  graft_out "$COPY"
  case "$v" in
    custom-ignore-*) printf 'project-private/\n' >> "$COPY/.ignore" ;;
    nested-git-*) make_nested graft/n1 ;;
  esac
  case "$v" in *-fallback) : > "$W/refuse" ;; esac
  prune_real arm t1
  start_inside "$COPY" "$W/worker.pid"
  start_pane "$COPY" bash "$W/bin/pane-idle" "$W/hold"
  FM_MERGE_PRUNE_EXIT_WAIT=3 prune_real run t1 --now >/dev/null 2>&1
  echo "--- $LABEL / $v ---"
  [ -e "$COPY" ] && echo "copy: KEPT" || echo "copy: removed"
  echo "treehouse destroy calls: $(destroy_calls)"
  echo "keep wakes: $(wake_count_real)"
  [ -e "$STATE/t1.meta" ] && echo "task record: open" || echo "task record: closed by teardown"
  [ ! -e "$STATE/t1.merge-prune" ] || echo "record reason: $(sed -n 's/^reason=//p' "$STATE/t1.merge-prune")"
  echo "preserved to task data: $(find "$DATA" -path '*preserved*' -type f 2>/dev/null | sed "s#$DATA/##" | tr '\n' ' ')"
  [ ! -e "$COPY/graft/n1/.git" ] || echo "nested clone under graft/: intact"
  sed "s#$W#<W>#g" "$DATA/t1/merge-prune.log" 2>/dev/null | sed 's/^/  log: /'
  cleanup_workers
}
for v in "$@"; do eval "drv_${v//-/_}() { drive $v; }"; done
names=(); for v in "$@"; do names+=("drv_${v//-/_}"); done
. "$R/tests/fm-merge-prune.test.sh" "${names[@]}"
