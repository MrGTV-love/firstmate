#!/usr/bin/env bash
# Live driver for `fm-control <task> rerecord-slot` against a disposable lab home.
# Sourced by each scenario shell after `eval "$(bin/fm-lab-home.sh env)"` (or the two exports it printed).
# The product under test is the run worktree's real bin/fm-control.sh; the only fixture is a throwaway
# project (bare origin, primary clone, task copy) and its create-only slot provisioner, which stands in for a
# project's own provisioner (the record source), never for firstmate.
set -u
WT_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M8F5K7F1PNN9YAGYXASRKWDP
CONTROL="$WT_ROOT/bin/fm-control.sh"
RR_ID=rrt
NOTE='Lab ruling L-1: re-record the renewed slot after the authorized forward merge'

say() { printf '\n### %s\n' "$*"; }
gitq() { git -c user.name=Lab -c user.email=lab@example.invalid "$@"; }

write_provisioner() { # <repo>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import argparse, datetime, json, os, sys
from pathlib import Path
p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
p.add_argument("--check-manifest-only", action="store_true")
a = p.parse_args()
manifest = Path(os.environ["LAB_SLOT_RECORD"])
if a.check_manifest_only:
    refused = manifest.exists()
    print(json.dumps({"state": "BLOCKED", "reason": "manifest_exists", "manifest_path": str(manifest)} if refused else {"state": "PASS"}))
    raise SystemExit(2 if refused else 0)
if manifest.exists():
    print(json.dumps({"state": "BLOCKED", "reason": "manifest_exists", "manifest_path": str(manifest)}))
    raise SystemExit(2)
record = dict(worktree_path=os.path.realpath(a.worktree_path), owner_id=a.owner_id, branch=a.branch,
              base_sha=a.base_sha, base_ref="origin/main", owned_paths=a.owned_path, lifecycle_state="worktree_active",
              repo_root=os.path.realpath(a.repo_root),
              created_at_iso=datetime.datetime.now(datetime.timezone.utc).isoformat())
manifest.write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
print(json.dumps(dict(state="PASS", manifest_path=str(manifest), **record)))
PY
}

put() { # <dir> <file=content>...
  local d=$1 pair; shift
  for pair in "$@"; do mkdir -p "$(dirname "$d/${pair%%=*}")"; printf '%s\n' "${pair#*=}" > "$d/${pair%%=*}"; done
}

# fixture <name>: a governed ship task rrt whose copy was provisioned at M0 with scope src, then main moved to M1,
# the branch merged it and added lib/new.py (new file in tracked dir lib) and changed tools/x.sh.
# Sets FX, PROJ, COPY, META, MANIFEST, M0, M1, H. Does NOT renew.
fixture() {
  FX=$(mktemp -d "$HOME/tmp/fm-rr-fx.XXXXXX")
  FX=$(cd "$FX" && pwd -P)
  PROJ="$FX/proj"; COPY="$FX/wt"; MANIFEST="$FX/manifests/manifest.json"; META="$FM_HOME/state/$RR_ID.meta"
  mkdir -p "$FX/manifests"
  git init -q --bare -b main "$FX/origin.git"
  git init -q -b main "$PROJ"
  put "$PROJ" src/owned.txt=owned docs.txt=docs
  write_provisioner "$PROJ"
  gitq -C "$PROJ" add -A; gitq -C "$PROJ" commit -qm 'M0 project with provisioner'
  git -C "$PROJ" remote add origin "$FX/origin.git"
  git -C "$PROJ" push -q origin main
  git -C "$PROJ" fetch -q origin
  git -C "$PROJ" remote set-head origin main
  M0=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" worktree add -q -b "fm/$RR_ID" "$COPY" origin/main
  LAB_SLOT_RECORD=$MANIFEST python3 "$COPY/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$PROJ" --worktree-path "$COPY" --owner-id "$RR_ID" --branch "fm/$RR_ID" --base-sha "$M0" \
    --owned-path src >/dev/null
  mkdir -p "$FM_HOME/data/$RR_ID"
  printf '# Task\n## Captain'"'"'s intent\nLab task.\n\n## Firstmate spec\nLab.\n' > "$FM_HOME/data/$RR_ID/brief.md"
  {
    echo "window=fmses:fm-$RR_ID"
    echo "endpoint_task_id=$RR_ID"
    echo "worktree=$COPY"
    echo "project=$PROJ"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=local-only"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$RR_ID"
    echo "model=default"
    echo "effort=default"
    echo "branch=fm/$RR_ID"
    echo "slot_manifest=$MANIFEST"
    echo "slot_base_sha=$M0"
    echo "slot_owned_path=src"
  } > "$META"
  # main moves forward to M1
  put "$PROJ" docs.txt=docs-at-m1 lib/a.py=a tools/x.sh=x tools/y.sh=y src/other.txt=other
  gitq -C "$PROJ" add -A; gitq -C "$PROJ" commit -qm 'main M1'
  git -C "$PROJ" push -q origin main; git -C "$PROJ" fetch -q origin
  M1=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" reset -q --hard "$M0"   # the primary clone's own checkout stays put; origin/main is M1
  # the branch: own change, forward merge, then new work
  put "$COPY" src/owned.txt=owned-by-k; gitq -C "$COPY" add -A; gitq -C "$COPY" commit -qm 'own change K'
  gitq -C "$COPY" merge -q --no-edit origin/main
  put "$COPY" lib/new.py=new tools/x.sh=x-changed; gitq -C "$COPY" add -A; gitq -C "$COPY" commit -qm 'new lib file and tools change'
  H=$(git -C "$COPY" rev-parse HEAD)
}

# renew [--owner <id>] [--base <sha>] [paths...]: the project renews the durable record (move aside, provision again).
renew() {
  local owner=$RR_ID base=$M1
  while :; do
    case "${1:-}" in
      --owner) owner=$2; shift 2 ;;
      --base) base=$2; shift 2 ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] || set -- src lib tools/x.sh
  local args=() p; for p in "$@"; do args+=(--owned-path "$p"); done
  mv "$MANIFEST" "$FX/manifests/moved-aside.$RANDOM.json"
  LAB_SLOT_RECORD=$MANIFEST python3 "$COPY/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$PROJ" --worktree-path "$COPY" --owner-id "$owner" --branch "fm/$RR_ID" --base-sha "$base" \
    "${args[@]}" >/dev/null
}

msha() { shasum -a 256 "$MANIFEST" | awk '{print $1}'; }
meta_sha() { shasum -a 256 "$META" | awk '{print $1}'; }
slot_lines() { grep -E '^(slot_base_sha|slot_owned_path)=' "$META"; }
audit_dir() { printf '%s' "$FM_HOME/data/$RR_ID/slot-rerecord"; }
inventory() { # what the verb could have written
  echo "record_sha256=$(meta_sha)"
  echo "manifest_sha256=$(msha)"
  echo "copy_head=$(git -C "$COPY" rev-parse HEAD)"
  echo "copy_status=$(git -C "$COPY" status --porcelain | tr '\n' ';')"
  echo "audit_dir_entries=$(ls "$(audit_dir)" 2>/dev/null | tr '\n' ' ')"
}

# rr <args...>: the real verb as the lock-owning main of the lab home (this shell's own Claude harness ancestry).
rr() {
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
    printf '$ fm-control %s rerecord-slot' "$RR_ID"; printf ' %q' "$@"; printf '\n'
    out=$("$CONTROL" "$RR_ID" rerecord-slot "$@" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -v '^fm-gate-refuse: gate agent lifecycle permitted only against lab home'
    exit "$rc" )
  local rc=$?; echo "exit=$rc"; return $rc
}

cleanup_fixture() {
  [ -n "${PROJ:-}" ] && git -C "$PROJ" worktree remove --force "$COPY" 2>/dev/null
  [ -n "${FX:-}" ] && rm -rf "$FX"
  rm -rf "$FM_HOME/data/$RR_ID" "$FM_HOME/state/$RR_ID".* "$FM_HOME/state/.$RR_ID".* "$FM_HOME/state/.spawn-$RR_ID.lock" 2>/dev/null
  return 0
}
