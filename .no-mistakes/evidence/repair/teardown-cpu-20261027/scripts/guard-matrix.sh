#!/bin/bash
# Drive the real bin/fm-guard.sh from three commits against disposable fixture
# homes, in three env modes, and record stdout/stderr/exit/artifact per run.
set -u
WT=$1 OUT=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-matrix.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
declare -a REVS=(8cd7049473649ea514cb726a5190197635d84236 b42dae56 a005287badac8f6518a0b97ef492491b52b81a58)
declare -a NAMES=(base prev head)
for i in 0 1 2; do
  mkdir -p "$WORK/${NAMES[$i]}"
  git -C "$WT" archive "${REVS[$i]}" bin | tar -x -C "$WORK/${NAMES[$i]}"
done
make_case() {  # <dir> <kind>
  local d=$1 kind=$2
  mkdir -p "$d/home/state" "$d/home/config" "$d/root"
  case $kind in
    idle) : ;;  # no tasks -> needed=false early exit
    stale) printf 'window=firstmate:fm-task\nkind=ship\n' > "$d/home/state/task.meta" ;;
    tangle) git -C "$d/root" init -q -b main; git -C "$d/root" -c user.email=t@t -c user.name=t commit -q --allow-empty -m i; git -C "$d/root" checkout -q -b feature/x ;;
  esac
}
: > "$OUT"
for kind in idle stale tangle; do
  for mode in default optin forged; do
    for n in base prev head; do
      d="$WORK/run-$kind-$mode-$n"; make_case "$d" "$kind"
      art="$d/artifact/guard-phase-durations.jsonl"; mkdir -p "$d/artifact"
      envs=(env -u BASH_ENV -u ENV -u EPOCHREALTIME -u FM_GUARD_PHASE_DURATION_FILE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE -u NO_MISTAKES_GATE
            FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" FM_GUARD_GRACE=0 FM_SUPERVISION_MODEL=persistent)
      case $mode in
        optin) envs+=(FM_GUARD_PHASE_DURATION_FILE="$art") ;;
        forged) envs+=(FM_GUARD_PHASE_DURATION_FILE="$art" EPOCHREALTIME=1700000000.123456 OSTYPE=linux-gnu) ;;
      esac
      "${envs[@]}" /bin/bash --noprofile --norc "$WORK/$n/bin/fm-guard.sh" >"$d/stdout" 2>"$d/stderr"; rc=$?
      # normalise the per-run fixture path so outputs compare across commits
      sed -i '' "s#$d#<FIX>#g; s#$WORK/$n#<BIN>#g" "$d/stdout" "$d/stderr"
      if [ -e "$art" ]; then artstate="exists:$(wc -l <"$art" | tr -d ' ')lines"; else artstate=absent; fi
      printf '%s\t%s\t%s\texit=%s\tstdout=%s\tstderr=%s\tartifact=%s\n' "$kind" "$mode" "$n" "$rc" \
        "$(shasum "$d/stdout" | cut -c1-10)" "$(shasum "$d/stderr" | cut -c1-10)" "$artstate" >> "$OUT"
      { echo "=== $kind $mode $n exit=$rc artifact=$artstate"; echo "--- stdout"; cat "$d/stdout"; echo "--- stderr"; cat "$d/stderr"; [ -e "$art" ] && { echo "--- artifact"; cat "$art"; }; } >> "$OUT.detail"
    done
  done
done
