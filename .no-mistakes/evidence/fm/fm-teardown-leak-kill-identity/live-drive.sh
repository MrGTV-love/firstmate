#!/usr/bin/env bash
# Live drive of bin/fm-teardown.sh against disposable, marked lab homes
# (bin/fm-lab-home.sh) with real git repos, real lsof, and real processes.
# No FM_*_OVERRIDE is set: the real script resolves every path from FM_HOME.
# treehouse/tmux/gh/no-mistakes are stubbed so nothing outside the lab is touched.
# Usage: live-drive.sh <worktree-root> <scenario>
set -u
WT_ROOT=$1
SCEN=$2
ID="labx-$SCEN-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 2; }
P="$LAB/projects"
FB="$LAB/fakebin"
mkdir -p "$FB"
for t in treehouse tmux gh no-mistakes; do printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/$t"; done
cat > "$FB/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
chmod +x "$FB"/*
g() { git -c user.email=t@t -c user.name=t "$@"; }
git init -q --bare "$P/origin.git"
git -C "$P/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$P/origin.git" "$P/seed" 2>/dev/null
g -C "$P/seed" commit -q --allow-empty -m base
git -C "$P/seed" push -q origin main
rm -rf "$P/seed"
git clone -q "$P/origin.git" "$P/project"
git -C "$P/project" remote set-head origin main 2>/dev/null || true
git -C "$P/project" worktree add -q -b "fm/$ID" "$P/wt" main
g -C "$P/wt" commit -q --allow-empty -m "shippable work"
git -C "$P/wt" push -q origin "fm/$ID"
git -C "$P/project" fetch -q origin
touch "$LAB/state/.last-watcher-beat"
. "$WT_ROOT/bin/fm-meta-lib.sh" 2>/dev/null || true
cat > "$LAB/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
endpoint_task_id=$ID
worktree=$P/wt
project=$P/project
kind=ship
mode=no-mistakes
spawn_gen=live-$ID
EOF
# An unrelated task record and process that must stay untouched.
mkdir -p "$P/unrelated"
printf 'worktree=%s\nkind=ship\n' "$P/unrelated" > "$LAB/state/unrelated.meta"
UNREL_BEFORE=$(shasum "$LAB/state/unrelated.meta")
(cd "$P/unrelated" && exec sleep 300) & UNREL=$!; disown
AUDIT="$LAB/state/$ID.teardown-processes"
TP="" ; FLAGS=()
start_ident() { LC_ALL=C ps -p "$1" -o lstart= | sed 's/^ *//; s/ *$//'; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo dead; }
NEST=""; EXTRA=""; EXTRA_LABEL=""
case "$SCEN" in
  own-audit)
    # Real leaked dev-server-like process that copies the audit file the moment TERM arrives.
    (cd "$P/wt" && exec perl -e '
      my ($a,$o,$r)=@ARGV;
      $SIG{TERM}=sub{ my $t = "NO AUDIT FILE AT TERM\n"; if (open(my $i,"<",$a)) { local $/; $t = <$i>; }
        open my $w,">",$o; print {$w} $t; close $w; };
      open my $f,">",$r; close $f; while(1){sleep 300}' "$AUDIT" "$LAB/term-observed" "$LAB/ready") & TP=$!; disown
    for _ in $(seq 50); do [ -e "$LAB/ready" ] && break; sleep 0.1; done ;;
  nested-project|nested-sibling|nested-nogit|nested-deleted)
    REG="$P/project"
    if [ "$SCEN" = nested-sibling ]; then REG="$P/sibling"; git clone -q "$P/origin.git" "$REG"; fi
    NEST="$P/wt/other-lane"
    git -C "$REG" worktree add -q --detach "$NEST" main
    git -C "$REG" worktree lock --reason "other task lane" "$NEST"
    (cd "$NEST" && exec sleep 300) & TP=$!; disown
    sleep 0.3
    [ "$SCEN" = nested-nogit ] && rm -f "$NEST/.git"
    [ "$SCEN" = nested-deleted ] && rm -rf "$NEST"
    FLAGS=(--force) ;;
  own-deleted-cwd)
    mkdir -p "$P/wt/dist"
    (cd "$P/wt/dist" && exec sleep 300) & TP=$!; disown
    sleep 0.3; rm -rf "$P/wt/dist" ;;
  no-lsof)
    mkdir -p "$LAB/nolsof"
    for c in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
      mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs shasum; do
      r=$(command -v "$c" 2>/dev/null) && ln -sf "$r" "$LAB/nolsof/$c"; done
    (cd "$P/wt" && exec sleep 300) & TP=$!; disown
    sleep 0.3; FLAGS=(--force) ;;
  audit-unwritable)
    mkdir "$AUDIT"
    (cd "$P/wt" && exec sleep 300) & TP=$!; disown
    sleep 0.3 ;;
  mixed-own-and-foreign)
    # An own leak in the task tree AND a foreign process inside another task's locked lane.
    NEST="$P/wt/other-lane"
    git -C "$P/project" worktree add -q --detach "$NEST" main
    git -C "$P/project" worktree lock --reason "other task lane" "$NEST"
    (cd "$NEST" && exec sleep 300) & TP=$!; disown
    (cd "$P/wt" && exec sleep 300) & EXTRA=$!; disown
    EXTRA_LABEL="own leak in task tree"
    sleep 0.3; FLAGS=(--force) ;;
  tasktmp-only)
    # Slot reassigned to another task: only the task's own tasktmp is reaped.
    git -C "$P/project" worktree remove --force "$P/wt"
    mkdir -p "$P/pool/1"
    git -C "$P/project" worktree add -q --detach "$P/pool/1/project" main
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$P/pool/1/project" > "$P/pool/treehouse-state.json"
    printf 'task=%s\nhome=%s\n' other-task "$P/other-home" > "$P/pool/1/.fm-slot-owner"
    sed -i '' "s#^worktree=.*#worktree=$P/pool/1/project#" "$LAB/state/$ID.meta"
    printf 'tasktmp=/tmp/fm-%s\n' "$ID" >> "$LAB/state/$ID.meta"
    mkdir -p "/tmp/fm-$ID"
    (cd "/tmp/fm-$ID" && exec sleep 300) & TP=$!; disown
    (cd "$P/pool/1/project" && exec sleep 300) & EXTRA=$!; disown
    EXTRA_LABEL="other task's worker in the reassigned slot"
    sleep 0.3; FLAGS=(--force) ;;
esac
echo "=== scenario: $SCEN   task id: $ID"
echo "lab home: $LAB (marked: $( [ -f "$LAB/.fm-lab-home" ] && echo yes || echo no))"
[ -n "$NEST" ] && echo "nested lane: $NEST" && git -C "$P/project" worktree list --porcelain | sed 's/^/  registry(project): /'
echo "target pid: $TP  start: $(start_ident "$TP")  cwd: $(lsof -a -p "$TP" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
echo "unrelated pid: $UNREL"
BASEPATH=$PATH; [ "$SCEN" = no-lsof ] && BASEPATH="$LAB/nolsof"
echo "--- running: FM_HOME=\$LAB bin/fm-teardown.sh $ID ${FLAGS[*]:-}"
rc=0
env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" PATH="$FB:$BASEPATH" \
  "$WT_ROOT/bin/fm-teardown.sh" "$ID" ${FLAGS[@]+"${FLAGS[@]}"} > "$LAB/out" 2> "$LAB/err" || rc=$?
echo "--- exit code: $rc"
echo "--- stderr (process-custody lines):"
grep -E "REFUSED|reaping leaked|force-killing|teardown:" "$LAB/err" | sed 's/^/  /'
echo "--- target pid $TP after teardown: $(alive "$TP")"
echo "--- unrelated pid $UNREL after teardown: $(alive "$UNREL")"
[ -n "$EXTRA" ] && echo "--- $EXTRA_LABEL pid $EXTRA after teardown: $(alive "$EXTRA")"
echo "--- unrelated record unchanged: $( [ "$(shasum "$LAB/state/unrelated.meta")" = "$UNREL_BEFORE" ] && echo yes || echo NO)"
echo "--- task record present: $( [ -e "$LAB/state/$ID.meta" ] && echo yes || echo no)"
echo "--- durable audit $ID.teardown-processes:"
if [ -f "$AUDIT" ]; then sed 's/^/  /' "$AUDIT"; else echo "  (absent$( [ -d "$AUDIT" ] && echo ': path is a directory'))"; fi
if [ -e "$LAB/term-observed" ]; then echo "--- audit content the process itself read at the instant TERM arrived:"; sed 's/^/  /' "$LAB/term-observed"; fi
kill -KILL "$TP" "$UNREL" $EXTRA 2>/dev/null || true
rm -rf "$LAB" "/tmp/fm-$ID"
echo "--- lab removed: $( [ -e "$LAB" ] && echo no || echo yes)"
