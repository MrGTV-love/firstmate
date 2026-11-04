#!/usr/bin/env bash
# Live lab drive of bin/fm-idle-session-reap.sh (real CLI) in a disposable,
# marked lab home minted by bin/fm-lab-home.sh env.
#
# Usage: lab-idle-reap.sh <worktree> <bin-dir-under-test> <real-closeout-output-file>
#
# Teardown is the sweep's documented seam FM_IDLE_REAP_TEARDOWN_BIN. The stand-in
#  - runs bin/fm-teardown.sh's real automatic-reap admission block, cut verbatim
#    from <worktree>/bin/fm-teardown.sh at setup time (the block that refused a
#    changed copy behind its own stale memo before the review fix);
#  - when admitted, plays Vernant's closeout driver as the incident showed it:
#    writes one more byte-identical tar of the copy's ignored files under
#    <slot>/vernant/.claude/bug-evidence/worktree-preservation/, keeps the tree,
#    and prints the refusal the real teardown printer (teardown_closeout_refusal,
#    bin/fm-teardown-nested-lib.sh) makes from a real recorded driver output.
# The real Vernant driver is never run (hard gate).
set -u
WT=$1; BIN=$2; REAL_OUT=$3
cd "$WT"
for v in NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do unset "$v"; done
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
cleanup() {
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 && rm -rf "$LAB"
  echo "lab torn down: $( [ -e "$LAB" ] && echo NO || echo yes )"
}
trap cleanup EXIT
echo "lab home: $LAB (marked lab, plain FM_HOME, no overrides)"
echo "bin under test: $BIN ($(git -C "$WT" rev-parse --short HEAD) worktree; base export when the path is not the worktree)"
STATE=$LAB/state; DATA=$LAB/data
printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
NOW=$(date +%s); OLD=$((NOW - 7200))

# --- the disposable Vernant-like slot, copy and fixed ignored payload -------
SLOT=$LAB/slot/vernant
ARCH=$SLOT/.claude/bug-evidence/worktree-preservation
COPY=$SLOT/.claude/worktrees/fm-cl-l2
mkdir -p "$ARCH" "$COPY"
git -C "$COPY" init -q
printf 'node_modules/\n' > "$COPY/.gitignore"
printf 'readme\n' > "$COPY/README.md"
git -C "$COPY" add -A && git -C "$COPY" -c user.name=lab -c user.email=lab@example.invalid commit -qm base
mkdir -p "$COPY/node_modules/pkg" && printf 'ignored payload\n' > "$COPY/node_modules/pkg/index.js"

# --- the stand-in teardown ---------------------------------------------------
SB=$LAB/stub; mkdir -p "$SB"
awk '/^if \[ "\$\{FM_IDLE_REAP_ADMISSION:-0\}" = 1 \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$WT/bin/fm-teardown.sh" > "$SB/admission-block.sh"
# Real-shape refusal from the real printer and a real recorded driver output.
(
  . "$WT/bin/fm-refuse-lib.sh"
  eval "$(sed -n '/^teardown_closeout_refusal() {/,/^}/p' "$WT/bin/fm-teardown-nested-lib.sh")"
  DATA=$LAB/data; ID=cl
  TEARDOWN_CLOSEOUT_OUT=$(cat "$REAL_OUT")
  teardown_closeout_refusal 'own nested' "$COPY" 3
) 2> "$SB/closeout-refusal.txt"
cat > "$SB/teardown" <<SH
#!/usr/bin/env bash
id=\$1
mode=\$(cat "$SB/mode.\$id" 2>/dev/null || echo closeout)
memo=0; [ ! -e "\$FM_HOME/state/.idle-reap/\$id.refused" ] || memo=1
printf '%s call id=%s mode=%s memo_present_at_call=%s admission_marker=%s\n' "\$(date +%s)" "\$id" "\$mode" "\$memo" "\${FM_IDLE_REAP_ADMISSION:-}" >> "$SB/calls.log"
FORCE=; ID=\$id; STATE=\$FM_HOME/state; DATA=\$FM_HOME/data; SCRIPT_DIR="$BIN"
teardown_require_source() { [ -f "\$1" ] && [ -r "\$1" ] || { echo "error: missing \$1" >&2; exit 1; }; }
# bin/fm-teardown.sh's admission block, verbatim:
. "$SB/admission-block.sh"
printf '  admitted id=%s\n' "\$id" >> "$SB/calls.log"
case "\$mode" in
  closeout)
    n=\$(find "$ARCH" -type f -name '*.tar' | wc -l | tr -d ' ')
    ( cd "\$(sed -n 's/^worktree=//p' "\$FM_HOME/state/\$id.meta")" && COPYFILE_DISABLE=1 tar -cf - --format ustar --uid 0 --gid 0 --uname root --gname root node_modules ) > "$ARCH/\$id-preservation-\$((n + 1)).tar"
    touch -t 202601010000 "$ARCH/\$id-preservation-\$((n + 1)).tar"
    cat "$SB/closeout-refusal.txt" >&2; exit 1 ;;
  refuse) echo "REFUSED: task \$id has work that has not landed" >&2; exit 1 ;;
  ok) rm -f "\$FM_HOME/state/\$id".*; exit 0 ;;
esac
SH
chmod +x "$SB/teardown"

mk_task() {  # <id> <worktree>
  local id=$1
  printf '%s\n' "window=w:$id" "kind=scout" "harness=claude" "backend=tmux" "worktree=$2" > "$STATE/$id.meta"
  printf 'done [at=%s]: report written\n' "$OLD" > "$STATE/$id.status"
  printf 'g1.1.1\n' > "$STATE/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$STATE/$id.busy-state"
  mkdir -p "$DATA/$id"; printf '# report\nfindings\n' > "$DATA/$id/report.md"
  touch -t "$(date -r "$OLD" +%Y%m%d%H%M.%S)" "$DATA/$id/report.md"
}
mk_task cl "$COPY"

reap() { FM_HOME="$LAB" FM_IDLE_REAP_TEARDOWN_BIN="$SB/teardown" "$BIN/fm-idle-session-reap.sh" "$@"; }
calls() { local n; n=$(grep -c " call id=$1 " "$SB/calls.log" 2>/dev/null) || true; printf "%s" "${n:-0}"; }
archives() { find "$ARCH" -type f -name '*.tar' | wc -l | tr -d ' '; }
wakes() { local n; n=$(grep -cF -- "$1" "$STATE/.wake-queue" 2>/dev/null) || true; printf "%s" "${n:-0}"; }
age_memo() {  # <id> <seconds-old>
  local m="$STATE/.idle-reap/$1.refused"
  [ -f "$m" ] || { echo "  (no memo for $1 to age)"; return 0; }
  sed -i.bak "2s/.*/$((NOW - $2))/" "$m" && rm -f "$m.bak"
}
row() { printf '%s' "$1" | awk -F'\t' -v id="$2" '$2 == id { print $1 " | " $NF }'; }
show() {  # <label>
  printf '%-58s cl_calls=%s archives=%s wake_rows_naming_copy=%s record=%s memo=%s\n' "$1" "$(calls cl)" "$(archives)" "$(wakes "$COPY")" \
    "$([ -f "$STATE/.closeout-retained/cl" ] && sed -n 4p "$STATE/.closeout-retained/cl" || echo none)" \
    "$([ -f "$STATE/.idle-reap/cl.refused" ] && echo present || echo none)"
}

echo; echo "== U: an unchanged retained copy =="
reap reap >/dev/null 2>&1; show "sweep 1 (first refusal)"
reap reap >/dev/null 2>&1; show "sweep 2 (fresh memo, unchanged)"
age_memo cl 100000; reap reap >/dev/null 2>&1; show "sweep 3 (memo aged 100000s > 21600s)"
age_memo cl 186400; reap reap >/dev/null 2>&1; show "sweep 4 (clock a further day)"
echo "scan row: $(row "$(reap scan 2>&1)" cl)"
echo "wake row: $(grep -F -- "$COPY" "$STATE/.wake-queue" | sed "s#$LAB#<lab>#g")"
echo "record:"; sed "s#$LAB#<lab>#g; s/^/  /" "$STATE/.closeout-retained/cl"
echo "archive sha256s:"; (cd "$ARCH" && shasum -a 256 *.tar | sed 's/^/  /')

echo; echo "== D: the wake is consumed with the real bin/fm-wake-drain.sh =="
drain_out=$(FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" 2>&1); echo "$drain_out" | sed "s#$LAB#<lab>#g" | grep -E 'WAKE_ACK|check:' | head -5 | sed 's/^/  drain: /'
ack=$(printf '%s\n' "$drain_out" | sed -n 's/.*run bin\/fm-wake-drain.sh \(--ack-through [0-9]* --recovery-generation [^ ]*\).*/\1/p' | tail -n 1)
if [ -n "$ack" ]; then
  # shellcheck disable=SC2086
  FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" $ack 2>&1 | sed "s#$LAB#<lab>#g; s/^/  ack: /" | head -3
else
  echo "  (no ack command printed; emptying the lab queue file instead)"; : > "$STATE/.wake-queue"
fi
echo "  pending rows after ack: $(FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" --queued 2>/dev/null | grep -cF -- "$COPY")"
before=$(wakes "$COPY")
age_memo cl 300000; reap reap >/dev/null 2>&1; show "sweep 5 (wake consumed, memo aged, unchanged)"
echo "  queue rows naming the copy before sweep 5: $before, after: $(wakes "$COPY"); pending after: $(FM_HOME="$LAB" "$WT/bin/fm-wake-drain.sh" --queued 2>/dev/null | grep -cF -- "$COPY")"

memo_age() { local m="$STATE/.idle-reap/cl.refused"; [ -f "$m" ] && echo "$(( $(date +%s) - $(sed -n 2p "$m") ))s" || echo none; }
admitted() { grep -c "admitted id=cl" "$SB/calls.log" 2>/dev/null || true; }
echo; echo "== C: the copy changes (new commit); memo is the old aged one =="
printf 'more\n' > "$COPY/more.txt"; git -C "$COPY" add more.txt; git -C "$COPY" -c user.name=lab -c user.email=lab@example.invalid commit -qm more
echo "  memo age before sweep 6: $(memo_age)"
out=$(reap reap 2>&1); show "sweep 6 (HEAD changed)"; echo "  sweep 6 row: $(row "$out" cl | cut -c1-140)"
echo "== C2: an untracked file appears right after sweep 6's refusal (memo FRESH, < 6h) =="
echo "  memo age before sweep 7: $(memo_age)"
printf 'new\n' > "$COPY/new.txt"
out=$(reap reap 2>&1); show "sweep 7 (status changed, fresh memo)"; echo "  sweep 7 row: $(row "$out" cl | cut -c1-140)"
echo "== C3: a tracked file is modified right after sweep 7 (memo FRESH) =="
echo "  memo age before sweep 8: $(memo_age)"
printf 'edit\n' >> "$COPY/README.md"
out=$(reap reap 2>&1); show "sweep 8 (status changed, fresh memo)"; echo "  sweep 8 row: $(row "$out" cl | cut -c1-140)"
echo "  closeout-class tries admitted by teardown's real admission block so far: $(admitted)"
age_memo cl 100000; reap reap >/dev/null 2>&1; show "sweep 9 (unchanged since sweep 8, memo aged: held)"

echo; echo "== O: another refusal class keeps its 6h retry =="
OCOPY=$LAB/other-copy; git -C "$LAB" init -q other-copy; printf 'x\n' > "$OCOPY/x"; git -C "$OCOPY" add -A; git -C "$OCOPY" -c user.name=lab -c user.email=lab@example.invalid commit -qm x
mk_task ot "$OCOPY"; printf 'refuse\n' > "$SB/mode.ot"
reap reap >/dev/null 2>&1; echo "ot sweep 1: calls=$(calls ot) record=$([ -e "$STATE/.closeout-retained/ot" ] && echo present || echo none) wakes_naming_copy=$(wakes "$OCOPY")"
reap reap >/dev/null 2>&1; echo "ot sweep 2 (fresh memo): calls=$(calls ot)"
age_memo ot 100000; reap reap >/dev/null 2>&1; echo "ot sweep 3 (memo aged): calls=$(calls ot) record=$([ -e "$STATE/.closeout-retained/ot" ] && echo present || echo none)"
rm -f "$STATE/ot".* ; rm -rf "$OCOPY"

echo; echo "== B: boundary: more edits to an already-modified tracked file (HEAD and git status unchanged) =="
printf 'edit again\n' >> "$COPY/README.md"
age_memo cl 100000; reap reap >/dev/null 2>&1; show "sweep 9b (same HEAD, same status line set, memo aged)"
echo "  git status --porcelain: $(git -C "$COPY" status --porcelain | tr '\n' ';')"

echo; echo "== S: a teardown that completes clears the record =="
printf 'done\n' > "$COPY/done.txt"; printf 'ok\n' > "$SB/mode.cl"
reap reap >/dev/null 2>&1; show "sweep 10 (changed copy, teardown exits 0)"
echo "  task meta: $([ -e "$STATE/cl.meta" ] && echo present || echo gone); closeout record files left: $(ls -A "$STATE/.closeout-retained" 2>/dev/null | wc -l | tr -d ' ')"
echo; echo "final teardown call log:"; sed 's/^/  /' "$SB/calls.log"
