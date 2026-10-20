#!/usr/bin/env bash
# Differential driver: run the BASE (03bff4bce) and HEAD checkers over the full
# matrix command list through all six harness entry forms and compare
# (exit code, stdout bytes, stderr bytes).
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BWZMJEVPGDQB5HWVWNFAZT
BASE=03bff4bce
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-cdg-diff.XXXXXX")
mk() { # dir ref
  local d=$1 ref=$2
  git init -q "$d"; git -C "$d" -c user.email=a@b -c user.name=t commit -q --allow-empty -m init
  : > "$d/AGENTS.md"; mkdir -p "$d/bin"
  for f in fm-cd-pretool-check.sh fm-hook-host-lib.sh fm-cd-command-policy.mjs fm-arm-command-policy.mjs; do
    git -C "$WT" show "$ref:bin/$f" > "$d/bin/$f"
  done
  chmod +x "$d/bin/fm-cd-pretool-check.sh" "$d/bin/fm-cd-command-policy.mjs"
}
mk "$W/base" "$BASE"; mk "$W/head" HEAD
IDS=(); CMDS=()
matrix_case() { IDS+=("$1"); CMDS+=("$3"); }
eval "$(grep '^matrix_case ' "$WT/tests/fm-cd-pretool-check.test.sh")"
run() { # dir entry cmd mode -> writes $W/out $W/err, echoes rc
  local dir=$1 entry=$2 cmd=$3 mode=$4 payload rc
  local -a envp=(env -u FM_CD_GUARD_MODE)
  [ -n "$mode" ] && envp=(env "FM_CD_GUARD_MODE=$mode")
  case $entry in
    codex)  jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "${envp[@]}" "$dir/bin/fm-cd-pretool-check.sh" >"$W/out" 2>"$W/err"; rc=$? ;;
    claude) jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "${envp[@]}" "$dir/bin/fm-cd-pretool-check.sh" --claude >"$W/out" 2>"$W/err"; rc=$? ;;
    grok)   jq -cn --arg c "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$c}}' | "${envp[@]}" "$dir/bin/fm-cd-pretool-check.sh" >"$W/out" 2>"$W/err"; rc=$? ;;
    opencode|pi) "${envp[@]}" "$dir/bin/fm-cd-pretool-check.sh" --command "$cmd" >"$W/out" 2>"$W/err"; rc=$? ;;
    cursor) jq -cn --arg c "$cmd" '{tool_name:"Shell",tool_input:{command:$c},cursor_version:"2026.08.11-e8db854"}' | "${envp[@]}" "$dir/bin/fm-cd-pretool-check.sh" --cursor >"$W/out" 2>"$W/err"; rc=$? ;;
  esac
  echo "$rc"
}
tot=0; same=0; diffs=0; denyrc2=0
for i in "${!IDS[@]}"; do
  for entry in codex claude grok opencode pi cursor; do
    brc=$(run "$W/base" "$entry" "${CMDS[$i]}" ""); cp "$W/out" "$W/bout"; cp "$W/err" "$W/berr"
    hrc=$(run "$W/head" "$entry" "${CMDS[$i]}" deny)
    tot=$((tot+1))
    if [ "$brc" = "$hrc" ] && cmp -s "$W/bout" "$W/out" && cmp -s "$W/berr" "$W/err"; then
      same=$((same+1)); [ "$brc" = 2 ] && denyrc2=$((denyrc2+1))
    else
      diffs=$((diffs+1)); echo "DIFF ${IDS[$i]} $entry base_rc=$brc head_rc=$hrc"
    fi
  done
done
echo "deny-mode vs base: total=$tot byte-identical=$same differing=$diffs (of identical, exit-2 denies=$denyrc2)"
# silent-allow commands: head default must also equal base (silent)
at=0; as=0
for i in "${!IDS[@]}"; do
  case ${IDS[$i]} in A*) ;; *) continue ;; esac
  for entry in codex claude grok opencode pi cursor; do
    hrc=$(run "$W/head" "$entry" "${CMDS[$i]}" ""); at=$((at+1))
    if [ "$hrc" = 0 ] && [ ! -s "$W/out" ] && [ ! -s "$W/err" ]; then as=$((as+1)); else echo "NOT-SILENT ${IDS[$i]} $entry rc=$hrc"; fi
  done
done
echo "head default silent-allow: total=$at silent-exit0=$as"
rm -rf "$W"
