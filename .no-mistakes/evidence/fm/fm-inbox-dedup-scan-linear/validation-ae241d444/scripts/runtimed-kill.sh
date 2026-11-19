#!/usr/bin/env bash
# usage: runtimed-kill.sh <tree-root> <budget-seconds> <direct|subst>
# Same as the remote leg's budget: the real fm_run_timed (bin/fm-timeout-lib.sh) wraps the
# real writer; a blocking dedup grep shim holds the writer inside the scan.
set -u
ROOT=$1; B=$2; MODE=$3
LIB="$ROOT/bin/fm-task-inbox-lib.sh"
TL="$ROOT/bin/fm-timeout-lib.sh"
STATE=$(mktemp -d "/tmp/fm-val-rt.XXXXXX")
mkdir -p "$STATE/shim" "$STATE/t1.inbox/handled"
i=0; while [ "$i" -lt 1600 ]; do i=$((i+1)); printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\nacknowledged steer %s\nsecond line\n' "$i" > "$STATE/t1.inbox/handled/$(printf '%04d' "$i").msg"; done
BLOCK=${BLOCK:-grep}
if [ "$BLOCK" = chmod ]; then
cat > "$STATE/shim/chmod" <<SH2
#!/bin/sh
case " \$* " in *".staging.record"*) printf '%s\n' "\$\$" >> "$STATE/blocked.pid"; exec /bin/sleep 300 ;; esac
exec /bin/chmod "\$@"
SH2
chmod +x "$STATE/shim/chmod"
elif [ "$BLOCK" = grep ]; then
cat > "$STATE/shim/grep" <<SH2
#!/bin/sh
case " \$* " in *" --null "*) printf '%s\n' "\$\$" >> "$STATE/blocked.pid"; exec /bin/sleep 300 ;; esac
exec /usr/bin/grep "\$@"
SH2
chmod +x "$STATE/shim/grep"
fi
if [ "$MODE" = subst ]; then
  BODY='. "$1"; rec=$(fm_task_inbox_write_idempotent "$2" t1 "$3"); echo "rec=$rec"'
else
  BODY='. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3"'
fi
export FM_STATE_OVERRIDE="$STATE"
PATH="$STATE/shim:$PATH" bash -c '. "$1"; shift; fm_run_timed "$@"' _ "$TL" "$B" bash -c "$BODY" _ "$LIB" "$STATE" "KILLED-STEER corr=T1
second" > "$STATE/out" 2> "$STATE/err"
RC=$?
sleep 1.5
pids=$(cat "$STATE/blocked.pid" 2>/dev/null | tr '\n' ' ')
alive=no; for p in $pids; do kill -0 "$p" 2>/dev/null && alive=yes; done
echo "fm_run_timed budget=${B}s writer=$MODE rc=$RC blocked_pids=[$pids] blocked_alive_after=$alive"
echo "  leftovers(after 1.5s): $(ls -a "$STATE/t1.inbox" | grep -E '^\.(dedup|work|staging|seq)' | tr '\n' ' ')"
echo "  work-dir-contents: $(ls -a "$STATE"/t1.inbox/.work.* 2>/dev/null | tr '\n' ' ')"
echo "  top-level .dedup* files: $(ls -a "$STATE/t1.inbox" | grep -c '^\.dedup' || true)  any-temp-file-holding-text: $(grep -rl 'KILLED-STEER' "$STATE/t1.inbox" 2>/dev/null | sed "s|$STATE/||" | tr '\n' ' ')"
rm -rf "$STATE"
