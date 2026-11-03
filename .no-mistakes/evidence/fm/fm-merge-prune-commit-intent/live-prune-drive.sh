#!/usr/bin/env bash
# live-prune-drive.sh <repo-bin-dir> <label>
# Drives the real bin/fm-merge-prune.sh (arm, then run --now) against a REAL
# treehouse pool in a throwaway TREEHOUSE_ROOT, inside a marked lab FM_HOME
# minted by bin/fm-lab-home.sh. HOME is a throwaway dir so ~/.treehouse is never
# touched. Only teardown and control are replaced through the script's own test
# seams (FM_MERGE_PRUNE_TEARDOWN_BIN / FM_MERGE_PRUNE_CONTROL_BIN): the teardown
# seam returns the slot with the real `treehouse return` and deletes the task
# record, the way a successful teardown does. Everything after that - the
# returned-slot proof, the ignored-file classifier, the CommitIntent predicate,
# and the real `treehouse destroy` - is the product.
set -u
BIN=$1
LABEL=$2
REPO_BIN=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6GHYMJ4PR1F87M2ZQ7X25VZ/bin
REAL_TREEHOUSE=$(command -v treehouse)
REAL_PY=$(command -v python3)

INTENT_TMPL='{"artifacttype":"CommitIntent","schemaversion":"1","branch":"%s","head_sha":"0123456789abcdef0123456789abcdef01234567","owned_paths":["scripts/hooks/commit_intent.py"],"validators":["pytest -q"],"expires_at_iso":"%s"}'

run_case() {  # <name> <setup-function>
  local name=$1 setup=$2 lab home W slot rc wake destroys exists
  eval "$("$REPO_BIN/fm-lab-home.sh" env 2>/dev/null)"
  lab=$FM_HOME
  W=$(mktemp -d "${TMPDIR:-/tmp}/fm-intent-live.XXXXXX")
  home="$W/fakehome"; mkdir -p "$home" "$W/bin"
  export HOME="$home" TREEHOUSE_ROOT="$W/th"
  export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
  git init -q --bare "$W/origin.git"; git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$W/origin.git" "$W/project" 2>/dev/null
  git -C "$W/project" checkout -q -b main
  printf '.claude/\n' > "$W/project/.gitignore"; printf 'readme\n' > "$W/project/README.md"
  git -C "$W/project" add -A; git -C "$W/project" commit -q -m base; git -C "$W/project" push -q origin main
  slot=$(cd "$W/project" && "$REAL_TREEHOUSE" get --lease 2>"$W/get.err") || { echo "[$LABEL] $name: treehouse get failed: $(cat "$W/get.err")"; "$REPO_BIN/fm-lab-home.sh" teardown "$lab" >/dev/null 2>&1 && rm -rf "$lab"; rm -rf "$W"; return 1; }
  # Teardown seam: return the slot for real, delete the task record, succeed.
  cat > "$W/bin/teardown" <<SH
#!/usr/bin/env bash
"$REAL_TREEHOUSE" return "$slot" >>"$W/return.log" 2>&1 || exit 1
rm -f "$lab/state/\$1.meta"
echo "teardown: returned $slot"
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/control"
  # A treehouse wrapper first on PATH that logs each call and runs the real tool.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexec %q "$@"\n' "$W/th.log" "$REAL_TREEHOUSE" > "$W/bin/treehouse"
  chmod +x "$W/bin/teardown" "$W/bin/control" "$W/bin/treehouse"
  mkdir -p "$lab/state" "$lab/data"
  printf 'kind=ship\nworktree=%s\nproject=%s\npr=https://github.com/acme/widget/pull/7\nbranch=fm/t1\n' "$slot" "$W/project" > "$lab/state/t1.meta"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$lab/state/t1.pr-poll-merge-notified"
  chmod 0600 "$lab/state/t1.pr-poll-merge-notified"
  mkdir -p "$slot/.claude"
  "$setup" "$slot" "$W"
  echo "[$LABEL] === $name"
  echo "  python3 the prune sees: $(PATH="${CASE_PATH_PREFIX:+$CASE_PATH_PREFIX:}$W/bin:$PATH" command -v python3) -> $(PATH="${CASE_PATH_PREFIX:+$CASE_PATH_PREFIX:}$W/bin:$PATH" python3 --version 2>&1)"
  for f in "$slot/.claude/commit-intent.json" "$slot/.claude/commit-intent.json.bak" "$slot/.claude/private/x"; do
    [ -f "$f" ] && echo "  file ${f#"$slot"/}: $(cat "$f")"
  done
  echo "  slot=$slot ($(git -C "$slot" status --porcelain | wc -l | tr -d ' ') status lines; ignored: $(git -C "$slot" ls-files -o -i --exclude-standard -z | tr '\0' ' '))"
  PATH="${CASE_PATH_PREFIX:+$CASE_PATH_PREFIX:}$W/bin:$PATH" FM_MERGE_PRUNE=1 \
    FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown" FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control" FM_MERGE_PRUNE_EXIT_WAIT=2 \
    env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    bash -c '"$1/fm-merge-prune.sh" arm t1 && "$1/fm-merge-prune.sh" run t1 --now' _ "$BIN" >"$W/run.out" 2>&1
  rc=$?
  if [ -e "$slot" ]; then exists=present; else exists=GONE; fi
  wake=$(grep -c 'merge-prune' "$lab/state/.wake-queue" 2>/dev/null) || wake=0
  destroys=$(grep -c '^destroy ' "$W/th.log" 2>/dev/null) || destroys=0
  echo "  exit=$rc copy=$exists treehouse_destroy_calls=$destroys wakes=$wake"
  [ ! -s "$W/run.out" ] || sed 's/^/  out: /' "$W/run.out"
  [ ! -f "$lab/state/t1.merge-prune" ] || { echo "  prune record:"; sed 's/^/    /' "$lab/state/t1.merge-prune"; }
  [ ! -f "$lab/data/t1/merge-prune.log" ] || { echo "  merge-prune.log:"; sed 's/^/    /' "$lab/data/t1/merge-prune.log"; }
  [ ! -f "$lab/state/.wake-queue" ] || { echo "  wake queue:"; sed 's/^/    /' "$lab/state/.wake-queue"; }
  echo "  treehouse status after: $(cd "$W/project" && "$REAL_TREEHOUSE" status 2>&1 | tr '\n' ' ' | cut -c1-200)"
  # Teardown of this case's lab.
  (cd "$W/project" && "$REAL_TREEHOUSE" destroy "$TREEHOUSE_ROOT" --all --include-unlanded --include-leased --yes >/dev/null 2>&1) || true
  "$REPO_BIN/fm-lab-home.sh" teardown "$lab" >/dev/null 2>&1 && rm -rf "$lab"
  rm -rf "$W"
  unset CASE_PATH_PREFIX
}

put() { printf "$INTENT_TMPL" "$2" "$3" > "$1/.claude/commit-intent.json"; }
c_expired()        { put "$1" fm/merged-elsewhere 2026-11-02T04:52:45+00:00; }
c_branch_unexpired(){ put "$1" fm/t1 2999-01-01T00:00:00+00:00; }
c_other_unexpired(){ put "$1" fm/t1-other 2999-01-01T00:00:00+00:00; }
c_no_tz()          { put "$1" fm/t1 2000-01-01T00:00:00; }
c_wrong_type()     { put "$1" fm/t1 2000-01-01T00:00:00+00:00; sed -i '' 's/"CommitIntent"/"CommitPlan"/' "$1/.claude/commit-intent.json"; }
c_empty_owned()    { put "$1" fm/t1 2000-01-01T00:00:00+00:00; sed -i '' 's/\["scripts[^]]*\]/[]/' "$1/.claude/commit-intent.json"; }
c_beside_other()   { c_expired "$1"; mkdir -p "$1/.claude/private"; printf 'secret\n' > "$1/.claude/private/x"; }
c_lookalike()      { put "$1" fm/t1 2000-01-01T00:00:00+00:00; mv "$1/.claude/commit-intent.json" "$1/.claude/commit-intent.json.bak"; }
c_old_python()     { c_expired "$1"; mkdir -p "$2/oldpy"; ln -s /usr/bin/python3 "$2/oldpy/python3"; }

case_names=(expired-intent-only:c_expired task-branch-unexpired:c_branch_unexpired other-branch-unexpired:c_other_unexpired
  expiry-without-timezone:c_no_tz wrong-artifacttype:c_wrong_type empty-owned_paths:c_empty_owned
  spent-intent-beside-claude-private-x:c_beside_other lookalike-commit-intent.json.bak:c_lookalike)
for pair in ${CASES:-${case_names[@]}}; do
  run_case "${pair%%:*}" "${pair#*:}"
done
if [ -z "${CASES:-}" ] && [ -x /usr/bin/python3 ]; then
  ver=$(/usr/bin/python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
  # Real older interpreter first on PATH (no stub): /usr/bin/python3.
  setup_old() { c_expired "$1"; }
  oldpy=$(mktemp -d "${TMPDIR:-/tmp}/fm-oldpy.XXXXXX"); ln -s /usr/bin/python3 "$oldpy/python3"
  CASE_PATH_PREFIX=$oldpy run_case "expired-intent-under-real-python-$ver" setup_old
  rm -rf "$oldpy"
fi
