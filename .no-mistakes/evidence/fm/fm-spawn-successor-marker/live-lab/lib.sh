SB=$SB
. "$SB/env.sh"
say() { printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
note() { printf '%s\n' "$*" | tee -a "$LOG"; }
run() { # echoes command, tees output, records rc in RC
  printf '$ %s\n' "$*" | sed "s#$SB#\$SB#g; s#$FM_HOME#\$FM_HOME#g; s#$WT#\$WT#g" | tee -a "$LOG"
  "$@" > "$SB/.out" 2>&1; RC=$?
  sed "s#$SB#\$SB#g; s#$FM_HOME#\$FM_HOME#g; s#$WT#\$WT#g" "$SB/.out" | tail -${TAILN:-25} | tee -a "$LOG"
  printf '[exit %s]\n' "$RC" | tee -a "$LOG"
}
brief() { mkdir -p "$FM_HOME/data/$1"; cat > "$FM_HOME/data/$1/brief.md" <<B
# Task
## Captain's intent
Lab successor validation for $1.

## Firstmate spec
Exercise the spawn behavior under test. Do nothing else.
B
}
spawn() { (cd "$FM_HOME" && lab "$WT/bin/fm-proc-budget.sh" -- "$WT/bin/fm-spawn.sh" "$@"); }
meta() { sed -n "s/^$2=//p" "$FM_HOME/state/$1.meta" | tail -1; }
lg() { lab git "$@"; }
snap() { (cd "$FM_HOME" && find state data -print | sort); ltmux list-windows -t firstmate -F '#{window_name}'; (cd "$SB/proj" && lab treehouse status 2>&1 | wc -l); git -C "$SB/proj" worktree list | wc -l; ls "$SB/treehouse/.treehouse/" 2>/dev/null | wc -l; }
H='--harness'
LAUNCH='sleep 86400'
