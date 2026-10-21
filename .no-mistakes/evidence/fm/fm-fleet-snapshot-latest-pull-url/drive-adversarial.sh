#!/usr/bin/env bash
# Adversarial inputs for the REAL bin/fm-fleet-snapshot.sh --json. Usage: drive-adversarial.sh <root> [bash-binary]
set -u
ROOT=$1; BASHBIN=${2:-bash}
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-adv-live.XXXXXX"); trap 'chmod -R u+rw "$W" 2>/dev/null; rm -rf "$W"' EXIT
H=$W/home; FB=$W/fakebin; mkdir -p "$H/state" "$H/data" "$H/projects" "$H/config" "$FB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"; chmod +x "$FB"/*
U=https://github.com/example/repo/pull
mk() { printf 'kind=ship\nremote_host=example.invalid\n' > "$H/state/$1.meta"; }
for id in crlf empty-log trailing-nonurl long-line http-scheme paren-quote blank-pr-meta files-suffix; do mk $id; done
printf 'done: %s/20\r\nworking: replacement %s/21\r\n' $U $U > "$H/state/crlf.status"
: > "$H/state/empty-log.status"
printf 'working: %s/23\nworking: replacement %s/24\nworking: still going\n\n  \n' $U $U > "$H/state/trailing-nonurl.status"
{ printf 'working: %s/25\nworking: ' $U; head -c 60000 /dev/zero | tr '\0' 'x'; printf ' %s/26\n' $U; } > "$H/state/long-line.status"
printf 'working: http://forge.example/o/r/pull/27 and https://github.com/o/r/pull/28\n' > "$H/state/http-scheme.status"
printf 'note: (%s/29) then "%s/30"\n' $U $U > "$H/state/paren-quote.status"
printf 'pr=\n' >> "$H/state/blank-pr-meta.meta"; printf 'done: %s/31\n' $U > "$H/state/blank-pr-meta.status"
printf 'working: %s/32/files#diff\n' $U > "$H/state/files-suffix.status"
echo "== $ROOT  via $($BASHBIN --version | head -1)"
PATH="$FB:$PATH" FM_HOME="$H" LC_ALL=en_US.UTF-8 $BASHBIN "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$W/out.json" 2> "$W/err.txt"
echo "exit=$? stderr: $(head -c 300 "$W/err.txt")"
jq -r '.tasks[] | [.id, (.pr.url // "null"), .pr.source] | @tsv' "$W/out.json" | sort | column -t
