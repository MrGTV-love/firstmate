#!/usr/bin/env bash
# Home scan (the command the heartbeat runs) after a merge-landing-tree-tested
# base-containment refusal, then a base-merge-only head change. Also one
# merge-required-reported refusal and one auto-not-armed refusal.
set -u
WT=$PWD; S=$(mktemp -d "${TMPDIR:-/tmp}/fm-r6d.XXXXXX"); trap 'rm -rf "$S"' EXIT
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
git init -q -b main "$S/origin"; echo base > "$S/origin/f"; g "$S/origin" add f; g "$S/origin" commit -m base
mkdir -p "$S/home/state"; L=$S/home/state/guard-events.jsonl
for spec in "t-contain merge-landing-tree-tested base-containment" "t-required merge-required-reported required-reported" "t-auto merge-auto-not-armed auto-not-armed"; do
  set -- $spec; git clone -q "$S/origin" "$S/$1"; g "$S/$1" checkout -b "fm/$1"; echo "impl" > "$S/$1/impl"; g "$S/$1" add impl; g "$S/$1" commit -m impl
  printf 'kind=ship\nworktree=%s\nbranch=fm/%s\nbase_branch=main\n' "$S/$1" "$1" > "$S/home/state/$1.meta"
  "$WT/bin/fm-guard-event.sh" "$2" deny --rule "$3" --task "$1" --head "$(git -C "$S/$1" rev-parse HEAD)" --base main --log "$L"
done
sleep 2; echo base2 >> "$S/origin/f"; g "$S/origin" commit -am base2
for t in t-contain t-required t-auto; do g "$S/$t" fetch -q origin; g "$S/$t" merge --no-ff -m "merge base" origin/main; done
echo "== text"; python3 "$WT/bin/fm-guard-workarounds.py" --state "$S/home/state"
echo "== json"; python3 "$WT/bin/fm-guard-workarounds.py" --state "$S/home/state" --json | jq -c '{guard,rule,task,kind}'
