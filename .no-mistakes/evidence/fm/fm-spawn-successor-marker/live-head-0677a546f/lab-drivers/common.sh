L=/Users/charlesabrooker/tmp/fm-lab.bLgx2P; W=/Users/charlesabrooker/tmp/fm-lab-work.NBfwwR; WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6HN2SACGPQ0JDT575QV98KC; P=/Users/charlesabrooker/tmp/fm-lab.bLgx2P/projects/vernant
brief() { # <id>
  mkdir -p "$L/data/$1"
  printf "# Task\n## Captain's intent\nLab task %s: exercise fm-spawn --successor-of live.\n\n## Firstmate spec\nExercise the spawn behavior under test.\n" "$1" > "$L/data/$1/brief.md"
}
spawn() { # <id> <args...>: the real CLI, as Firstmate runs it
  local id=$1; shift
  echo "+ bin/fm-spawn.sh $id projects/vernant --mode local-only --yolo off --owned-path README.md $*"
  "$WT/bin/fm-spawn.sh" "$id" "$P" --mode local-only --yolo off --owned-path README.md "$@"
}
relaunch() { echo "+ bin/fm-spawn.sh $1 --relaunch"; "$WT/bin/fm-spawn.sh" "$1" --relaunch; }
# Everything a refused declaration must not touch: state/ and data/ (minus the
# gate-context allow log the lab gate writes on every call), tmux windows, treehouse leases, markers.
snap() { (cd "$L" && { find state data -print | grep -v -e guard-events.jsonl -e home-summary | sort; find state data -type f ! -name guard-events.jsonl ! -name '*home-summary*' -exec cksum {} + | sort; }
  tmux list-windows -a -F 'window #{session_name}:#{window_name}' | sort
  find "$W/pool" -name treehouse-state.json -exec cksum {} + 2>/dev/null
  find "$W"/hook-state* "$W"/locked* -path '*worktree-supersedence*' -name '*.json' 2>/dev/null | sort); }
meta() { grep -E '^(worktree|branch|successor_of|recovery|slot_manifest|window)=' "$L/state/$1.meta"; }
markers() { find "$1/worktree-supersedence" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
marker_show() { python3 -c 'import json,sys,glob
for f in sorted(glob.glob(sys.argv[1]+"/worktree-supersedence/*.json")):
    r=json.load(open(f)); print("  marker", f.rsplit("/",1)[1], {k:r.get(k) for k in ("schema_version","carry_status","predecessor_branch","superseded_by_branch")})' "$1"; }
pred() { # <id>: spawn a real predecessor task, then give it two pushed commits
  local id=$1 pc i
  brief "$id"; spawn "$id" || return 1
  pc=$(sed -n 's/^worktree=//p' "$L/state/$id.meta")
  for i in 1 2; do printf '%s commit %s\n' "$id" "$i" > "$pc/$id-$i.txt"; git -C "$pc" add "$id-$i.txt"
    git -C "$pc" -c core.hooksPath=/dev/null -c user.name=Lab -c user.email=lab@example.invalid commit -qm "$id $i"; done
  git -C "$pc" -c core.hooksPath=/dev/null push --quiet origin "fm/$id"
  echo "predecessor $id: copy=$pc branch=$(git -C "$pc" branch --show-current) head=$(git -C "$pc" log --oneline -1)"
}
carry() { # <successor-id> <pred-id>: the worker carries the predecessor commits and adds its own
  local sc; sc=$(sed -n 's/^worktree=//p' "$L/state/$1.meta")
  git -C "$sc" -c core.hooksPath=/dev/null merge --quiet --ff-only "fm/$2" || { echo "carry failed"; return 1; }
  printf 'successor\n' > "$sc/$1.txt"; git -C "$sc" add "$1.txt"
  git -C "$sc" -c core.hooksPath=/dev/null -c user.name=Lab -c user.email=lab@example.invalid commit -qm "$1 own"
}
r13() { # <successor-id> <state-dir>: Vernant's own R-13 decision for the successor's push
  local sc br url; sc=$(sed -n 's/^worktree=//p' "$L/state/$1.meta"); br=$(git -C "$sc" branch --show-current)
  url=$(git -C "$P" remote get-url origin)
  (cd "$sc" && CODEX_HOOK_STATE_DIR="$2" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$P:$P/scripts/git-stability" "$P/.venv/bin/python" - "$1" "$br" "$url" <<'PY'
import subprocess, sys
from pathlib import Path
from scripts.hooks import pre_push_base_ref_staleness as r13
label, branch, url = sys.argv[1:4]
r13.CANONICAL_ORIGIN_URLS = frozenset({url})  # the lab bare remote stands in for the canonical origin
tip = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
foreign = r13.local_foreign_commits(Path.cwd(), budget_seconds=60)
ref = "refs/heads/" + branch
verdict = r13._classify(f"{ref} {tip} {ref} {'0' * 40}\n")
blocked = isinstance(verdict, r13.StderrBlock) and verdict.severity == "block"
print(f"  R-13 for {label} ({branch}): foreign={len(foreign)} block={'yes' if blocked else 'no'}")
if blocked: print("  R-13 says:", str(getattr(verdict, "message", verdict)).splitlines()[0][:300])
PY
  )
}
