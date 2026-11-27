#!/usr/bin/env bash
# Real omp codex usage probe in a marked lab home: head form (--no-extensions) vs base form.
set -u
ROOT=$(pwd)
eval "$(bin/fm-lab-home.sh env 2>"$ROOT/../.labenv.$$")" || exit 1
TD=$(sed -n 's/.*teardown: //p' "$ROOT/../.labenv.$$"); rm -f "$ROOT/../.labenv.$$"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE NO_MISTAKES_GATE
mk() { find "$FM_HOME/state" \( -name '.omp-*-extension-loaded' -o -name lifecycle.log \) 2>/dev/null | sed "s|$FM_HOME|<labhome>|" | tr '\n' ' '; }
pshape() { jq -c '[paths|map(if type=="number" then 0 else . end)]|unique' 2>/dev/null; }
echo "head=$(git rev-parse HEAD)"
echo "== markers before: [$(mk)]"
. bin/fm-dispatch-capacity-lib.sh
out=$(fm_omp_codex_capacity openai-codex/gpt-5.5); rc=$?
echo "== fm_omp_codex_capacity (head code, worktree cwd): rc=$rc type=$(printf %s "$out" | jq -r type 2>/dev/null) keys=$(printf %s "$out" | jq -c 'if type=="object" then keys else . end' 2>/dev/null)"
echo "== markers after head probe: [$(mk)]"
withf=$(omp usage --provider openai-codex --json --no-extensions </dev/null 2>/dev/null); r1=$?
T=$(mktemp -d); noflag=$(cd "$T" && omp usage --provider openai-codex --json </dev/null 2>/dev/null); r2=$?; rmdir "$T"
echo "== raw with flag: rc=$r1 bytes=${#withf} path_shapes=$(printf %s "$withf" | pshape | jq length)"
echo "== raw no flag (empty cwd): rc=$r2 bytes=${#noflag} path_shapes=$(printf %s "$noflag" | pshape | jq length)"
[ "$(printf %s "$withf" | pshape)" = "$(printf %s "$noflag" | pshape)" ] && echo "== same JSON key shape: yes" || echo "== same JSON key shape: no"
echo "== RED control: base form (no flag) from the worktree cwd"
omp usage --provider openai-codex --json </dev/null >/dev/null 2>&1; echo "rc=$?"
echo "== markers after base-form probe: [$(mk)]"
eval "$TD"; echo "labhome-teardown=$?"
