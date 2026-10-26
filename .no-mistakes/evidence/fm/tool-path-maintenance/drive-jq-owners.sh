#!/usr/bin/env bash
# Live driver: real bin/fm-bootstrap.sh in a disposable lab home. The system jq
# is removed from lookup by a disposable PATH directory that links every
# /usr/bin tool except jq; the real /usr/bin/jq sits behind an exec-logging
# launcher in a disposable $HOME/.local/bin (path with spaces).
set -u
ROOT=$1
cd "$ROOT"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pathmiss-jq.XXXXXX")
U="$SCR/operator home with spaces"; UB="$U/.local/bin"; LOG="$SCR/exec.log"; SYS="$SCR/usrbin-without-jq"
mkdir -p "$UB" "$SYS"
for f in /usr/bin/*; do [ "${f##*/}" = jq ] || ln -s "$f" "$SYS/${f##*/}"; done
printf '#!/bin/sh\necho "jq $*" >> "%s"\nexec /usr/bin/jq "$@"\n' "$LOG" > "$UB/jq"; chmod +x "$UB/jq"
OFF="$SYS:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/Users/charlesabrooker/.local/bin-not-used"
OFF="$SYS:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
ON="$UB:$OFF"
run() { # $1=PATH, rest = extra env
  local p=$1; shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE \
    HOME="$U" PATH="$p" FM_HOME="$FM_HOME" FM_BOOTSTRAP_NETWORK=skip "$@" bin/fm-bootstrap.sh 2>&1; echo "[exit=$?]"; }
echo "FM_HOME=$FM_HOME"; echo "HOME=$U"
echo "jq lookup with PATH excluding \$HOME/.local/bin: $(PATH="$OFF" command -v jq || echo 'not found')"
echo "jq lookup with PATH including \$HOME/.local/bin: $(PATH="$ON" command -v jq)"
printf 'FMX_PAIRING_TOKEN=tok-lab\n' > "$FM_HOME/.env"
artifacts() { for a in state/x-watch.check.sh config/x-mode.env; do [ -e "$FM_HOME/$a" ] && echo "  present: $a" || echo "  absent:  $a"; done; }
echo; echo "=== X1: Relay opted in, jq only in \$HOME/.local/bin ==="
run "$OFF" | grep -E 'jq|curl|FMX|PATH_MISSING|exit='
artifacts; echo "  exec log: $(cat "$LOG" 2>/dev/null || echo none)"
echo; echo "=== X2: operator adds \$HOME/.local/bin to PATH ==="
run "$ON" | grep -E 'jq|curl|FMX|PATH_MISSING|exit='
artifacts
rm -f "$LOG"
echo; echo "=== X3: PATH entry lost again while Relay is armed ==="
run "$OFF" | grep -E 'jq|curl|FMX|PATH_MISSING|exit='
artifacts; echo "  exec log: $(cat "$LOG" 2>/dev/null || echo none)"
echo; echo "=== X4 (base commit d118e2d3, same setup as X3) - previous advice ==="
mkdir -p "$SCR/base"; git archive d118e2d3 | tar -x -C "$SCR/base"
run "$ON" >/dev/null   # re-arm with current code
( cd "$SCR/base" && env -u FM_ROOT_OVERRIDE -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE HOME="$U" PATH="$OFF" FM_HOME="$FM_HOME" FM_BOOTSTRAP_NETWORK=skip bin/fm-bootstrap.sh 2>&1 | grep -E 'jq|FMX|PATH_MISSING' )
rm -f "$FM_HOME/.env" "$FM_HOME/state/x-watch.check.sh" "$FM_HOME/config/x-mode.env"
rm -f "$LOG"
echo; echo "=== C1: crew-dispatch.json present (malformed), jq only in \$HOME/.local/bin ==="
printf '%s\n' '{"rules":[' > "$FM_HOME/config/crew-dispatch.json"
run "$OFF" FM_BOOTSTRAP_DETECT_ONLY=1 | grep -E 'jq|CREW_DISPATCH|PATH_MISSING|exit='
echo "  exec log: $(cat "$LOG" 2>/dev/null || echo none)"
echo; echo "=== C2: operator adds \$HOME/.local/bin to PATH ==="
run "$ON" FM_BOOTSTRAP_DETECT_ONLY=1 | grep -E 'jq|CREW_DISPATCH|PATH_MISSING|exit='
echo "  exec log: $(tr '\n' ';' < "$LOG" 2>/dev/null || echo none)"
echo; echo "=== C3: jq genuinely absent (no candidate) keeps install advice ==="
rm -f "$UB/jq"
run "$OFF" FM_BOOTSTRAP_DETECT_ONLY=1 | grep -E 'jq|CREW_DISPATCH|PATH_MISSING|exit='
echo; echo "=== teardown ==="
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME" && rm -rf "$SCR" && echo "lab + scratch removed"
