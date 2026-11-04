echo "labsucc0 (spawned with NO --successor-of) agent stopped; window and copy remain"
echo "=== later relaunch of the admitted NON-successor labsucc0"
relaunch labsucc0 --harness "$AGENT" | grep -v "^notice\|^local-only"
