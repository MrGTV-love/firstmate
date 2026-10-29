#!/bin/bash
# Round 4 live lab: run the real bin/fm-guard.sh (target b8b84040) and the base
# 7b5c75cc guard against one disposable marked lab home on this Mac, with and
# without FM_GUARD_PHASE_DURATION_FILE, on both original exit paths.
set -u
WT=$1; EV=$2
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>"$EV/r5-lab-env.stderr")"
echo "FM_HOME=$FM_HOME"
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-base.XXXXXX")
ART=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-art.XXXXXX")
cleanup() {
  "$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"
  echo "teardown_rc=$?"; rm -rf "$BASE" "$ART"; echo cleanup_done
}
trap cleanup EXIT
git archive 7b5c75cc bin | tar -x -C "$BASE"
echo "base fm-guard.sh blob: $(git rev-parse 7b5c75cc:bin/fm-guard.sh)"
echo "target fm-guard.sh blob: $(git rev-parse HEAD:bin/fm-guard.sh)"
echo "env bash: $(env bash -c 'echo $BASH_VERSION $OSTYPE')"
run() {  # <label> <guard> [env...]
  local label=$1 guard=$2; shift 2
  env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GUARD_PHASE_DURATION_FILE \
      FM_HOME="$FM_HOME" "$@" "$guard" > "$ART/$label.out" 2> "$ART/$label.err"
  echo "== $label rc=$? stdout_bytes=$(wc -c < "$ART/$label.out" | tr -d ' ') stderr_bytes=$(wc -c < "$ART/$label.err" | tr -d ' ')"
}
same() {
  if cmp -s "$ART/$1.out" "$ART/$2.out" && cmp -s "$ART/$1.err" "$ART/$2.err"; then
    echo "IDENTICAL: $1 vs $2"; else echo "DIFFERENT: $1 vs $2"; diff "$ART/$1.err" "$ART/$2.err"; fi
}
OPT="FM_GUARD_PHASE_DURATION_FILE=$ART/optin/guard-phase-durations.jsonl"
mkdir -p "$ART/optin"
echo "### early exit path (idle lab home, needed=false)"
run base-idle "$BASE/bin/fm-guard.sh"
run target-idle "$WT/bin/fm-guard.sh"
run target-idle-optin "$WT/bin/fm-guard.sh" "$OPT"
run target-idle-optin-b3clock "$WT/bin/fm-guard.sh" "$OPT" EPOCHREALTIME=1700000000.123456
same base-idle target-idle; same target-idle target-idle-optin; same target-idle target-idle-optin-b3clock
echo "### final exit path (one task .meta in flight, no watcher -> needed=true)"
printf 'window=firstmate:fm-task\nkind=ship\n' > "$FM_HOME/state/task.meta"
for v in base target target-optin; do
  rm -f "$FM_HOME/state/.guard-watcher-stale-banner"
  case $v in
    base) run first-$v "$BASE/bin/fm-guard.sh" ;;
    target) run first-$v "$WT/bin/fm-guard.sh" ;;
    target-optin) run first-$v "$WT/bin/fm-guard.sh" "$OPT" ;;
  esac
done
same first-base first-target; same first-target first-target-optin
run repeat-base "$BASE/bin/fm-guard.sh"
run repeat-target "$WT/bin/fm-guard.sh"
run repeat-target-optin "$WT/bin/fm-guard.sh" "$OPT" EPOCHREALTIME=1700000000.123456
same repeat-base repeat-target; same repeat-target repeat-target-optin
echo "-- first-target stderr:"; cat "$ART/first-target.err"
echo "-- repeat-target stderr:"; cat "$ART/repeat-target.err"
rm -f "$FM_HOME/state/task.meta"
run idle-after-base "$BASE/bin/fm-guard.sh"
[ -e "$FM_HOME/state/.guard-watcher-stale-banner" ] && echo "marker still present" || echo "marker cleared by needed=false exit"
echo "-- opt-in artifacts:"
ls -A "$ART/optin" | sed 's/^/  /'; [ -z "$(ls -A "$ART/optin")" ] && echo "none: no duration file created by any opt-in run on Darwin Bash 3.2"
echo "-- duration-like files in lab home:"; find "$FM_HOME" -name '*duration*' -print; echo "(end)"
