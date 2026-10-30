#!/usr/bin/env bash
# Live E4 reproduction: a hard link / symlink alias to a protected shared Git
# ref file made before the profile build, then a confined write through it.
# Usage: e4-alias-repro.sh <repo> <rev-or-HEAD> <harness> <alias-kind>
set -uo pipefail
repo=$1 rev=$2 harness=$3 kind=$4
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-e4.XXXXXX"); S=$(cd "$S" && pwd -P)
trap 'rm -rf "$S"' EXIT
builder="$S/builder.py"
if [ "$rev" = HEAD ]; then cp "$repo/bin/fm-write-confinement.py" "$builder"; else git -C "$repo" show "$rev:bin/fm-write-confinement.py" > "$builder"; fi
U="$S/user-home"; H="$S/home"; mkdir -p "$U/tmp" "$H"/{config,data/task,state,projects} "$S/nm/repos"
export HOME="$U" NM_HOME="$S/nm" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c user.name=F -c user.email=f@example.invalid "$@"; }
P="$H/projects/project"
g init -q -b main "$P"; g -C "$P" commit -q --allow-empty -m one
real=$(g -C "$P" commit-tree "$(g -C "$P" rev-parse HEAD^{tree})" -p HEAD -m real)
forged=$(g -C "$P" rev-parse HEAD)
g -C "$P" update-ref refs/heads/fm/other "$real"
g -C "$P" pack-refs --all
W="$S/wt"; g -C "$P" worktree add -q -b fm/task "$W"
C="$P/.git"
case "$kind" in
  hardlink-worktree) alias="$W/packed-refs-alias"; ln "$C/packed-refs" "$alias" ;;
  hardlink-data)     alias="$H/data/task/packed-refs-alias"; ln "$C/packed-refs" "$alias" ;;
  hardlink-hometmp)  alias="$U/tmp/fm-task-packed-refs-alias"; ln "$C/packed-refs" "$alias" ;;
  symlink-ref)       # loose fm/other replaced by a symlink to a worker-writable file
                     printf '%s\n' "$real" > "$W/ref-target"; mkdir -p "$C/refs/heads/fm"
                     ln -s "$W/ref-target" "$C/refs/heads/fm/other"; alias="$W/ref-target" ;;
  symlink-folder)    mkdir -p "$U/tmp/fm-task-dir"; printf '%s\n' "$real" > "$U/tmp/fm-task-dir/other"
                     ln -s "$U/tmp/fm-task-dir" "$C/refs/heads/aliased"; alias="$U/tmp/fm-task-dir/other" ;;
  symlink-refs-root) mv "$C/refs" "$U/tmp/fm-task-refs"; ln -s "$U/tmp/fm-task-refs" "$C/refs"
                     printf '%s\n' "$real" > "$U/tmp/fm-task-refs/heads/fm-other-loose"; alias="$U/tmp/fm-task-refs/heads/fm-other-loose" ;;
  symlink-logs-heads) mkdir -p "$W/fake-logs"; mv "$C/logs/refs/heads" "$W/fake-logs/heads"; ln -s "$W/fake-logs/heads" "$C/logs/refs/heads"; alias="" ;;
  none)              alias="" ;;
esac
echo "== builder=$rev harness=$harness alias=$kind"
echo "packed-refs links: $(stat -f %l "$C/packed-refs")"
echo "fm/other before: $(git -C "$P" rev-parse fm/other) (real=$real)"
args=(--worktree "$W" --home "$H" --config "$H/config" --projects "$H/projects" --data "$H/data/task" --state "$H/state" --task task --branch fm/task --harness "$harness" --profile "$S/p.sb")
[ "$harness" = claude ] && args+=(--claude-session 99999999-8888-4777-8666-555555555555)
python3 "$builder" "${args[@]}"; rc=$?
echo "build exit=$rc; profile published=$([ -e "$S/p.sb" ] && echo yes || echo no)"
if [ "$rc" -eq 0 ]; then
  if [ -n "$alias" ]; then
    case "$kind" in
      hardlink-*) payload="# pack-refs with: peeled fully-peeled sorted 
$forged refs/heads/fm/other" ;;
      symlink-ref) payload=$forged ;;
      symlink-folder) payload=$forged ;;
      symlink-refs-root) payload=$forged ;;
    esac
    /usr/bin/sandbox-exec -f "$S/p.sb" /bin/sh -c 'printf "%s\n" "$1" > "$2"' sh "$payload" "$alias"; echo "confined write through alias exit=$?"
  fi
  case "$kind" in symlink-folder) ref=aliased/other ;; symlink-refs-root) ref=fm-other-loose ;; *) ref=fm/other ;; esac
  now=$(git -C "$P" rev-parse "$ref" 2>/dev/null)
  echo "primary $ref after: $now -> $([ "$now" = "$forged" ] && echo FORGED || echo real-or-unchanged)"
  /usr/bin/sandbox-exec -f "$S/p.sb" /bin/sh -c 'printf "x\n" > "$1"' sh "$C/packed-refs" 2>&1; echo "confined direct write to packed-refs exit=$?"
  /usr/bin/sandbox-exec -f "$S/p.sb" /bin/sh -c 'ln "$1" "$2"' sh "$C/packed-refs" "$W/new-alias" 2>&1; echo "confined new hard link exit=$?"
fi
