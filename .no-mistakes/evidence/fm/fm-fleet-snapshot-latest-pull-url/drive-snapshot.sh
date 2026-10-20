#!/usr/bin/env bash
# Drives the REAL bin/fm-fleet-snapshot.sh --json against a disposable lab home.
# usage: drive-snapshot.sh <lab-home> <code-root>
# <code-root> is either the change worktree (new code) or a git-archive of the base commit (old code).
set -u
LAB=$1
CODE=$2
SNAP="$CODE/bin/fm-fleet-snapshot.sh"
FB="$LAB/fakebin"
mkdir -p "$FB" "$LAB/state" "$LAB/data" "$LAB/projects" "$LAB/config"
rm -f "$LAB"/state/*.meta "$LAB"/state/*.status "$LAB"/state/*.json 2>/dev/null

# Same inert stand-ins the repo's own snapshot test uses, so no live tmux/herdr session is touched.
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf '%%1\n' ;;
esac
exit 0
SH
chmod +x "$FB/no-mistakes" "$FB/tmux"

meta() { printf 'kind=ship\nremote_host=example.invalid\n' > "$LAB/state/$1.meta"; }
U=https://github.com/example/repo/pull

# Scenario 1-3: the three withdrawn-and-replaced logs from the recorded decision.
meta replacement;          printf 'done: PR %s/1 checks green\nworking: PR 1 withdrawn, replacement %s/2\n' $U $U > "$LAB/state/replacement.status"
meta replacement-decision; printf 'done: %s/1\nneeds-decision: replacement %s/2 open, which?\n' $U $U > "$LAB/state/replacement-decision.status"
meta replacement-sameline; printf 'done: PR %s/2 replaces withdrawn %s/1\n' $U $U > "$LAB/state/replacement-sameline.status"
# Scenario 4: explicit pr= metadata wins, status log never consulted for URL.
meta explicit;             printf 'pr=%s/8\n' $U >> "$LAB/state/explicit.meta"; printf 'done: %s/9\n' $U > "$LAB/state/explicit.status"
# Scenario 5: no URL anywhere.
meta absent;               printf 'working: no pull request yet\n' > "$LAB/state/absent.status"
# Scenario 6: no status log file at all.
meta nofile
# Scenario 7: invalid UTF-8 bytes on the replacement line, read under a UTF-8 locale.
meta invalid-bytes;        printf 'working: %s/10\nworking: \377\376 replacement %s/11\n' $U $U > "$LAB/state/invalid-bytes.status"
# Scenario 8: NUL byte on the replacement line.
meta nul-byte;             printf 'working: %s/12\nworking: nul\0byte replacement %s/13\n' $U $U > "$LAB/state/nul-byte.status"
# Scenario 9: last URL-bearing line wins even when a later line has no URL; trailing line without newline.
meta trailing-nourl;       printf 'working: %s/20\ndone: %s/21\nworking: still going, no url\n' $U $U > "$LAB/state/trailing-nourl.status"
meta no-newline;           printf 'working: %s/30\nnote: compare %s/31 and %s/32' $U $U $U > "$LAB/state/no-newline.status"
# Scenario 10: non-GitHub forge URL shapes + URL in quotes/parens delimiters.
meta paren-url;            printf 'done: (see %s/40) ok\n' $U > "$LAB/state/paren-url.status"
meta gitlabish;            printf 'done: https://gitlab.example.com/g/p/-/pull/50 merged\n' > "$LAB/state/gitlabish.status"

PATH="$FB:$PATH" FM_HOME="$LAB" LC_ALL="${DRIVE_LOCALE:-C}" "$SNAP" --json | jq -c '.tasks[] | {id, url:.pr.url, source:.pr.source}'
