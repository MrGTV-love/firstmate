#!/usr/bin/env bash
# Drive bin/fm-scratch-legacy-reap.sh on a disposable temp dir that copies the measured leak shape.
set -u
WT=$1
D=$(mktemp -d "${TMPDIR:-/tmp}/nm-drive-legacy.XXXXXX"); trap 'kill $HOLD 2>/dev/null; rm -rf "$D"' EXIT
old=$(date -v-5d +%Y%m%d%H%M 2>/dev/null || date -d '5 days ago' +%Y%m%d%H%M)
for p in fm-timeout-status fm-gh-rest fm-contributions fm-session-start-stage; do
  touch -t "$old" "$D/$p.AAAAA1"; done
mkdir "$D/fm-remote-reply-ingest.OLDDIR"; touch -t "$old" "$D/fm-remote-reply-ingest.OLDDIR/x" "$D/fm-remote-reply-ingest.OLDDIR"
mkdir "$D/fm-lavish-poll.NEWFIL"; : > "$D/fm-lavish-poll.NEWFIL/f"   # old dir, fresh file inside
touch -t "$old" "$D/fm-lavish-poll.NEWFIL"
: > "$D/fm-gh-rest.FRESH1"                                             # fresh
mkdir "$D/fm-test-reap.INUSE1"; touch -t "$old" "$D/fm-test-reap.INUSE1"  # old but open (cwd)
(cd "$D/fm-test-reap.INUSE1" && exec sleep 300) & HOLD=$!
touch -t "$old" "$D/fm-drop-words.AAAAAA" "$D/other-file.AAAAAA"       # not a known prefix
mkdir "$D/fm-timeout-status.scratch"; touch -t "$old" "$D/fm-timeout-status.scratch"  # new-style container
ln -s /etc "$D/fm-fleet-tasks.SYMLNK"                                   # symlink
sleep 0.5
echo '$ fm-scratch-legacy-reap.sh --tmpdir D            (dry run)'; bash "$WT/bin/fm-scratch-legacy-reap.sh" --tmpdir "$D" | sed "s#$D#D#g"; echo "  exit=$?"
echo "entries after dry run: $(ls -A "$D" | wc -l | tr -d ' ')"
echo '$ fm-scratch-legacy-reap.sh --tmpdir D --apply'; bash "$WT/bin/fm-scratch-legacy-reap.sh" --tmpdir "$D" --apply | sed "s#$D#D#g"
echo "entries kept:"; ls -A "$D" | sed 's/^/   /'
echo '$ fm-scratch-legacy-reap.sh --apply   (no --tmpdir)'; bash "$WT/bin/fm-scratch-legacy-reap.sh" --apply >/dev/null 2>&1; echo "  exit=$?"
