#!/usr/bin/env bash
# drive.sh <tree> <label> : run real bin/fm-on.sh (unmodified library copy) through a
# deterministic fake-ssh boundary; record stdout, stderr, exit, duration, job state.
set -u
TREE=$1; LABEL=$2; OUT=$3
T=$(mktemp -d /tmp/fmon-drive.XXXXXX); T=$(cd "$T" && pwd -P)
RR=$T/remote-root; RH=$T/remote-home; LH=$T/local-home; FB=$T/fakebin
mkdir -p "$RR/bin" "$RH" "$LH/data" "$FB"
printf 'fixture\n' > "$RR/AGENTS.md"
cp "$TREE/bin/fm-remote-entrypoint.sh" "$TREE/bin/fm-remote-job-lib.sh" "$TREE/bin/fm-remote-job-worker.sh" \
   "$TREE/bin/fm-remote-doctor.sh" "$TREE/bin/fm-tasks-axi-lib.sh" "$TREE/bin/fm-api-key-guard-lib.sh" \
   "$TREE/bin/fm-remote-herdr-owner-lib.sh" "$TREE/bin/fm-backend.sh" "$RR/bin/"
mkdir -p "$RR/bin/backends"; cp "$TREE/bin/backends/herdr.sh" "$RR/bin/backends/"
cat > "$RR/bin/fm-probe-one.sh" <<'SH'
#!/usr/bin/env bash
printf 'remote stdout line\n'; printf 'remote stderr line\n' >&2; exit "$1"
SH
cat > "$RR/bin/fm-mutate.sh" <<'SH'
#!/usr/bin/env bash
printf 'mutation\n' >> "$1"
SH
chmod +x "$RR/bin"/*.sh
git -C "$RR" init -q -b main; git -C "$RR" -c user.email=t@e -c user.name=T add AGENTS.md bin
git -C "$RR" -c user.email=t@e -c user.name=T commit -qm fixture
cat > "$FB/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "$1" = remote-mac ] || exit 91; [ "$2" = fm-remote-entrypoint.sh ] || exit 92; shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FB/fake-ssh"
printf -- '- ios - iOS delivery (host: remote-mac; root: %s; home: %s; scope: iOS work; projects: alpha; added 2026-08-02)\n' "$RR" "$RH" > "$LH/data/secondmates.md"
run() { # <name> <args...>
  local name=$1 s rc; shift
  s=$(date +%s)
  FM_HOME="$LH" FM_ROOT_OVERRIDE="$RR" FM_SSH_BIN="$FB/fake-ssh" FM_FAKE_REMOTE_ENTRYPOINT="$RR/bin/fm-remote-entrypoint.sh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$T/remote-jobs" \
    "$TREE/bin/fm-on.sh" "$@" > "$OUT/$LABEL.$name.stdout" 2> "$OUT/$LABEL.$name.stderr"
  rc=$?
  {
    echo "== $LABEL $name: fm-on.sh $*"
    echo "exit=$rc duration_s=$(( $(date +%s)-s ))"
    echo "-- stdout:"; cat "$OUT/$LABEL.$name.stdout"
    echo "-- stderr:"; cat "$OUT/$LABEL.$name.stderr"
    echo "-- state: worker.pid=$([ -e "$T/remote-jobs/worker.pid" ] && echo present || echo absent) jobs=$([ -e "$T/remote-jobs/jobs" ] && ls "$T/remote-jobs/jobs" | wc -l | tr -d ' ' || echo absent) mutation=$([ -e "$RH/mut" ] && echo ran || echo absent)"
  } | tee -a "$OUT/$LABEL.transcript.txt"
}
run exit23 ios fm-probe-one.sh 23
run mutate ios fm-mutate.sh "$RH/mut"
# teardown: stop any worker tree, then remove fixture
if [ -f "$T/remote-jobs/worker.pid" ]; then
  . "$RR/bin/fm-remote-job-lib.sh"; FM_REMOTE_JOB_STATE="$T/remote-jobs"
  fm_remote_job_stop_worker_tree "$(cat "$T/remote-jobs/worker.pid")" 2>/dev/null || true
fi
rm -rf -- "$T"
