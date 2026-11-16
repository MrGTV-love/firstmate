#!/usr/bin/env bash
# Drives the real guard (bin/fm-slot-provision-lib.sh fm_slot_move_forward) on throwaway git repos.
# Real git, real lsof, real processes. Prints before/after state for each scenario.
set -u; PIDS=
ROOT=$1
. "$ROOT/bin/fm-task-copy-lib.sh" 2>/dev/null || true
. "$ROOT/bin/fm-slot-provision-lib.sh"
. "$ROOT/bin/fm-agent-process-lib.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-guard.XXXXXX")
trap 'for p in ${PIDS:-}; do kill $p 2>/dev/null; done; rm -rf "$T"' EXIT
G=(-c user.name=t -c user.email=t@example.invalid)
world() { # name
  D=$T/$1; P=$D/project; S=$D/slot; U=$D/pub; mkdir -p "$D"
  git init -q -b main "$P"; echo base >"$P/README.md"; printf '*.local\n' >"$P/.gitignore"
  git -C "$P" add -A; git -C "$P" "${G[@]}" commit -qm init
  git clone -q --bare "$P" "$D/origin.git"; git -C "$P" remote add origin "file://$D/origin.git"
  git -C "$P" worktree add -q --detach "$S" HEAD; git clone -q "file://$D/origin.git" "$U"
  FM_SLOT_PREPARE_DETACHED=0 FM_SLOT_PREPARED=0 FM_SLOT_EXPECT_REFS=
}
advance() { # files...
  for f in "$@"; do mkdir -p "$U/$(dirname "$f")"; echo "origin $f" >"$U/$f"; git -C "$U" add -f -- "$f"; done
  git -C "$U" "${G[@]}" commit -qm adv; git -C "$U" push -q origin main; git -C "$P" fetch -q origin
  TGT=$(git -C "$P" rev-parse origin/main)
}
state() { echo "  HEAD=$(git -C "$S" rev-parse --short HEAD) sym=$(git -C "$S" symbolic-ref -q --short HEAD || echo detached) refs=$(git -C "$S" for-each-ref --format='%(refname:short)@%(objectname:short)' refs/heads | tr '\n' ' ')"; }
run() { # label
  echo "== $1"; echo " before:"; state
  out=$(fm_slot_move_forward "$S" "$TGT" "$P" 2>&1); rc=$?
  echo " guard rc=$rc"; printf '%s\n' "$out" | sed 's/^/  | /' | head -4
  echo " after:"; state
}
world s1; advance new.txt; run "S1 clean slot behind origin (control)"
world s2; advance new.txt; echo x>"$S/w.txt"; git -C "$S" add w.txt; git -C "$S" "${G[@]}" commit -qm unlanded; run "S2 detached HEAD with unlanded commit"
world s3; advance new.txt; git -C "$S" checkout -q -b owner; echo x>"$S/w.txt"; git -C "$S" add w.txt; git -C "$S" "${G[@]}" commit -qm unlanded; run "S3 attached owner branch with unlanded commit"
world s4; advance new.txt; echo edited >>"$S/README.md"; run "S4 modified tracked file"; echo "  README now: $(tail -1 "$S/README.md")"
world s5; advance cfg.local; echo precious >"$S/cfg.local"; run "S5 ignored file at a path the target tracks"; echo "  cfg.local now: $(cat "$S/cfg.local")"
world s6; advance new.txt; echo keep >"$S/other.local"; run "S6 ignored file at an untouched path (control)"; echo "  other.local now: $(cat "$S/other.local")"
world s7; advance new.txt; (cd "$S" && exec sleep 60) & PIDS="$PIDS $!"; sleep 0.5; run "S7 live holder process with cwd in the slot"
world s8; advance new.txt; mkdir -p "$D/fakebin"; printf '#!/bin/sh\nexit 1\n' >"$D/fakebin/lsof"; chmod +x "$D/fakebin/lsof"
OLDPATH=$PATH; PATH="$D/fakebin:$PATH"; run "S8 holder list unreadable (lsof fails)"; PATH=$OLDPATH
world s9; advance new.txt; git -C "$S" checkout -q -b owner; run "S9 attached owner branch behind origin (control)"
