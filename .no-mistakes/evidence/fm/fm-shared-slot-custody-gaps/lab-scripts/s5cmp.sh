#!/usr/bin/env bash
# Compare base (8a86b966) vs change for the reassigned-both-records shape
# (A and B name the root, claim=B, slot unleased), with B's work in the root:
#   clean  : B has an unpushed commit only
#   dirty  : B also has an untracked scratch file in the root
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
for variant in clean dirty; do
  for code in base change; do
    A=cmp-$variant-$code-a; B=cmp-$variant-$code-b
    SLOT=$(new_slot) || { echo "no slot"; exit 1; }
    SLOTDIR=$(dirname "$SLOT")
    git -C "$SLOT" checkout -q -b "fm/$B"
    echo "B work" > "$SLOT/b.txt"; git -C "$SLOT" add b.txt; git -C "$SLOT" commit -qm "B unpushed work"
    [ "$variant" = clean ] || echo "B scratch" > "$SLOT/scratch.txt"
    for t in "$A" "$B"; do
      write_meta "$t" "window=fmses:fm-$t" "endpoint_task_id=$t" "worktree=$SLOT" "project=$PROJ" "harness=claude" \
        "kind=ship" "mode=no-mistakes" "branch=fm/$t" "spawn_gen=cmp.$t"
      write_brief "$t" "fm/$t"
    done
    printf 'task=%s\nhome=%s\n' "$B" "$LAB" > "$SLOTDIR/.fm-slot-owner"
    fingerprint "$SLOT" > "$W/cmp.fp"
    if [ "$code" = base ]; then script="$W/base/bin/fm-teardown.sh"; else script="$WT_ROOT/bin/fm-teardown.sh"; fi
    say "$variant / $code: $script $A"
    out=$(fm "$script" "$A" 2>&1); rc=$?
    printf '%s\n[exit %s]\n' "$(grep -v -e '^●' -e '^WARNING: watcher' -e '^fm-gate-refuse' <<<"$out")" "$rc"
    printf 'RESULT %s/%s: rc=%s A-record=%s B-record=%s slot-bytes=%s claim=%s\n' "$variant" "$code" "$rc" \
      "$([ -e "$LAB/state/$A.meta" ] && echo kept || echo retired)" \
      "$([ -e "$LAB/state/$B.meta" ] && echo kept || echo retired)" \
      "$(fingerprint "$SLOT" | cmp -s - "$W/cmp.fp" && echo unchanged || echo CHANGED)" \
      "$(tr '\n' ' ' < "$SLOTDIR/.fm-slot-owner")"
    rm -f "$LAB/state/$A.meta" "$LAB/state/$B.meta"
  done
done
