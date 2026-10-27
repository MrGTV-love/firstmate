#!/usr/bin/env bash
# Drive the real bin/fm-fleet-snapshot.sh in a disposable lab FM_HOME and print
# each task's published pr.url / pr.source. Usage: drive-snapshot-pr.sh <repo-root> [<bash>]
set -u
ROOT=$1; BASH_BIN=${2:-bash}
cd "$ROOT"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
trap 'bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME"' EXIT
S=$FM_HOME/state
meta() { printf 'kind=ship\nremote_host=example.invalid\n' > "$S/$1.meta"; }
u=https://github.com/example/repo/pull
for id in withdrawn-replaced decision-replaced same-line single none incidental explicit invalid-bytes nul-byte crlf; do meta "$id"; done
printf 'working: opened %s/1\ndone: PR %s/1 checks green\nworking: PR 1 withdrawn, replacement %s/2\n' $u $u $u > "$S/withdrawn-replaced.status"
printf 'done: %s/1\nneeds-decision: replacement %s/2 open, which?\n' $u $u > "$S/decision-replaced.status"
printf 'done: PR %s/2 replaces withdrawn %s/1\n' $u $u > "$S/same-line.status"
printf 'done: %s/4\n' $u > "$S/single.status"
printf 'working: no pull request yet\ndone: shipped, see report\n' > "$S/none.status"
printf 'working: %s/5\nnote: compare %s/6 and %s/7' $u $u $u > "$S/incidental.status"
printf 'pr=%s/8\n' $u >> "$S/explicit.meta"; printf 'done: %s/9\n' $u > "$S/explicit.status"
printf 'working: %s/10\nworking: \377\376 replacement %s/11\n' $u $u > "$S/invalid-bytes.status"
printf 'working: %s/12\nworking: nul\0byte replacement %s/13\n' $u $u > "$S/nul-byte.status"
printf 'working: %s/20\r\nworking: replacement %s/21)\r\n' $u $u > "$S/crlf.status"
echo "## status logs"; for f in "$S"/*.status; do echo "--- $(basename "$f")"; LC_ALL=C cat -v "$f"; echo; done
for loc in C.UTF-8 en_US.UTF-8 C; do
  echo "## snapshot --json, LC_ALL=$loc, shell=$BASH_BIN"
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    LC_ALL=$loc FM_HOME="$FM_HOME" "$BASH_BIN" bin/fm-fleet-snapshot.sh --json 2>&1 |
    jq -r '.tasks[] | [.id, (.pr.url // "null"), .pr.source] | @tsv' | sort | column -t
done
