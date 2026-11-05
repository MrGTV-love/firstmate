#!/usr/bin/env bash
# A process named shellcheck that bin/fm-lint.sh did not start holds a real lint back while the budget has no room for it.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s11; rm -rf "$S"; mkdir -p "$S/o"; root "$S/c.sh"; POOL=/var/tmp/firstmate-lint-$(id -u)/lint-slots
lint() { ( cd "$WT" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR -u FM_LINT_REQUIRE_BOUNDS CI= GITHUB_ACTIONS= FM_LINT_CACHE_DIR=off FM_LINT_HOST_RSS_KIB=1 bin/fm-lint.sh --jobs 1 "$S/c.sh" ) > "$S/$1.out" 2>&1; }
others=$("$REALPS" -axo comm= | awk '{sub(/.*\//,"")} $0=="shellcheck"{n++} END{print n+0}'); echo "other processes named shellcheck before the run: $others"
t=$SECONDS; lint control; echo "control, real ShellCheck, 1 KiB budget, nothing outside: exit=$? seconds=$((SECONDS-t)) (one root is always admitted)"
shellcheck --norc --external-sources "$WT/bin/fm-watch.sh" >/dev/null 2>&1 & O=$!; ( sleep 10; kill -KILL "$O" 2>/dev/null ) & sleep 1
echo "outside real shellcheck running, resident KiB now: $("$REALPS" -o rss= -p "$O" | tr -d " ")"
t=$SECONDS; lint held; rc=$?; took=$((SECONDS-t)); kill -0 "$O" 2>/dev/null && alive=yes || alive=no
echo "with a raw real shellcheck outside the lint, ended by this driver after 10 s: exit=$rc seconds=$took outside still alive at the end=$alive (expect it waits about 9 s, alive=no)"
wait "$O" 2>/dev/null
rm -f "$POOL/history/$(hkey "full:$S/c.sh")"; echo "fixture mark removed"
