#!/usr/bin/env bash
# Drive bin/fm-guard-lint.sh against a disposable copy of the run worktree.
# Usage: drive-lint-scenarios.sh <worktree> <base-commit>
set -u
SRC=$1
BASE=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
rsync -a --exclude .git "$SRC/" "$LAB/"
cd "$LAB" || exit 2
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q && git add -A && git -c user.email=lab@x -c user.name=lab commit -qm base
commit() { git add -A && git -c user.email=lab@x -c user.name=lab commit -qm "$1"; }
reset() { git reset -q --hard "$1" && git clean -qfd; }
BASECOMMIT=$(git rev-parse HEAD)

run() { # run <label> <expected-exit> <lint args...>
  local label=$1 want=$2; shift 2
  local out rc
  out=$(bin/fm-guard-lint.sh "$@" 2>&1); rc=$?
  echo "### $label"
  echo "\$ bin/fm-guard-lint.sh $*"
  printf '%s\n' "$out" | grep -E '^(VIOLATION|STALE|LINT_SUMMARY|error)' | grep -v 'VIOLATION S1 site:' | head -8
  printf '%s\n' "$out" | grep -E 'VIOLATION S1 site:' | grep -iE 'lab|task-copy|changed line' | head -4
  if [ "$rc" = "$want" ]; then echo "exit=$rc expected=$want RESULT=PASS"; else echo "exit=$rc expected=$want RESULT=FAIL"; fi
  echo
}

NEWSITE='  echo "REFUSED: lab slot is busy; nothing was changed" >&2'

# 1. A new unregistered refusal in an already-registered owner file (bin/fm-spawn.sh), uncommitted.
reset "$BASECOMMIT"
printf '%s\n' "$NEWSITE" >> bin/fm-spawn.sh
run "S3a new unregistered REFUSED site in a registered owner file, working tree" 1 --mode new-or-touched --base HEAD
run "S3a same, enforce mode (CI step 1)" 1 --mode enforce --counts

# 2. Same site committed; CI-shaped invocation against the PR base.
commit "add site"
run "S3b committed new site, CI new-or-touched --base HEAD^1" 1 --mode new-or-touched --base HEAD^1

# 3. A new site that an existing marker would silently absorb.
reset "$BASECOMMIT"
printf '%s\n' '    "$SCRIPT_DIR/fm-guard-event.sh" teardown-unlanded deny --source-ok true 2>/dev/null || true' >> bin/fm-teardown.sh
run "S3c new site absorbed by teardown-unlanded marker (count 4 -> 5)" 1 --mode new-or-touched --base HEAD

# 4. Register the new site with full spec fields.
reset "$BASECOMMIT"
printf '%s\n' "$NEWSITE" >> bin/fm-spawn.sh
jq '.guards += [(.guards[] | select(.id=="spawn-worktree-isolation")
      | .id="lab-slot-busy" | .invariant="a lab slot that is busy is never reused"
      | .trigger="the lab slot is busy" | .instrumented=false
      | .sites=[{"file":"bin/fm-spawn.sh","match":"REFUSED: lab slot is busy"}])]
    | .beyond_audit_active += ["lab-slot-busy"]' docs/guards/registry.json > reg.tmp && mv reg.tmp docs/guards/registry.json
run "S4 same site registered with full fields, new-or-touched" 0 --mode new-or-touched --base HEAD
run "S4 same site registered, enforce" 0 --mode enforce --counts

# 5. Removing a legacy site makes its allowlist entry stale.
reset "$BASECOMMIT"
grep -v 'refusing allocation before treehouse get' bin/fm-task-copy-lib.sh > t.tmp && cat t.tmp > bin/fm-task-copy-lib.sh && rm t.tmp
run "S5a legacy allocation-guard site removed, allowlist entry left (stale)" 1 --mode enforce --counts

# 6. Allowlist may not grow: base has an unmapped site, the next commit only allowlists it.
reset "$BASECOMMIT"
printf '%s\n' "$NEWSITE" >> bin/fm-spawn.sh
commit "base with unmapped site"
id=$(python3 bin/fm-guard-sites.py | jq -r '.sites[] | select(.text|test("lab slot is busy")) | .key')
jq --arg id "$id" '.allowed += [{"id":$id,"rule":"S1","text":"lab"}]' docs/guards/lint-allowlist.json > a.tmp && mv a.tmp docs/guards/lint-allowlist.json
commit "grow allowlist"
run "S5b allowlist grows by one entry for an existing unmapped site" 1 --mode new-or-touched --base HEAD^1

# 7. Touching an allowlisted legacy site: re-indent the shared-slot teardown REFUSED line.
reset "$BASECOMMIT"
python3 - <<'PY'
p = 'bin/fm-teardown.sh'
s = open(p).read()
needle = 'echo "REFUSED: shared pool slot $slot $FM_TASK_COPY_SLOT_REASON'
i = s.index(needle)
s = s[:i] + '  ' + s[i:]
open(p, 'w').write(s)
PY
run "S5c touched (re-indented) allowlisted shared-slot teardown site, new-or-touched" 1 --mode new-or-touched --base HEAD
run "S5c same, enforce still allowlists it" 0 --mode enforce --counts

# 8. Typed unregistered count must equal the computed one.
reset "$BASECOMMIT"
jq '.unregistered_ids = ["site:bogus"]' docs/guards/registry.json > reg.tmp && mv reg.tmp docs/guards/registry.json
run "S6a typed unregistered_ids of length 1 vs computed 845" 1 --mode enforce --counts
reset "$BASECOMMIT"
ids=$(python3 bin/fm-guard-sites.py | jq -c '[.sites[] | select(.entry==null) | .key]')
jq --argjson ids "$ids" '.unregistered_ids = $ids' docs/guards/registry.json > reg.tmp && mv reg.tmp docs/guards/registry.json
run "S6b typed unregistered_ids matching the computed count" 0 --mode enforce --counts

# 9. Red-first: the base lint does not see a new unregistered refusal at all.
reset "$BASECOMMIT"
for f in bin/fm-guard-lint.sh docs/guards/registry.json docs/guards/lint-allowlist.json; do
  git -C "$SRC" show "$BASE:$f" > "$f"
done
rm -f bin/fm-guard-sites.py
printf '%s\n' "$NEWSITE" >> bin/fm-spawn.sh
echo "### RED-FIRST base lint ($BASE) with the same new unregistered site"
out=$(bin/fm-guard-lint.sh --mode enforce --counts 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^(INFO inventory|LINT_SUMMARY)'
echo "exit=$rc (base passes: the site is invisible to the old lint)"
