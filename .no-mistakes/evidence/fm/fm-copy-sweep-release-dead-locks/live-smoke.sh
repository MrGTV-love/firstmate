#!/usr/bin/env bash
# live-smoke.sh - drives the REAL bin/fm-copy-sweep.sh (report mode, then the
# documented hourly one-liner `bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh --apply`)
# against a throwaway pool: real git worktrees, a real local bare remote, real
# Vernant-format creation locks, a marked disposable lab home as FM_HOME, and the
# real lsof/du/jq. Only Vernant's closeout driver is a stub: the real one lives in
# the operator's private Vernant clone and must not be run. The stub plans, and on
# --execute-cleanup it unlocks and plainly removes the copy, as the real driver does.
# Nothing here reads or writes a real pool, home, state or remote.
# Usage: live-smoke.sh <worktree> <evidence-dir>
set -u
WT=${1:?worktree}
EV=${2:?evidence dir}
OUT=$EV/live-smoke-transcript.txt
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
FAILS=0
check() { # <label> <cmd...>
  local label=$1; shift
  if "$@"; then say "PASS: $label"; else say "FAIL: $label"; FAILS=$((FAILS + 1)); fi
}

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-sweep-live.XXXXXX") || exit 1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
LIVE=
cleanup() {
  [ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null
  rm -rf "$ROOT" "$LAB"
}
trap cleanup EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || { say "lab home create failed"; exit 1; }
mkdir -p "$LAB/state" "$LAB/config" "$LAB/data"

export HOME=$ROOT/home; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
REAL_GIT=$(command -v git)
TH=$ROOT/th; SLOT=$TH/pool1/1/repo; ORIGIN=$ROOT/origin.git
mkdir -p "$TH/pool1/1" "$ROOT/bin"
"$REAL_GIT" init -q -b main "$SLOT"
printf 'base\n' > "$SLOT/base.txt"
"$REAL_GIT" -C "$SLOT" add base.txt
"$REAL_GIT" -C "$SLOT" commit -qm base
"$REAL_GIT" init -q --bare "$ORIGIN"
"$REAL_GIT" -C "$SLOT" remote add origin "$ORIGIN"
"$REAL_GIT" -C "$SLOT" push -q origin main
"$REAL_GIT" -C "$SLOT" fetch -q origin
printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
EXCL=$("$REAL_GIT" -C "$SLOT" rev-parse --path-format=absolute --git-path info/exclude)
printf '%s\n' scripts/ .venv/ scratch.bin >> "$EXCL"

# Shims record every git and treehouse call, so a forbidden sweep operation is visible.
cat > "$ROOT/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\${FAKE_DRIVER:-0}" = 1 ]; then printf '%s\n' "\$*" >> "$ROOT/git.log.driver"; else printf '%s\n' "\$*" >> "$ROOT/git.log"; fi
exec "$REAL_GIT" "\$@"
EOF
cat > "$ROOT/bin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ROOT/treehouse.log"
exit 0
EOF
chmod +x "$ROOT/bin/git" "$ROOT/bin/treehouse"

# The stub driver (stand-in for Vernant's closeout_pr.py), run by a bash "interpreter".
mkdir -p "$SLOT/scripts/git-stability"
cat > "$SLOT/scripts/git-stability/closeout_pr.py" <<EOF
export FAKE_DRIVER=1
printf '%s|%s\n' "\$PWD" "\$*" >> "$ROOT/closeout.log"
copy=\$2
if [ "\${3:-}" != --execute-cleanup ]; then
  case "\$copy" in
    *refused*) echo '{"allowed": false, "cleanup_command": ["x"], "reason": "pull_request_not_merged"}'; exit 3 ;;
  esac
  echo '{"allowed": true}'; exit 0
fi
if [ -e "$ROOT/fail-after-unlock" ] && [ "\${copy##*/}" = partial ]; then
  git worktree unlock "\$copy" || exit 4
  echo 'injected removal failure after driver released the lock'
  exit 4
fi
git worktree unlock "\$copy" || exit 4
git worktree remove "\$copy"
EOF
printf '#!/usr/bin/env bash\nexec bash "$@"\n' > "$ROOT/vpy"; chmod +x "$ROOT/vpy"

copy_path() { printf '%s\n' "$SLOT/.claude/worktrees/$1"; }
add_copy() { # <name> [tracked-MiB]
  local c; c=$(copy_path "$1")
  "$REAL_GIT" -C "$SLOT" worktree add -q -b "fm/$1" "$c"
  printf '%s\n' "$1" > "$c/$1.txt"
  [ -z "${2:-}" ] || dd if=/dev/zero of="$c/tracked.bin" bs=1048576 count="$2" 2>/dev/null
  "$REAL_GIT" -C "$c" add -A
  "$REAL_GIT" -C "$c" commit -qm "$1"
  "$REAL_GIT" -C "$c" push -q origin "fm/$1"
}
dead_pid() { local p; sleep 0.1 & p=$!; wait "$p" 2>/dev/null; printf '%s\n' "$p"; }
lock_dead() { local p; p=$(dead_pid); "$REAL_GIT" -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$p launcher=$p" "$(copy_path "$1")"; }
lockfile() { printf '%s/locked\n' "$("$REAL_GIT" -C "$(copy_path "$1")" rev-parse --absolute-git-dir)"; }

# --- fixture world ---------------------------------------------------------------
add_copy dead 128;       lock_dead dead
dd if=/dev/zero of="$(copy_path dead)/scratch.bin" bs=1048576 count=16 2>/dev/null   # ignored scratch file, preserved on release
add_copy uuidowner;      p=$(dead_pid); "$REAL_GIT" -C "$SLOT" worktree lock --reason "vernant-session-active owner=01234567-89ab-cdef-0123-456789abcdef launcher=$p" "$(copy_path uuidowner)"
add_copy refused;        lock_dead refused
add_copy livelauncher
(cd "$ROOT" && exec sleep 900) & LIVE=$!
disown "$LIVE" 2>/dev/null
"$REAL_GIT" -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$LIVE launcher=$LIVE" "$(copy_path livelauncher)"
add_copy foreignlock;    "$REAL_GIT" -C "$SLOT" worktree lock --reason 'hand-held by an operator' "$(copy_path foreignlock)"
add_copy multiline;      lock_dead multiline; printf 'extra line\n' >> "$(lockfile multiline)"
add_copy unpushedlock;   lock_dead unpushedlock
printf 'local\n' > "$(copy_path unpushedlock)/local.txt"
"$REAL_GIT" -C "$(copy_path unpushedlock)" add local.txt
"$REAL_GIT" -C "$(copy_path unpushedlock)" commit -qm local-only
add_copy plainreap

NAMES="dead uuidowner refused livelauncher foreignlock multiline unpushedlock plainreap"
for n in $NAMES; do
  "$REAL_GIT" -C "$(copy_path "$n")" rev-parse HEAD > "$ROOT/head-$n"
  [ ! -f "$(lockfile "$n")" ] || shasum -a 256 "$(lockfile "$n")" | awk '{print $1}' > "$ROOT/lockhash-$n"
done

sweep() { # <args...>: the real script, nice -n 20, process budget, 600s bound
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    PATH="$ROOT/bin:$PATH" FM_HOME="$LAB" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" FM_TEARDOWN_VERNANT_PYTHON="$ROOT/vpy" \
    nice -n 20 "$WT/bin/fm-proc-budget.sh" -- timeout 600 "$WT/bin/fm-copy-sweep.sh" "$@"
}
TAB=$(printf '\t')
row_of() { printf '%s\n' "$1" | awk -F '\t' -v p="$(copy_path "$2")" '$3 == p'; }          # <output> <name>
class_is() { [ "$(row_of "$1" "$2" | cut -f1)" = "$3" ]; }                                    # <output> <name> <class>
gone() { [ ! -e "$(copy_path "$1")" ] && ! registered "$1"; }
registered() { "$REAL_GIT" -C "$SLOT" worktree list --porcelain | grep -qxF "worktree $(copy_path "$1")"; }
unchanged_lock() { [ "$(shasum -a 256 "$(lockfile "$1")" | awk '{print $1}')" = "$(cat "$ROOT/lockhash-$1")" ]; }
held_intact() { [ -d "$(copy_path "$1")" ] && registered "$1" && unchanged_lock "$1"; }
has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
remote_head_is_original() { [ "$("$REAL_GIT" -C "$ORIGIN" rev-parse "refs/heads/fm/$1")" = "$(cat "$ROOT/head-$1")" ] \
  && [ "$("$REAL_GIT" -C "$SLOT" rev-parse "refs/heads/fm/$1")" = "$(cat "$ROOT/head-$1")" ]; }
asked_plan_only() { grep -F -- "$(copy_path "$1")" "$ROOT/closeout.log" | grep -qv -- '--execute-cleanup'; }
never_asked() { ! grep -qF -- "$(copy_path "$1")" "$ROOT/closeout.log" 2>/dev/null; }
asked_execute() { grep -F -- "$(copy_path "$1")" "$ROOT/closeout.log" | grep -qF -- '--execute-cleanup'; }
no_report_side_effects() { for n in $NAMES; do [ -d "$(copy_path "$n")" ] || return 1; done; [ ! -e "$LAB/data/copy-sweep" ] && [ ! -e "$LAB/data/copy-sweep.log" ]; }

# --- S1: report mode names candidates, calls no driver, changes nothing -------------
say "=== S1: report mode (no arguments) ==="
R1=$(sweep 2>&1); rc=$?
say "$R1"; say "exit=$rc"
check "S1 exit 0" [ "$rc" = 0 ]
check "S1 dead-launcher copy is PENDING-DRIVER (not claimed removable)" class_is "$R1" dead PENDING-DRIVER
check "S1 uuid-owner dead-launcher copy is PENDING-DRIVER" class_is "$R1" uuidowner PENDING-DRIVER
check "S1 live-launcher copy is HELD-LOCKED" class_is "$R1" livelauncher HELD-LOCKED
check "S1 foreign lock is HELD-LOCKED" class_is "$R1" foreignlock HELD-LOCKED
check "S1 multi-line lock is HELD-LOCKED" class_is "$R1" multiline HELD-LOCKED
check "S1 locked copy with an unpushed commit is HELD-UNPUSHED" class_is "$R1" unpushedlock HELD-UNPUSHED
check "S1 plain unlocked redundant copy is REAPABLE-PROVEN" class_is "$R1" plainreap REAPABLE-PROVEN
check "S1 report did not call the closeout driver" [ ! -e "$ROOT/closeout.log" ]
check "S1 report removed nothing and wrote no copy-sweep data" no_report_side_effects

# --- S2: the documented hourly command --------------------------------------------
say ""; say "=== S2: bin/fm-proc-budget.sh -- bin/fm-copy-sweep.sh --apply ==="
R2=$(sweep --apply 2>&1); rc=$?
say "$R2"; say "exit=$rc"
check "S2 exit 0" [ "$rc" = 0 ]
for n in dead uuidowner plainreap; do
  check "S2 $n has a REMOVED line" has "$R2" "REMOVED$TAB$(copy_path "$n")"
  check "S2 $n gone from disk and registry" gone "$n"
done
for n in dead uuidowner; do
  check "S2 $n branch commit preserved locally and on the remote" remote_head_is_original "$n"
  check "S2 $n: driver asked to plan, then to execute" asked_execute "$n"
done
check "S2 dead removal line reports copy / preserved / net GiB" bash -c 'printf "%s\n" "$1" | grep -E "REMOVED.*dead.*copy [0-9.]+ GiB, preserved [0-9.]+ GiB, net freed [0-9.]+ GiB" >/dev/null' _ "$R2"
check "S2 final line is the copies/GiB/reaped/freed accounting" bash -c 'printf "%s\n" "$1" | tail -n 1 | grep -E "^copies=[0-9]+ GiB=[0-9.]+ reaped=3 freed=[0-9.]+$" >/dev/null' _ "$R2"
check "S2 ignored scratch file preserved before release" bash -c 'find "$1/data/copy-sweep" -path "*/nested-copy-preserved/*" -name scratch.bin -type f | grep -q .' _ "$LAB"
check "S2 preserved bytes equal the 16 MiB source" bash -c '[ "$(find "$1/data/copy-sweep" -name scratch.bin -type f -exec wc -c {} + | head -1 | awk "{print \$1}")" = 16777216 ]' _ "$LAB"
check "S2 removal log has 3 lines" bash -c '[ "$(wc -l < "$1/data/copy-sweep.log" | tr -d " ")" = 3 ]' _ "$LAB"
check "S2 refused copy: HELD-LOCKED with the driver's own reason" bash -c 'printf "%s\n" "$1" | grep -F HELD-LOCKED | grep -F "$2" | grep -qF pull_request_not_merged' _ "$R2" "$(copy_path refused)"
check "S2 refused copy stays, registered, lock bytes unchanged" held_intact refused
check "S2 refused copy: driver only asked for its plan" asked_plan_only refused
for n in livelauncher foreignlock multiline unpushedlock; do
  check "S2 $n untouched (present, registered, lock bytes identical)" held_intact "$n"
  check "S2 $n: the closeout driver was never called" never_asked "$n"
done
check "S2 live launcher process still running" kill -0 "$LIVE"
check "S2 sweep reports GiB freed on its last line (nonzero, from 128 MiB copy)" bash -c 'printf "%s\n" "$1" | tail -n 1 | grep -vqE "freed=0\.00$"' _ "$R2"

# --- S3: driver unlocks, then removal fails: never removed later as an unlocked copy ---
say ""; say "=== S3: driver unlocks 'partial' then fails; the copy must not be removed as unlocked later ==="
add_copy partial; lock_dead partial
touch "$ROOT/fail-after-unlock"
R3=$(sweep --apply 2>&1); rc3=$?
say "$R3"; say "exit=$rc3"
check "S3 exit 1 (a removal failed)" [ "$rc3" = 1 ]
check "S3 FAILED line carries the driver's own words" bash -c 'printf "%s\n" "$1" | grep -F FAILED | grep -F "$2" | grep -qF "injected removal failure"' _ "$R3" "$(copy_path partial)"
check "S3 FAILED line names no teardown completing command" bash -c '! printf "%s\n" "$1" | grep -F FAILED | grep -qF fm-teardown.sh' _ "$R3"
check "S3 copy left on disk and registered" bash -c '[ -d "$1" ]' _ "$(copy_path partial)"
check "S3 driver released the lock (the copy now looks unlocked)" bash -c '[ ! -e "$1" ]' _ "$(lockfile partial)"
rm -f "$ROOT/fail-after-unlock"
R3b=$(sweep --apply 2>&1); rc3b=$?
say "--- rerun after the failure cause is gone ---"; say "$R3b"; say "exit=$rc3b"
check "S3 rerun holds it as HELD-LOCKED 'driver retained this copy'" bash -c 'printf "%s\n" "$1" | grep -F HELD-LOCKED | grep -F "$2" | grep -qF "driver retained this copy"' _ "$R3b" "$(copy_path partial)"
check "S3 rerun did NOT remove the now-unlocked copy" bash -c '[ -d "$1" ]' _ "$(copy_path partial)"
check "S3 rerun did not call the driver again for it (still exactly plan+execute)" bash -c '[ "$(grep -cF -- "$2" "$1")" = 2 ]' _ "$ROOT/closeout.log" "$(copy_path partial)"

# --- S4: nothing forced, hand-unlocked, deleted or returned by the sweep -----------
say ""; say "=== S4: forbidden operations by the sweep itself ==="
check "S4 sweep issued no git worktree lock/unlock and no force flag" bash -c '! grep -E "worktree (lock|unlock)|(--force|(^| )-ff?( |$))" "$1"' _ "$ROOT/git.log"
check "S4 sweep removed the unlocked copy with a plain 'worktree remove' (once)" bash -c '[ "$(grep -c "worktree remove" "$1")" = 1 ] && grep "worktree remove" "$1" | grep -vq -- "--force"' _ "$ROOT/git.log"
check "S4 the driver (not the sweep) issued the unlocks" bash -c 'grep -q "worktree unlock" "$1"' _ "$ROOT/git.log.driver"
check "S4 Treehouse was never called" [ ! -e "$ROOT/treehouse.log" ]

say ""; say "git.log (sweep-issued git calls that mutate worktrees):"
grep -E "worktree (add|remove|lock|unlock)" "$ROOT/git.log" 2>/dev/null | tee -a "$OUT"
say "closeout.log (driver invocations):"
sed "s#$ROOT#<ROOT>#g" "$ROOT/closeout.log" 2>/dev/null | tee -a "$OUT"
say ""; say "FAILS=$FAILS"
exit "$FAILS"
