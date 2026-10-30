#!/usr/bin/env bash
# Live drive: bin/fm-scratch-legacy-reap.sh with real lsof on a disposable temp dir.
set -u
WT=$1; SB=$(mktemp -d /tmp/fmnm-s4.XXXXXX); D=$SB/t; mkdir -p "$D"
R=$WT/bin/fm-scratch-legacy-reap.sh
for p in fm-timeout-status fm-fleet-tasks fm-gh-rest fm-remote-reply-ingest fm-contributions fm-session-start-stage fm-lavish-poll fm-test-reap fm-bash-timeout-command; do mkdir "$D/$p.OLD123"; echo x > "$D/$p.OLD123/f"; done
: > "$D/fm-timeout-status.OLDF12"                    # old file entry
mkdir "$D/fm-gh-rest.FRESH1"                         # young: keep
mkdir "$D/fm-gh-rest.INUSE1"                         # old but a process has its cwd in it: keep
mkdir "$D/fm-fleet-tasks.tok123.ABCDEF"              # carries an owner token: not a candidate
mkdir "$D/fm-unrelated.OLD123" "$D/fm-gh-rest.scratch" # other fm-* and a scratch container: keep
ln -s "$SB" "$D/fm-contributions.LINK12"             # symlink: keep
find "$D" -mindepth 1 ! -name 'fm-gh-rest.FRESH1' -exec touch -h -t 202001010000 {} \;
(cd "$D/fm-gh-rest.INUSE1" && exec sleep 60) & holder=$!; sleep 0.5
echo "--- no --tmpdir (must refuse, even with --apply)"; "$R" --apply; echo "rc=$?"
echo "--- dry run"; "$R" --tmpdir "$D"; echo "rc=$?"; echo "entries now: $(ls "$D" | wc -l | tr -d ' ') (dry run removes nothing)"
echo "--- apply"; "$R" --tmpdir "$D" --apply; echo "rc=$?"
echo "--- left in the temp dir:"; ls -1 "$D"
kill $holder; wait $holder 2>/dev/null; rm -rf "$SB"
