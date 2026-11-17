#!/usr/bin/env bash
# Live driver: real bin/fm-spawn.sh and bin/fm-bootstrap.sh against a disposable
# lab home + fixture pool, using the REAL installed treehouse (unproven provider)
# behind a logging wrapper that forbids pool-mutating/diagnostic commands.
set -u
WT=$1
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
echo "FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
REAL_TH=$(command -v treehouse)
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-fix.XXXXXX")
UH=$FIX/user-home; mkdir -p "$UH"
WB=$FIX/wbin; mkdir -p "$WB"
cat > "$WB/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIX/treehouse-calls"
[ "\${2:-}" = --help ] || case "\${1:-}" in status|lease|get|return|list|prune|destroy) : > "$FIX/forbidden"; echo "FORBIDDEN \$*" >&2; exit 99;; esac
exec env HOME="$UH" TREEHOUSE_NO_UPDATE_CHECK=1 "$REAL_TH" "\$@"
SH
chmod +x "$WB/treehouse"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x.invalid
P=$FIX/project; git init -q -b main "$P"; echo hi > "$P/a"; git -C "$P" add a; git -C "$P" commit -qm init
S1=$FIX/pool/1/project; S2=$FIX/pool/2/project
mkdir -p "$FIX/pool/1" "$FIX/pool/2"
git -C "$P" worktree add -q --detach "$S1"; git -C "$P" worktree add -q --detach "$S2"
N=$S1/.claude/worktrees/nested-holder; mkdir -p "${N%/*}"
git -C "$P" worktree add -q -b nested-holder "$N"; echo unlanded > "$N/u"; git -C "$N" add u; git -C "$N" commit -qm unlanded
OLD='recovered: state file was corrupt or truncated; verify before reuse'
jq -cn --arg s1 "$S1" --arg s2 "$S2" --arg h "$OLD" '{worktrees:[{name:"1",path:$s1,leased:true,lease_holder:$h},{name:"2",path:$s2}]}' > "$FIX/pool/treehouse-state.json"
mkdir -p "$FM_HOME/state" "$FM_HOME/data/new-live" "$FM_HOME/config" "$FM_HOME/projects"
printf 'window=fmses:fm-holder\nworktree=%s\nproject=%s\nkind=ship\n' "$N" "$P" > "$FM_HOME/state/holder.meta"
printf '# Task\n## Captain'"'"'s intent\nlive check\n\n## Firstmate spec\nlive\n' > "$FM_HOME/data/new-live/brief.md"
echo codex > "$FM_HOME/config/crew-harness"
fp() { git -C "$N" rev-parse HEAD; git -C "$S1" rev-parse HEAD; git -C "$S1" status --porcelain --untracked-files=all; shasum -a 256 "$FIX/pool/treehouse-state.json" "$FM_HOME/state/holder.meta"; ls -a "$FIX/pool/1"; }
fp > "$FIX/before"
echo "=== installed provider capability answer (via wrapper)"
PATH="$WB:$PATH" treehouse capabilities --json; echo "exit=$?"
: > "$FIX/treehouse-calls"
echo "=== SCENARIO A: real bin/fm-spawn.sh new-live --scout on unproven provider, pane cwd = free slot 2"
cd "$S2"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$FM_HOME" HOME="$UH" CLAUDE_CONFIG_DIR= PATH="$WB:$PATH" "$WT/bin/fm-spawn.sh" new-live "$P" --scout 2>&1; echo "spawn exit=$?"
cd "$WT"
echo "--- treehouse calls made by spawn:"; cat "$FIX/treehouse-calls"
[ -e "$FIX/forbidden" ] && echo "FORBIDDEN COMMAND RAN" || echo "no status/lease/get/return ran"
fp > "$FIX/after"
cmp -s "$FIX/before" "$FIX/after" && echo "recovered slot 1, nested copy HEAD, pool state and holder record: byte-identical before/after" || { echo "CHANGED:"; diff "$FIX/before" "$FIX/after"; }
[ -e "$FM_HOME/state/new-live.meta" ] && echo "new-live.meta PUBLISHED" || echo "no new-live.meta published"
[ -e "$FIX/pool/1/.fm-slot-owner" ] && echo "slot 1 CLAIMED" || echo "slot 1 not claimed"
: > "$FIX/treehouse-calls"
echo "=== SCENARIO B: real bin/fm-bootstrap.sh with installed (unproven) treehouse"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$FM_HOME" HOME="$UH" PATH="$WB:$PATH" "$WT/bin/fm-bootstrap.sh" 2>&1 | grep -i 'treehouse\|recovered' ; echo "bootstrap pipeline done"
echo "--- treehouse calls made by bootstrap:"; cat "$FIX/treehouse-calls"
[ -e "$FIX/forbidden" ] && echo "FORBIDDEN COMMAND RAN" || echo "no status/lease/get/return ran"
fp > "$FIX/after2"; cmp -s "$FIX/before" "$FIX/after2" && echo "pool unchanged after bootstrap" || echo "POOL CHANGED after bootstrap"
echo "=== teardown"
tmux kill-server 2>/dev/null
"$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"
git -C "$P" worktree prune; rm -rf "$FIX"
echo "lab removed: $( [ -e "$FM_HOME" ] && echo no || echo yes ), fixture removed: $( [ -e "$FIX" ] && echo no || echo yes )"
