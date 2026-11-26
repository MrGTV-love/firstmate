#!/usr/bin/env bash
# Live driver: runs the real bin/fm-review-record.py (new = run worktree, old = base 407c3837)
# against a disposable lab (own FM_HOME, NM_HOME, task worktree, fake HOME). No real fleet state.
set -u
WT=$1   # run worktree
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-carry-lab.XXXXXX")
trap 'chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
NEW=$WT/bin
OLD=$LAB/old/bin
mkdir -p "$LAB/old"; git -C "$WT" archive 407c3837 bin | tar -x -C "$LAB/old"
URL=https://github.com/example/repo/pull/9
NM="$LAB/nm"; mkdir -p "$NM"
python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$NM/state.sqlite"

g() { local c=$1; shift; git -C "$c/wt" -c user.name=Lab -c user.email=lab@example.invalid "$@"; }
mkcase() {  # <name>: worktree with branch pr (R) and trunk (moved base); prints dir
  local c="$LAB/$1"; mkdir -p "$c/home/state"
  git init -q -b main "$c/wt"; echo base > "$c/wt/README.md"; g "$c" add README.md; g "$c" commit -qm initial
  g "$c" checkout -q -b pr; printf 'one\ntwo\nthree\n' > "$c/wt/app.txt"; g "$c" add app.txt; g "$c" commit -qm 'ship change'
  g "$c" checkout -q -b trunk main; echo other > "$c/wt/other.txt"; g "$c" add other.txt; g "$c" commit -qm 'base moves'
  g "$c" checkout -q pr
  printf 'worktree=%s\nkind=ship\nmodel=gpt-5.1\nbranch=fm/fixture\nmode=direct-PR\n' "$c/wt" > "$c/home/state/task-x1.meta"
  echo "$c"
}
review() {  # <case> <head> <reader>
  printf 'VERDICT: PASS head=%s\nIndependent reader evidence.\n' "$2" > "$1/report.md"
  FM_HOME="$1/home" "$NEW/fm-review-record.py" review --pr "$URL" --head "$2" --verdict PASS --reader-model "$3" \
    --author-groups '{"ship":["gpt-5.1"]}' --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$1/report.md" >/dev/null || echo "!! record failed"
}
verify() {  # <bin> <case> <head> <base>; prints exit code + text output
  local rc=0 out err
  out=$(NM_HOME="$NM" FM_HOME="$2/home" "$1/fm-review-record.py" verify --pr "$URL" --head "$3" --task task-x1 --base "$4" 2>"$LAB/err") || rc=$?
  err=$(cat "$LAB/err")
  echo "    exit=$rc"; [ -z "$out" ] || printf '%s\n' "$out" | sed 's/^/    stdout| /'; [ -z "$err" ] || printf '%s\n' "$err" | sed 's/^/    stderr| /'
}
both() { echo "  OLD (407c3837):"; verify "$OLD" "$@"; echo "  NEW (bb94c642):"; verify "$NEW" "$@"; }

echo "=== S1 clean base merge carries; scratch made in state/, removed; shared TMPDIR untouched ==="
c=$(mkcase s1); R=$(g "$c" rev-parse pr); T=$(g "$c" rev-parse trunk); review "$c" "$R" sonnet
g "$c" merge -q --no-edit trunk; H=$(g "$c" rev-parse HEAD)
mkdir -p "$c/shim" "$c/shared-tmp"; REALGIT=$(command -v git)
cat > "$c/shim/git" <<SH
#!/usr/bin/env bash
[ "\$1" != init ] || printf '%s\n' "\${@: -1}" >> "$c/init.log"
exec $REALGIT "\$@"
SH
chmod +x "$c/shim/git"
echo "  R=$R  H=$H  T=$T"
echo "  OLD (407c3837):"; : > "$c/init.log"; PATH="$c/shim:$PATH" TMPDIR="$c/shared-tmp" verify "$OLD" "$c" "$H" "$T"; echo "    git init ran at: $(cat "$c/init.log")"
echo "  NEW (bb94c642):"; : > "$c/init.log"; PATH="$c/shim:$PATH" TMPDIR="$c/shared-tmp" verify "$NEW" "$c" "$H" "$T"; echo "    git init ran at: $(cat "$c/init.log")"
echo "    state/ dir listing after verify (hidden too):"; ls -A "$c/home/state" | sed 's/^/      /'
echo "    shared-tmp entries after verify: $(ls -A "$c/shared-tmp" | wc -l | tr -d ' ')"

echo "=== S2 unwritable state directory: typed refusal, no traceback ==="
c=$(mkcase s2); R=$(g "$c" rev-parse pr); T=$(g "$c" rev-parse trunk); review "$c" "$R" sonnet
g "$c" merge -q --no-edit trunk; H=$(g "$c" rev-parse HEAD)
chmod 500 "$c/home/state"; echo "  state mode: $(stat -f %Sp "$c/home/state")  uid=$(id -u)"
both "$c" "$H" "$T"
echo "  NEW --json:"; NM_HOME="$NM" FM_HOME="$c/home" "$NEW/fm-review-record.py" verify --pr "$URL" --head "$H" --task task-x1 --base "$T" --json 2>&1 | sed 's/^/    /'
chmod 700 "$c/home/state"

echo "=== S3 same-tree rewrite of R (amend message), not itself read, then base merge: carries from R ==="
c=$(mkcase s3); R=$(g "$c" rev-parse pr); T=$(g "$c" rev-parse trunk); review "$c" "$R" sonnet
g "$c" commit -q --amend -m 'ship change, reworded'; RW=$(g "$c" rev-parse HEAD)
g "$c" merge -q --no-edit trunk; H=$(g "$c" rev-parse HEAD); echo "  R=$R rewrite=$RW H=$H"
both "$c" "$H" "$T"

for order in rewrite-last original-last; do
echo "=== S4 ($order) same-tree rewrite that was itself read, then base merge: refuses ==="
c=$(mkcase "s4-$order"); R=$(g "$c" rev-parse pr); T=$(g "$c" rev-parse trunk); review "$c" "$R" sonnet
g "$c" commit -q --amend -m 'ship change, reworded'; RW=$(g "$c" rev-parse HEAD); review "$c" "$RW" sonnet
[ "$order" = rewrite-last ] || review "$c" "$R" gemini-3-pro
g "$c" merge -q --no-edit trunk; H=$(g "$c" rev-parse HEAD); echo "  R=$R rewrite=$RW H=$H"
both "$c" "$H" "$T"
done

for layout in home xdg; do
echo "=== S5 ($layout) merge driver + attributes in caller's global config hide a conflict: refuses ==="
c=$(mkcase "s5-$layout"); R=$(g "$c" rev-parse pr); review "$c" "$R" sonnet
g "$c" checkout -q trunk; echo 'base version' > "$c/wt/app.txt"; g "$c" add app.txt; g "$c" commit -qm 'base edits app.txt'; g "$c" checkout -q pr
T=$(g "$c" rev-parse trunk); F="$c/fake-home"; mkdir -p "$F/xdg/git"
if [ "$layout" = home ]; then echo 'app.txt merge=forge' > "$F/attrs"
  git config --file "$F/.gitconfig" merge.forge.driver "printf 'unread driver bytes\\n' > %A"; git config --file "$F/.gitconfig" core.attributesFile "$F/attrs"
else echo 'app.txt merge=forge' > "$F/xdg/git/attributes"; git config --file "$F/xdg/git/config" merge.forge.driver "printf 'unread driver bytes\\n' > %A"; fi
( unset GIT_CONFIG_GLOBAL; export HOME="$F" XDG_CONFIG_HOME="$F/xdg"; g "$c" merge -q --no-edit trunk ) || echo "!! fixture merge failed"
H=$(g "$c" rev-parse HEAD); echo "  live app.txt after driver-resolved merge: $(cat "$c/wt/app.txt")"
( unset GIT_CONFIG_GLOBAL; export HOME="$F" XDG_CONFIG_HOME="$F/xdg"; both "$c" "$H" "$T" )
done

echo "=== S6 accept/refuse unchanged: unread line hidden in base merge refuses, old and new ==="
c=$(mkcase s6); R=$(g "$c" rev-parse pr); T=$(g "$c" rev-parse trunk); review "$c" "$R" sonnet
g "$c" merge -q --no-commit --no-ff trunk >/dev/null 2>&1; echo unread >> "$c/wt/app.txt"; g "$c" add app.txt; g "$c" commit -qm "Merge branch 'trunk' into pr"
H=$(g "$c" rev-parse HEAD); both "$c" "$H" "$T"

echo "=== S7 accept/refuse unchanged: merge of a side branch not on the base refuses, old and new ==="
c=$(mkcase s7); R=$(g "$c" rev-parse pr); T=$(g "$c" rev-parse trunk); review "$c" "$R" sonnet
g "$c" checkout -q -b side main; echo side > "$c/wt/side.txt"; g "$c" add side.txt; g "$c" commit -qm side; g "$c" checkout -q pr
g "$c" merge -q --no-edit side; H=$(g "$c" rev-parse HEAD); both "$c" "$H" "$T"
echo "=== lab removed on exit: $LAB ==="
