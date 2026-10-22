#!/usr/bin/env bash
# Live CLI transcript: real bin/fm-fleet-snapshot.sh --json over a disposable FM_HOME,
# one task per status-log shape. Usage: drive-edge-cases.sh <bin-tree-root> <label> <work-dir>
set -u
code=$1 label=$2 work=$3
home=$work/home fb=$work/fakebin
rm -rf "$work"; mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$fb"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"; printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"; chmod +x "$fb"/*
mk() { printf 'kind=ship\nmode=ship\nremote_host=example.invalid\n' > "$home/state/$1.meta"; }
U=https://github.com/example/repo/pull
mk a-withdrawn-then-working;   printf "done: PR $U/1 checks green\nworking: PR 1 withdrawn, replacement $U/2\n" > "$home/state/a-withdrawn-then-working.status"
mk b-withdrawn-then-decision;  printf "done: $U/1\nneeds-decision: replacement $U/2 open, which?\n" > "$home/state/b-withdrawn-then-decision.status"
mk c-same-line-first-url;      printf "done: PR $U/2 replaces withdrawn $U/1\n" > "$home/state/c-same-line-first-url.status"
mk d-invalid-utf8-bytes;       printf "working: $U/10\nworking: \377\376 replacement $U/11\n" > "$home/state/d-invalid-utf8-bytes.status"
mk e-nul-byte;                 printf "working: $U/12\nworking: nul\0byte replacement $U/13\n" > "$home/state/e-nul-byte.status"
mk f-no-url;                   printf 'working: no pull request yet\n' > "$home/state/f-no-url.status"
mk g-explicit-meta-pr;         printf "pr=$U/8\n" >> "$home/state/g-explicit-meta-pr.meta"; printf "done: $U/9\n" > "$home/state/g-explicit-meta-pr.status"
mk h-no-trailing-newline;      printf "working: $U/20\nworking: replacement $U/21" > "$home/state/h-no-trailing-newline.status"
mk i-known-limit-incidental;   printf "done: $U/30\nnote: compare $U/31\n" > "$home/state/i-known-limit-incidental.status"
mk j-no-status-log
utf8=$(locale -a 2>/dev/null | grep -i -E '^(C|en_US)\.utf-?8$' | head -1)
echo "=== [$label] bash=$(command -v bash) $(bash --version | head -1)  LC_ALL=$utf8 ==="
echo "\$ FM_HOME=<lab> LC_ALL=$utf8 bin/fm-fleet-snapshot.sh --json | jq '.tasks[] | {id, url: .pr.url, source: .pr.source}'"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  PATH="$fb:$PATH" FM_HOME="$home" LC_ALL="$utf8" "$code/bin/fm-fleet-snapshot.sh" --json \
  | jq -r '.tasks[] | [.id, (.pr.url // "null"), .pr.source] | @tsv' | column -t
