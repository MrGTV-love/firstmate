#!/usr/bin/env bash
# An over-bound root is ended at the bound and retried narrower: with a stand-in, then real ShellCheck.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s6; rm -rf "$S"; mkdir -p "$S/bin"; BIN=$S/bin
echo "## stand-in that grows 8 MiB per step, bound 102400 KiB"
cat > "$BIN/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'; exit 0; fi
follow=no; for a in "$@"; do [ "$a" != --external-sources ] || follow=yes; done
printf '%s\n' "$follow" >> "$FLAGS"
[ "$follow" = yes ] || exit 0
exec perl -e 'my $h=""; for (1..60) { $h .= "x" x (8*1048576); select(undef,undef,undef,0.05) } sleep 20'
SH
chmod +x "$BIN/shellcheck"; root "$S/grow.sh"
t=$SECONDS; FLAGS=$S/flags FM_LINT_SLOT_DIR=$S/pool FM_LINT_JOBS=1 FM_LINT_ROOT_RSS_KIB=102400 L --telemetry "$S/t.tsv" "$S/grow.sh" > "$S/grow.out" 2>&1; rc=$?
echo "exit=$rc seconds=$((SECONDS-t)) attempts=$(tr '\n' ' ' < "$S/flags") (expect yes no)"
grep -E 'hit the memory ceiling|fallback passed' "$S/grow.out" | sed "s#$S/##"
awk -F '\t' '$1=="end"{print "roots log: status=" $9 " outcome=" $10 " peak_rss_kib=" $11}' "$S/t.roots.tsv"
echo; echo "## real ShellCheck $(shellcheck --version | sed -n 2p), heavy repo root, host pool, bound 2097152 KiB (2 GiB)"
ROOTF=bin/fm-watch.sh; H=/var/tmp/firstmate-lint-$(id -u)/lint-slots/history/$(hkey "full:$ROOTF")
echo "history record before: $(cat "$H" 2>/dev/null || echo none) KiB"
"$WT/bin/fm-mem-guard.sh" admit >/dev/null; echo "host admit exit=$?"
t=$SECONDS; ( cd "$WT" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR -u FM_LINT_REQUIRE_BOUNDS CI= GITHUB_ACTIONS= FM_LINT_CACHE_DIR=off FM_LINT_JOBS=1 FM_LINT_ROOT_RSS_KIB=2097152 bin/fm-lint.sh --telemetry "$S/real.tsv" "$ROOTF" ) > "$S/real.out" 2>&1; rc=$?
echo "exit=$rc seconds=$((SECONDS-t))"
grep -E 'hit the memory ceiling|fallback passed|fallback' "$S/real.out" | head -5
awk -F '\t' '$1=="end"{print "roots log: root=" $3 " status=" $9 " outcome=" $10 " peak_rss_kib=" $11}' "$S/real.roots.tsv"
echo "history record after: $(cat "$H" 2>/dev/null || echo none) KiB (a record never falls)"
