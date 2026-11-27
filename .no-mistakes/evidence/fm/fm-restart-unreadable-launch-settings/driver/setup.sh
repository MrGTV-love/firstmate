#!/usr/bin/env bash
# Stand up one disposable lab: a marked lab FM_HOME, a guarded fm-lab-* Herdr
# session, a herdr PATH shim that routes every call through fm-herdr-lab.sh run,
# a secondmate task record bound to a real lab pane. Writes $LAB/env.sh.
set -eu
unset FM_SPAWN_GEN HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV HERDR_SESSION HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX TMUX_PANE
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8E3M26SDN99JSRN9AT978AC
DRV=$(cd "$(dirname "$0")" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-nmt.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
eval "$("$ROOT/bin/fm-lab-home.sh" env 2>"$LAB/labhome.stderr")"
SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name rattr)
"$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" >"$LAB/provision.log" 2>&1
mkdir -p "$LAB/fakebin" "$LAB/bin"
cc -O2 -o "$LAB/bin/claude" "$DRV/fake-claude.c"
REAL_PATH=$PATH
cat > "$LAB/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || exit 91; shift 2 ;;
    --session=*) exit 91 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "${args[0]:-}" = --version ]; then exec env PATH="$FM_LAB_REAL_PATH" herdr --version; fi
PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/fakebin/herdr"
git init -q "$LAB/proj"; git -C "$LAB/proj" commit -q --allow-empty -m init
git -C "$LAB/proj" worktree add -q "$LAB/wt" -b sm-labmate
WT="$LAB/wt"
mkdir -p "$WT/state" "$WT/data" "$WT/bin" "$FM_HOME/config"
printf 'labmate\n' > "$WT/.fm-secondmate-home"; printf '# lab home\n' > "$WT/AGENTS.md"; printf '# lab charter\n' > "$WT/data/charter.md"
printf 'claude\n' > "$FM_HOME/config/secondmate-harness"
printf 'herdr\n' > "$FM_HOME/config/backend"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
cat > "$LAB/env.sh" <<ENV
export ROOT='$ROOT' LAB='$LAB' DRV='$DRV' FM_HOME='$FM_HOME' TMUX_TMPDIR='$TMUX_TMPDIR'
export SESSION='$SESSION' WT='$WT' FM_LAB_SESSION='$SESSION' FM_LAB_REAL_PATH='$REAL_PATH' FM_LAB_HELPER='$ROOT/bin/fm-herdr-lab.sh'
export PATH='$LAB/fakebin:$REAL_PATH' HERDR_SESSION='$SESSION'
unset FM_SPAWN_GEN HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_ENV HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX TMUX_PANE
ENV
echo "LAB=$LAB"; echo "SESSION=$SESSION"; cat "$LAB/labhome.stderr"
