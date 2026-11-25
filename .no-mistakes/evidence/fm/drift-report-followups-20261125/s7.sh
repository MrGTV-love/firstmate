#!/usr/bin/env bash
# driver.sh <tree>: drive the real bin/fm-control.sh relaunch (stubbed tmux session provider) in a throwaway home.
TREE=$1
. "$TREE/tests/fm-control-relaunch-helpers.sh"
. "$TREE/tests/fm-control-relaunch-slot-helpers.sh"
trap relaunch_cleanup EXIT
SHIM=$TMP_ROOT/shim; mkdir -p "$SHIM"
REALMV=$(command -v mv) REALPY=$(command -v python3)
say() { printf '\n===== %s =====\n' "$*"; }
id=lane
say "S7 skip-worktree names with a space, a newline and a backslash, changed and unchanged (SF5)"
make_adopt_case live7 lane7 src
WT7=$ADOPT_DIR/wt
for f in 'docs/sp ace' 'docs/sp same' $'docs/new\nline' $'docs/new\nsame' 'docs/back\slash' 'docs/back\same'; do
  mkdir -p "$WT7/docs"; printf 'unusual name\n' > "$WT7/$f.txt"; done
git -C "$WT7" add -A && git -C "$WT7" -c user.name=T -c user.email=t@example.invalid commit -qm 'unusual names'
nb=$(git -C "$WT7" rev-parse HEAD)
git -C "$WT7" update-ref refs/remotes/origin/main "$nb"
sed -i '' "s/^slot_base_sha=.*/slot_base_sha=$nb/" "$ADOPT_META"
python3 - "$ADOPT_MANIFEST" "$nb" <<'PY'
import json,sys; p,b=sys.argv[1:]; d=json.load(open(p)); d["base_sha"]=b; json.dump(d,open(p,"w"),sort_keys=True)
PY
git -C "$WT7" update-index --skip-worktree 'docs/sp ace.txt' 'docs/sp same.txt' $'docs/new\nline.txt' $'docs/new\nsame.txt' 'docs/back\slash.txt' 'docs/back\same.txt'
for f in 'docs/sp ace' $'docs/new\nline' 'docs/back\slash'; do printf 'unusual name, changed\n' > "$WT7/$f.txt"; done
echo "git status --porcelain (hidden): [$(git -C "$WT7" status --porcelain)]"
echo "skip-worktree entries: $(git -C "$WT7" ls-files -v | grep -c '^S ')"
out=$(run_adopt_control "$ADOPT_DIR" lane7); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|^  drift' | sort -u | sed 's/^/  | /'
