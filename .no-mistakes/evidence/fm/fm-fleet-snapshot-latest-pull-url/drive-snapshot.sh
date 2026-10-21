#!/usr/bin/env bash
# Drives the REAL bin/fm-fleet-snapshot.sh (<ROOT>) against a disposable FM_HOME.
# Usage: drive-snapshot.sh <root-of-firstmate-checkout> <label>
set -u
ROOT=$1; LABEL=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-live.XXXXXX")
trap 'rm -rf "$W"' EXIT
H=$W/home; FB=$W/fakebin
mkdir -p "$H/state" "$H/data" "$H/projects" "$H/config" "$FB"
# external tools the snapshot shells out to; not the product under test
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"
chmod +x "$FB/no-mistakes" "$FB/tmux"
U=https://github.com/example/repo/pull
mk() { printf 'kind=ship\nremote_host=example.invalid\n' > "$H/state/$1.meta"; }
for id in s1-done-then-withdrawn s2-done-then-decision s3-same-line single explicit-meta no-url invalid-bytes nul-byte first-on-last-line; do mk $id; done
printf 'done: PR %s/1 checks green\nworking: PR 1 withdrawn, replacement %s/2\n' $U $U > "$H/state/s1-done-then-withdrawn.status"
printf 'done: %s/1\nneeds-decision: replacement %s/2 open, which?\n' $U $U > "$H/state/s2-done-then-decision.status"
printf 'done: PR %s/2 replaces withdrawn %s/1\n' $U $U > "$H/state/s3-same-line.status"
printf 'done: %s/4\n' $U > "$H/state/single.status"
printf 'pr=%s/8\n' $U >> "$H/state/explicit-meta.meta"
printf 'done: %s/9\n' $U > "$H/state/explicit-meta.status"
printf 'working: no pull request yet\n' > "$H/state/no-url.status"
printf 'working: %s/10\nworking: \377\376 replacement %s/11\n' $U $U > "$H/state/invalid-bytes.status"
printf 'working: %s/12\nworking: nul\0byte replacement %s/13\n' $U $U > "$H/state/nul-byte.status"
printf 'working: %s/5\nnote: compare %s/6 and %s/7' $U $U $U > "$H/state/first-on-last-line.status"
UTF8=$(locale -a 2>/dev/null | grep -i -E '^(C|en_US)\.utf-?8$' | head -1)
echo "== $LABEL  (snapshot: $ROOT/bin/fm-fleet-snapshot.sh, locale: $UTF8, bash: $(/bin/bash --version | head -1))"
PATH="$FB:$PATH" FM_HOME="$H" LC_ALL="$UTF8" "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$W/out.json" 2> "$W/err.txt"
echo "exit=$? stderr_bytes=$(wc -c < "$W/err.txt")"
jq -r '.tasks[] | [.id, (.pr.url // "null"), .pr.source] | @tsv' "$W/out.json" | sort | column -t
