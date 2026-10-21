#!/usr/bin/env bash
# Times the REAL snapshot on a 200,000-line status log: with explicit pr= (no discovery) vs without (discovery).
# Usage: drive-large.sh <root>
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-large-live.XXXXXX"); trap 'rm -rf "$W"' EXIT
H=$W/home; FB=$W/fakebin; mkdir -p "$H/state" "$H/data" "$H/projects" "$H/config" "$FB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"; printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/tmux"; chmod +x "$FB"/*
U=https://github.com/example/repo/pull
awk 'BEGIN{for(i=0;i<200000;i++)print "working: routine progress"}' > "$H/state/large.status"
printf 'done: %s/15\n' $U >> "$H/state/large.status"
wc -l "$H/state/large.status" | awk '{print "status log lines:", $1}'
# checkpoint the independent open-decision fold exactly as the production drain does, so we time PR discovery, not a cold fold
bash -c '. "$1"; status_open_decisions_incremental "$2" >/dev/null' _ "$ROOT/bin/fm-classify-lib.sh" "$H/state/large.status"
run() {  # label
  PATH="$FB:$PATH" FM_HOME="$H" /usr/bin/time -l /bin/bash "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$W/out.json" 2> "$W/time.txt"
  printf '%-34s real=%ss maxrss=%sMB  pr=%s source=%s\n' "$1" "$(awk '/ real /{print $1}' "$W/time.txt")" \
    "$(awk '/maximum resident/{printf "%d", $1/1048576}' "$W/time.txt")" \
    "$(jq -r '.tasks[0].pr.url' "$W/out.json")" "$(jq -r '.tasks[0].pr.source' "$W/out.json")"
}
printf 'kind=ship\nremote_host=example.invalid\npr=%s/16\n' $U > "$H/state/large.meta"
run "explicit pr= (no discovery) #1"
run "explicit pr= (no discovery) #2"
printf 'kind=ship\nremote_host=example.invalid\n' > "$H/state/large.meta"
run "no pr= (discovery) #1"
run "no pr= (discovery) #2"
run "no pr= (discovery) #3"
