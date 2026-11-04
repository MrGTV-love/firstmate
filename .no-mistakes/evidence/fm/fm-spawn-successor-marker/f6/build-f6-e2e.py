#!/usr/bin/env python3
"""Build the F6 end-to-end scenario from the suite in a firstmate checkout.

usage: build-f6-e2e.py <firstmate-checkout> <out-root>
Copies every tracked file of the checkout (working-tree contents) into <out-root>
and adds tests/fm-f6-e2e.test.sh: the suite's own helpers, with make_case cloning
a Vernant checkout (FM_E2E_SRC at FM_E2E_SHA) instead of a stub project, plus
the scenario test_f6_e2e. The real provision_existing_slot.py of that checkout
is used. Backend, pool and agent are the suite's stubs. Nothing in the
checkout is modified.
"""
import subprocess
import sys
from pathlib import Path

src, out = Path(sys.argv[1]), Path(sys.argv[2])
files = subprocess.run(["git", "-C", str(src), "ls-files", "-z"], check=True, capture_output=True).stdout
for name in filter(None, files.decode().split("\0")):
    target = out / name
    if (src / name).is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["cp", "-p", str(src / name), str(target)], check=True)

suite = (src / "tests/fm-spawn-pool-base-freshen.test.sh").read_text()
anchor = "# Explicit selection keeps focused acquisition regressions independently runnable.\n"
head = suite[: suite.index(anchor)]

old = head[head.index('  git init --quiet -b "$default" "$project"\n') : head.index('  git clone --quiet --bare "$project" "$origin"\n')]
new = '''  if [ -n "${FM_E2E_SRC:-}" ]; then
    git clone --quiet --no-checkout "$FM_E2E_SRC" "$project"
    git -C "$project" remote remove origin
    git -C "$project" checkout --quiet -B "$default" "$FM_E2E_SHA"
    ln -s "$FM_E2E_SRC/.venv" "$project/.venv"
  else
''' + "".join("  " + line if line.strip() else line for line in old.splitlines(True)) + "  fi\n"
head = head.replace(old, new, 1)

scenario = r'''
e2e_git() { git -C "$1" -c user.name=Tests -c user.email=tests@example.invalid "${@:2}"; }

# R-13 decision for the successor copy, using the project's own hook code.
e2e_r13() { # <label> <copy> <branch> -> prints "<label>: foreign=<n> block=<yes|no>"
  local url
  url=$(git -C "$PROJECT_DIR" remote get-url origin)
  (cd "$2" && CODEX_HOOK_STATE_DIR="$E2E_STATE" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$PROJECT_DIR:$PROJECT_DIR/scripts/git-stability" \
    "$PROJECT_DIR/.venv/bin/python" - "$1" "$3" "$url" <<'PY2'
import subprocess, sys
from pathlib import Path
from scripts.hooks import pre_push_base_ref_staleness as r13
label, branch, url = sys.argv[1:4]
r13.CANONICAL_ORIGIN_URLS = frozenset({url})
tip = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
foreign = r13.local_foreign_commits(Path.cwd(), budget_seconds=60)
ref = "refs/heads/" + branch
verdict = r13._classify(f"{ref} {tip} {ref} {'0' * 40}\n")
blocked = isinstance(verdict, r13.StderrBlock) and verdict.severity == "block"
print(f"{label}: foreign={len(foreign)} block={'yes' if blocked else 'no'}")
PY2
  )
}

e2e_pred() { # <pred-id>: a live predecessor with two commits past main, pushed
  local pid=$1 index
  successor_pred "$pid"
  for index in 1 2; do
    printf 'predecessor %s\n' "$index" > "$CASE_DIR/pred-$pid/e2e-pred-$index.txt"
    e2e_git "$CASE_DIR/pred-$pid" add "e2e-pred-$index.txt"
    e2e_git "$CASE_DIR/pred-$pid" commit -qm "predecessor $index"
  done
  git -C "$CASE_DIR/pred-$pid" push --quiet origin "fm/$pid"
}

e2e_carry() { # <copy> <pred-id>: the worker carries the predecessor's commits, then adds its own
  e2e_git "$1" merge --quiet --ff-only "fm/$2" || fail "the predecessor's commits did not carry by fast-forward"
  printf 'successor\n' > "$1/e2e-successor.txt"
  e2e_git "$1" add e2e-successor.txt
  e2e_git "$1" commit -qm successor
}

test_f6_e2e() {
  local out rc=0 meta marker_dir markers branch
  [ -n "${FM_E2E_SRC:-}" ] && [ -n "${FM_E2E_SHA:-}" ] || fail 'FM_E2E_SRC and FM_E2E_SHA name the landed Vernant checkout'
  # --- 1. positive: --successor-of records through the real helper; R-13 accepts the carried range
  make_successor_case e2e-pos none
  E2E_STATE="$CASE_DIR/hook-state"; export CODEX_HOOK_STATE_DIR="$E2E_STATE"
  e2e_pred pred-live
  out=$(run_successor_spawn --successor-of pred-live) || rc=$?
  echo "positive spawn exit=$rc"
  expect_code 0 "$rc" "the successor spawn through the real helper failed: $out"
  meta="$HOME_DIR/state/$SUCC_ID.meta"
  [ "$(successor_meta_count "$SUCC_ID" pred-live)" = 1 ] || fail 'meta lacks successor_of'
  assert_no_grep 'recovery=' "$meta" 'an admitted successor kept a recovery marker'
  marker_dir="$E2E_STATE/worktree-supersedence"
  markers=$(find "$marker_dir" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "markers in the temp state dir after the flagged spawn: $markers"
  [ "$markers" = 1 ] || fail "expected one marker written by the helper, found $markers"
  python3 -c 'import json,sys,glob; r=json.load(open(glob.glob(sys.argv[1]+"/*.json")[0])); print("marker:", {k:r[k] for k in ("schema_version","carry_status","predecessor_branch","superseded_by_branch")})' "$marker_dir"
  branch=$(git -C "$POOL_DIR" branch --show-current)
  e2e_carry "$POOL_DIR" pred-live
  e2e_r13 'flagged successor, predecessor commits carried' "$POOL_DIR" "$branch" | tee "$CASE_DIR/pos.r13"
  grep -q 'foreign=0 block=no' "$CASE_DIR/pos.r13" || fail 'R-13 did not accept the carried range for the flagged successor'

  # --- 2. negative: the same spawn without the flag leaves the hook blocking
  make_successor_case e2e-neg none
  E2E_STATE="$CASE_DIR/hook-state"; export CODEX_HOOK_STATE_DIR="$E2E_STATE"
  e2e_pred pred-live
  rc=0; out=$(run_successor_spawn) || rc=$?
  echo "no-flag spawn exit=$rc"
  expect_code 0 "$rc" "the plain spawn through the real helper failed: $out"
  [ ! -e "$E2E_STATE/worktree-supersedence" ] || fail 'a marker exists after a spawn without the flag'
  echo "markers in the temp state dir after the unflagged spawn: 0"
  branch=$(git -C "$POOL_DIR" branch --show-current)
  e2e_carry "$POOL_DIR" pred-live
  e2e_r13 'unflagged successor, predecessor commits carried' "$POOL_DIR" "$branch" | tee "$CASE_DIR/neg.r13"
  grep -q 'block=yes' "$CASE_DIR/neg.r13" || fail 'R-13 accepted the carried range without a marker'

  # --- 3. recovery: a real helper refusal keeps the declaration; the retry records the marker
  make_successor_case e2e-rec none
  E2E_STATE="$CASE_DIR/locked/hook-state"; export CODEX_HOOK_STATE_DIR="$E2E_STATE"
  mkdir "$CASE_DIR/locked"; chmod 500 "$CASE_DIR/locked"
  e2e_pred pred-live
  meta="$HOME_DIR/state/$SUCC_ID.meta"
  rc=0; out=$(run_successor_spawn --successor-of pred-live) || rc=$?
  echo "refused spawn exit=$rc"
  [ "$rc" -ne 0 ] || { chmod 700 "$CASE_DIR/locked"; fail 'the helper did not refuse with an unusable state directory'; }
  assert_contains "$out" 'slot provisioner refused task' 'the existing refusal error is missing'
  printf '%s\n' "$out" | grep -o 'supersedes_[a-z_]*' | sort -u | sed 's/^/helper refusal: /'
  assert_grep 'recovery=slot-provision-refused' "$meta" 'the refusal lost its recovery record'
  [ "$(successor_meta_count "$SUCC_ID" pred-live)" = 1 ] || fail 'the recovery record lost the declaration'
  [ ! -e "$E2E_STATE/worktree-supersedence" ] || fail 'a marker exists after a refused call'
  make_stopped_tmux "$CASE_DIR/stopped"
  chmod 700 "$CASE_DIR/locked"
  git -C "$CASE_DIR/pred-pred-live" checkout -q --detach
  rc=0; out=$(run_successor_relaunch) || rc=$?
  echo "retry with a detached predecessor exit=$rc"
  [ "$rc" -ne 0 ] || fail 'the retry admitted a predecessor that is not on its branch'
  assert_contains "$out" 'pred-live' 'the retry refusal does not name the predecessor'
  [ "$(successor_meta_count "$SUCC_ID" pred-live)" = 1 ] || fail 'the refused retry dropped the declaration'
  git -C "$CASE_DIR/pred-pred-live" checkout -q fm/pred-live
  rc=0; out=$(run_successor_relaunch) || rc=$?
  echo "retry after restoring the predecessor exit=$rc"
  expect_code 0 "$rc" "the recovery retry failed: $out"
  assert_no_grep 'recovery=slot-provision-refused' "$meta" 'the admitted retry kept the refusal marker'
  [ "$(find "$E2E_STATE/worktree-supersedence" -name '*.json' | wc -l | tr -d ' ')" = 1 ] || fail 'the retry wrote no marker through the helper'
  echo "markers in the temp state dir after the retry: 1"
  branch=$(git -C "$POOL_DIR" branch --show-current)
  e2e_carry "$POOL_DIR" pred-live
  e2e_r13 'recovered successor, predecessor commits carried' "$POOL_DIR" "$branch" | tee "$CASE_DIR/rec.r13"
  grep -q 'foreign=0 block=no' "$CASE_DIR/rec.r13" || fail 'R-13 did not accept the carried range after the recovery retry'
  pass 'F6: a successor spawned through fm-spawn gets a marker the landed Vernant R-13 accepts; without the flag it blocks; the refused retry records it'
}

test_f6_e2e
'''
(out / "tests").mkdir(exist_ok=True)
(out / "tests/fm-f6-e2e.test.sh").write_text(head + scenario)
