#!/usr/bin/env bash
# Live driver for `bin/fm-teardown.sh --copy <path>` against a disposable lab home.
# Usage: drive-by-path.sh <repo-worktree> <evidence-dir>
# Mints a lab home with bin/fm-lab-home.sh env, builds real git repos in it, runs the real
# teardown script as an operator would (plain FM_HOME, no fleet overrides), and tears the lab down.
# PATH shims are used only where a scenario needs the environment to misbehave (a refused ps, an
# unreadable registration list, a slow lsof, harm planted mid-run); the product itself is never faked.
set -u
REPO=$1
EV=$2
cd "$REPO" || exit 1
eval "$(bin/fm-lab-home.sh env 2>"$EV/lab-env.txt")"
LAB=$FM_HOME
TEARDOWN_LINE=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/lab-env.txt")
trap 'eval "$TEARDOWN_LINE"' EXIT
W=$LAB/work
mkdir -p "$W/bundles"
REAL_GIT=$(command -v git)
REAL_LSOF=$(command -v lsof)
REAL_PS=$(command -v ps)
G() { "$REAL_GIT" -c user.name=lab -c user.email=lab@lab.invalid "$@"; }

TRANSCRIPT=$EV/transcript.txt
: > "$TRANSCRIPT"
RESULTS=$EV/results.txt
: > "$RESULTS"
log() { printf '%s\n' "$*" >> "$TRANSCRIPT"; }
ok() { printf 'PASS %s\n' "$1" | tee -a "$RESULTS" >> "$TRANSCRIPT"; }
bad() { printf 'FAIL %s: %s\n' "$1" "$2" | tee -a "$RESULTS" >> "$TRANSCRIPT"; }
alive() { kill -0 "$1" 2>/dev/null; }
section() { log ""; log "=== $1 ==="; }
said() { grep -Fq -- "$1" "$W/err"; }
CLEAN_ENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE)

# The operator command: plain FM_HOME, fleet overrides removed.
td() {
  log "\$ FM_HOME=\$LAB bin/fm-teardown.sh $*"
  "${CLEAN_ENV[@]}" FM_HOME="$LAB" PATH="${TD_PATH:-$PATH}" bin/fm-teardown.sh "$@" > "$W/out" 2> "$W/err"
  RC=$?
  sed 's/^/  | /' "$W/out" "$W/err" >> "$TRANSCRIPT"
  log "  rc=$RC"
}
registered() { "$REAL_GIT" -C "$1" worktree list --porcelain | grep -Fqx "worktree $2"; }
hold_row() {  # <row-id> <reason>
  log "\$ FM_HOME=\$LAB bin/fm-captain-hold.sh hold $1 --owner captain --title $1 --repo project --boundary destructive --if-no ... --reason '$2'"
  "${CLEAN_ENV[@]}" FM_HOME="$LAB" bin/fm-captain-hold.sh hold "$1" --owner captain --title "$1" --repo project \
    --boundary destructive --if-no 'Keep the copy and bundle' --reason "$2" >> "$TRANSCRIPT" 2>&1
  log "  hold rc=$?"
}

"$REAL_GIT" init -q --bare -b main "$W/origin.git"
G clone -q "$W/origin.git" "$W/seed" 2>/dev/null
printf 'hello\n' > "$W/seed/README"
printf '.claude/\n.opencode/\n' > "$W/seed/.gitignore"
G -C "$W/seed" add . && G -C "$W/seed" commit -qm init && G -C "$W/seed" push -q origin main
G clone -q "$W/origin.git" "$LAB/projects/project"
P=$(cd "$LAB/projects/project" && pwd -P)
mkdir -p "$P/.claude/worktrees"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
log "lab home: $LAB"
log "project clone: $P (origin $W/origin.git, .claude/ and .opencode/ ignored)"

mkcopy() {  # <name> -> COPY, HEAD0
  COPY=$P/.claude/worktrees/$1
  G -C "$P" worktree add -q -b "fm/$1" "$COPY" main
  HEAD0=$(G -C "$COPY" rev-parse HEAD)
}
untouched() {  # <label>: present, registered, same HEAD, no audit line for it
  [ -d "$COPY" ] || { bad "$1" "copy removed"; return 1; }
  registered "$P" "$COPY" || { bad "$1" "copy unregistered"; return 1; }
  [ "$(G -C "$COPY" rev-parse HEAD)" = "$HEAD0" ] || { bad "$1" "HEAD moved"; return 1; }
  if [ -f "$LAB/data/record-less-copy-removals.log" ] && grep -Fq "	$COPY	" "$LAB/data/record-less-copy-removals.log"; then
    bad "$1" "audit line written for a refused run"; return 1
  fi
  return 0
}
commit_work() { printf 'work\n' > "$COPY/work.txt"; G -C "$COPY" add work.txt; G -C "$COPY" commit -qm 'unpublished work'; HEAD0=$(G -C "$COPY" rev-parse HEAD); }
record_bundle() {  # <record-id> <bundle> <rev...> -> BDIGEST, BTIPS
  local id=$1 b=$2; shift 2
  mkdir -p "$LAB/data/$id"
  G -C "$COPY" bundle create "$b" "$@" 2>/dev/null
  BDIGEST=$(shasum -a 256 "$b" | awk '{print $1}')
  BTIPS=$(G bundle list-heads "$b" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
  printf '%s\t%s\t%s\n' "$b" "$BDIGEST" "$BTIPS" > "$LAB/data/$id/preservation-bundles.tsv"
  log "bundle record data/$id/preservation-bundles.tsv: $(cat "$LAB/data/$id/preservation-bundles.tsv")"
}
printed_hold() { sed -n 's/^File the land-or-drop call as its row, then run the same teardown --copy command again: //p' "$W/err"; }

# ---------------------------------------------------------------------------
section "S00 base commit c89e6a5: --copy does not exist, and teardown by id refuses the record-less copy; head removes it"
mkdir -p "$W/base-src"
"$REAL_GIT" -C "$REPO" archive c89e6a5977f60f3aca41c983c5410dabd3cf14f2 | tar -x -C "$W/base-src"
mkcopy basered
for args in "--copy $COPY" "copy-basered"; do
  log "\$ FM_HOME=\$LAB <base c89e6a5>/bin/fm-teardown.sh $args"
  # shellcheck disable=SC2086
  "${CLEAN_ENV[@]}" FM_HOME="$LAB" "$W/base-src/bin/fm-teardown.sh" $args > "$W/out" 2> "$W/err"; RC=$?
  sed 's/^/  | /' "$W/err" >> "$TRANSCRIPT"; log "  rc=$RC"
  case "$args" in
    --copy*) if [ "$RC" = 2 ] && said 'invalid teardown request' && untouched S00a; then ok S00a-base-has-no-copy-mode; else bad S00a "rc=$RC"; fi ;;
    *) if [ "$RC" != 0 ] && said 'task record is not a regular file' && untouched S00b; then ok S00b-base-by-id-refuses-record-less; else bad S00b "rc=$RC"; fi ;;
  esac
done
td --copy "$COPY"
if [ "$RC" = 0 ] && [ ! -e "$COPY" ]; then ok S00c-head-removes-the-same-copy; else bad S00c "rc=$RC"; fi

section "S01 landed record-less copy is removed: one non-forced removal, one audit line, clone untouched"
mkcopy landed
td --copy "$COPY"
if [ "$RC" = 0 ] && [ ! -e "$COPY" ] && ! registered "$P" "$COPY" && [ -d "$P/.git" ] && [ "$(G -C "$P" rev-parse main)" = "$HEAD0" ] \
  && said 'removed record-less copy' && [ "$(grep -Fc "	$COPY	$HEAD0	landed" "$LAB/data/record-less-copy-removals.log")" = 1 ]; then ok S01; else bad S01 "rc=$RC"; fi
log "audit log:"; sed 's/^/  | /' "$LAB/data/record-less-copy-removals.log" >> "$TRANSCRIPT"

section "S02 rerun on the removed copy exits 0 and names its audit line; a never-existing path refuses"
td --copy "$COPY"
if [ "$RC" = 0 ] && said 'already gone, and this run removed nothing' && said "for HEAD $HEAD0"; then ok S02a; else bad S02a "rc=$RC"; fi
td --copy "$P/.claude/worktrees/never-existed"
if [ "$RC" = 1 ] && said 'no audit record'; then ok S02b-never-existed-refuses; else bad S02b "rc=$RC"; fi

section "S03 ordinary teardown by task id is unchanged for a missing record"
td copy-nope
if [ "$RC" != 0 ] && said 'task record is not a regular file'; then ok S03; else bad S03 "rc=$RC"; fi

section "S04 unlanded commit with no bundle refuses"
mkcopy unlanded; commit_work
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S04 && said 'is not removed'; then ok S04; else bad S04 "rc=$RC"; fi

section "S05 bundle-held copy with two recorded tips: no call refuses and prints the hold; a call naming one tip refuses; the printed hold lets it go"
mkcopy bundled; commit_work
G -C "$COPY" update-ref refs/heads/fm/second "$(G -C "$COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'second unpublished tip')"
B=$W/bundles/work.bundle
record_bundle rec-1 "$B" fm/bundled fm/second
digest=$BDIGEST; tips=$BTIPS
td --copy "$COPY" --record-id rec-1
cmd=$(printed_hold)
if [ "$RC" = 1 ] && untouched S05a && said 'bundle preservation unavailable' && [ -n "$cmd" ]; then ok S05a-no-call-refuses-and-prints-hold; else bad S05a "rc=$RC"; fi
hold_row partial-call "Land or drop work: preserved in bundle $B, recorded tip ${tips%% *}."
td --copy "$COPY" --record-id rec-1
if [ "$RC" = 1 ] && untouched S05b && said 'bundle preservation unavailable'; then ok S05b-call-naming-one-of-two-tips-refuses; else bad S05b "rc=$RC"; fi
cmd=$(printed_hold)
log "\$ (printed) $cmd"
( "${CLEAN_ENV[@]}" FM_HOME="$LAB" bash -c "$cmd" ) >> "$TRANSCRIPT" 2>&1
log "  hold rc=$?"
td --copy "$COPY" --record-id rec-1
stored=$LAB/data/rec-1/preserved-bundles/$digest.bundle
if [ "$RC" = 0 ] && [ ! -e "$COPY" ] && ! registered "$P" "$COPY" && [ -f "$stored" ] && said "land-or-drop call for bundle $B is held on task rec-1" \
  && G -C "$P" fetch -q "$stored" "$HEAD0:refs/heads/recovered" && [ "$(G -C "$P" rev-parse recovered)" = "$HEAD0" ] \
  && grep -Fq "	$COPY	$HEAD0	bundle $stored" "$LAB/data/record-less-copy-removals.log"; then
  ok S05c-printed-hold-filed-copy-removed-bundle-stored-and-restores
else bad S05c "rc=$RC"; fi
log "stored bundle restores HEAD $HEAD0 into the clone as refs/heads/recovered: $(G -C "$P" rev-parse recovered 2>&1)"

section "S05d a commit made after the bundle, with the call filed, refuses"
mkcopy bundlelate; commit_work
record_bundle rec-3 "$W/bundles/late.bundle" fm/bundlelate
hold_row rec-3 "Land or drop the unlanded commits of rec-3: preserved in bundle $W/bundles/late.bundle, recorded tips $BTIPS."
printf 'more\n' > "$COPY/more.txt"; G -C "$COPY" add more.txt; G -C "$COPY" commit -qm 'after the bundle'; HEAD0=$(G -C "$COPY" rev-parse HEAD)
td --copy "$COPY" --record-id rec-3
if [ "$RC" = 1 ] && untouched S05d && said 'bundle does not list unlanded tip'; then ok S05d; else bad S05d "rc=$RC"; fi

section "S06 a recorded bundle whose bytes changed after it was recorded refuses, call filed"
mkcopy badbundle; commit_work
record_bundle rec-2 "$W/bundles/bad.bundle" fm/badbundle
hold_row rec-2 "Land or drop the unlanded commits of rec-2: preserved in bundle $W/bundles/bad.bundle, recorded tips $BTIPS."
printf 'x' >> "$W/bundles/bad.bundle"
td --copy "$COPY" --record-id rec-2
if [ "$RC" = 1 ] && untouched S06 && said 'sha256 does not match record'; then ok S06; else bad S06 "rc=$RC"; fi

section "S07 dirty tree (tracked edit, then untracked file) refuses"
mkcopy dirty
printf 'edit\n' >> "$COPY/README"
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S07a && grep -q edit "$COPY/README"; then ok S07a-tracked-edit; else bad S07a "rc=$RC"; fi
G -C "$COPY" checkout -q README
printf 'new\n' > "$COPY/untracked.txt"
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S07b && [ -f "$COPY/untracked.txt" ]; then ok S07b-untracked; else bad S07b "rc=$RC"; fi

section "S08 a process with cwd in the copy, then one holding a file open, refuses and is not signalled; idle copy then goes"
mkcopy held
( cd "$COPY" && exec sleep 300 ) & hpid=$!
sleep 1
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S08a && said "$hpid" && alive "$hpid"; then ok S08a-cwd; else bad S08a "rc=$RC"; fi
kill "$hpid"; wait "$hpid" 2>/dev/null
( cd / && exec 3< "$COPY/README" && exec sleep 300 ) & hpid=$!
for _ in $(seq 1 50); do "$REAL_LSOF" -nP -w -p "$hpid" -Fn 2>/dev/null | grep -Fq "n$COPY/README" && break; sleep 0.1; done
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S08b && said "$hpid" && alive "$hpid"; then ok S08b-open-file; else bad S08b "rc=$RC"; fi
kill "$hpid"; wait "$hpid" 2>/dev/null
td --copy "$COPY"
if [ "$RC" = 0 ] && [ ! -e "$COPY" ]; then ok S08c-idle-copy-goes; else bad S08c "rc=$RC"; fi

section "S09 --force, --drop-file, --legacy-record, relative path, link refuse"
mkcopy force; commit_work
printf 'words\n' > "$W/words.txt"
for f in --force --legacy-record "--drop-file $W/words.txt"; do
  # shellcheck disable=SC2086
  td --copy "$COPY" $f
  if [ "$RC" = 2 ] && said "takes no ${f%% *}" && untouched "S09${f%% *}"; then ok "S09${f%% *}"; else bad "S09${f%% *}" "rc=$RC"; fi
done
td --copy relative/path
if [ "$RC" != 0 ] && untouched S09-relative; then ok S09-relative; else bad S09-relative "rc=$RC"; fi
ln -s "$COPY" "$W/link-to-copy"
td --copy "$W/link-to-copy"
if [ "$RC" != 0 ] && untouched S09-link; then ok S09-link; else bad S09-link "rc=$RC"; fi

section "S10 a live task record that names the copy refuses; a record id that is a live task refuses"
mkcopy recorded
printf '%s\n' "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$COPY" "project=$P" \
  "kind=ship" "mode=no-mistakes" "spawn_gen=lab" > "$LAB/state/task-x1.meta"
td --copy "$COPY"
if [ "$RC" = 1 ] && said 'rule=active-record-owner' && said "task task-x1's active record names it as its worktree" && untouched S10a; then ok S10a; else bad S10a "rc=$RC"; fi
td --copy "$COPY" --record-id task-x1
if [ "$RC" = 2 ] && said 'names a live task record' && untouched S10b; then ok S10b-record-id-is-live-task; else bad S10b "rc=$RC"; fi
rm -f "$LAB/state/task-x1.meta"

section "S11 the clone itself and an unregistered directory refuse"
td --copy "$P"
if [ "$RC" = 1 ] && [ -d "$P/.git" ]; then ok S11a-clone; else bad S11a "rc=$RC"; fi
mkdir -p "$P/.claude/worktrees/plain-dir"; printf 'x\n' > "$P/.claude/worktrees/plain-dir/f"
td --copy "$P/.claude/worktrees/plain-dir"
if [ "$RC" = 1 ] && [ -f "$P/.claude/worktrees/plain-dir/f" ]; then ok S11b-unregistered; else bad S11b "rc=$RC"; fi

section "S12 other Git repositories in the copy: nested clone, bare repo with an unpushed commit, tracked bare fixture"
mkcopy nestclone
G clone -q "$W/origin.git" "$COPY/.claude/inner-clone"
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S12a && said "$COPY/.claude/inner-clone" && [ -d "$COPY/.claude/inner-clone/.git" ]; then ok S12a-nested-clone; else bad S12a "rc=$RC"; fi
rm -rf "$COPY/.claude/inner-clone"
G clone -q --bare "$W/origin.git" "$COPY/.claude/backup.git"
c=$(G --git-dir="$COPY/.claude/backup.git" commit-tree 'HEAD^{tree}' -p HEAD -m 'only the bare repo has this')
G --git-dir="$COPY/.claude/backup.git" update-ref refs/heads/unlanded "$c"
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S12b && said "$COPY/.claude/backup.git" && G --git-dir="$COPY/.claude/backup.git" cat-file -e "$c"; then ok S12b-bare-unpushed; else bad S12b "rc=$RC"; fi
mkcopy barefixture
G clone -q --bare "$W/origin.git" "$COPY/.claude/fixtures/repo.git"
G -C "$COPY" add -f .claude/fixtures/repo.git && G -C "$COPY" commit -qm 'track a bare fixture' && G -C "$COPY" push -q origin HEAD:main
HEAD0=$(G -C "$COPY" rev-parse HEAD)
printf 'changed\n' >> "$COPY/.claude/fixtures/repo.git/description"
td --copy "$COPY"
if [ "$RC" = 1 ] && untouched S12c; then ok S12c-tracked-bare-modified-refuses; else bad S12c "rc=$RC"; fi
G -C "$COPY" checkout -q -- .claude/fixtures/repo.git/description
td --copy "$COPY"
if [ "$RC" = 0 ] && [ ! -e "$COPY" ]; then ok S12d-tracked-clean-bare-is-landed-content; else bad S12d "rc=$RC"; fi

section "S13 ignored .claude and .opencode files are preserved whole, then the copy goes"
mkcopy claude
mkdir -p "$COPY/.claude/sub" "$COPY/.opencode"
printf 'unique settings\n' > "$COPY/.claude/settings.local.json"
printf 'unique note\n' > "$COPY/.claude/sub/note.txt"
printf 'unique opencode\n' > "$COPY/.opencode/state.json"
td --copy "$COPY" --record-id pres-1
kept=$(find "$LAB/data/pres-1/nested-copy-preserved" -type d -name files -print -quit 2>/dev/null)
if [ "$RC" = 0 ] && [ ! -e "$COPY" ] && [ "$(cat "$kept/.claude/settings.local.json")" = 'unique settings' ] \
  && [ "$(cat "$kept/.claude/sub/note.txt")" = 'unique note' ] && [ "$(cat "$kept/.opencode/state.json")" = 'unique opencode' ]; then
  ok S13a
else bad S13a "rc=$RC kept=$kept"; fi
log "preserved files:"; (cd "$LAB/data/pres-1" && find . -type f | sort | sed 's/^/  | /') >> "$TRANSCRIPT"
section "S13b a preserve that cannot publish keeps the copy; with the blocker gone the rerun removes it"
mkcopy claude2
mkdir -p "$COPY/.claude"; printf 'unique\n' > "$COPY/.claude/settings.local.json"
mkdir -p "$LAB/data/pres-2"; printf 'blocker\n' > "$LAB/data/pres-2/nested-copy-preserved"
td --copy "$COPY" --record-id pres-2
if [ "$RC" = 1 ] && [ -d "$COPY" ] && registered "$P" "$COPY" && [ "$(G -C "$COPY" rev-parse HEAD)" = "$HEAD0" ] \
  && said 'could not be preserved' && [ -f "$COPY/.claude/settings.local.json" ]; then ok S13b-preserve-cannot-publish-keeps-copy; else bad S13b "rc=$RC"; fi
log "audit lines for this copy after the refused run (the header writes the line after the proofs, before the removal):"
grep -F "	$COPY	" "$LAB/data/record-less-copy-removals.log" | sed 's/^/  | /' >> "$TRANSCRIPT"
rm -f "$LAB/data/pres-2/nested-copy-preserved"
td --copy "$COPY" --record-id pres-2
if [ "$RC" = 0 ] && [ ! -e "$COPY" ] && [ "$(grep -Fc "	$COPY	$HEAD0	" "$LAB/data/record-less-copy-removals.log")" = 1 ]; then ok S13c-rerun-goes-with-one-audit-line; else bad S13c "rc=$RC"; fi

section "S14 Vernant-locked copy whose launcher is really gone: ps refused (126) or failed (3) still keeps the copy"
for mode in 126 3; do
  mkcopy "vlock$mode"
  sleep 0 & lpid=$!; wait "$lpid" 2>/dev/null
  if alive "$lpid"; then bad "S14-$mode" "pid reused"; continue; fi
  G -C "$P" worktree lock --reason "vernant-session-active owner=launcher:$lpid launcher=$lpid" "$COPY"
  mkdir -p "$W/fake-ps-$mode"
  cat > "$W/fake-ps-$mode/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = "-p $lpid -o pid=" ]; then echo 'ps: Operation not permitted' >&2; exit $mode; fi
exec "$REAL_PS" "\$@"
SH
  chmod +x "$W/fake-ps-$mode/ps"
  TD_PATH="$W/fake-ps-$mode:$PATH" td --copy "$COPY"
  if [ "$RC" = 1 ] && said 'rule=lock-launcher-owner' \
    && said "ps could not show that it is gone, so the copy is kept: run this teardown again where ps can answer for pid $lpid; end that process only after you confirm pid $lpid is the launcher named by the lock (a pid can be reused)" \
    && untouched "S14-$mode" && G -C "$P" worktree list --porcelain | grep -A4 -F "worktree $COPY" | grep -q '^locked'; then
    ok "S14-dead-launcher-ps-exit-$mode-kept"
  else bad "S14-$mode" "rc=$RC"; fi
done

section "S15 a clone whose registration list git cannot read refuses"
mkcopy unreadable
mkdir -p "$W/fake-git"
cat > "$W/fake-git/git" <<SH
#!/usr/bin/env bash
case " \$* " in *" worktree list "*) echo 'fatal: cannot read worktrees' >&2; exit 128 ;; esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/fake-git/git"
TD_PATH="$W/fake-git:$PATH" td --copy "$COPY"
if [ "$RC" = 1 ] && said 'could not be read' && untouched S15; then ok S15; else bad S15 "rc=$RC"; fi

section "S16 two runs at once on one copy: one proceeds, the other refuses on the path lock"
mkcopy twice
mkdir -p "$W/slow-lsof"
cat > "$W/slow-lsof/lsof" <<SH
#!/usr/bin/env bash
sleep 3
exec "$REAL_LSOF" "\$@"
SH
chmod +x "$W/slow-lsof/lsof"
( "${CLEAN_ENV[@]}" FM_HOME="$LAB" PATH="$W/slow-lsof:$PATH" bin/fm-teardown.sh --copy "$COPY" > "$W/a.out" 2> "$W/a.err"; echo $? > "$W/a.rc" ) &
apid=$!
sleep 1.5
td --copy "$COPY"
brc=$RC
wait "$apid"
log "first (slowed) run rc=$(cat "$W/a.rc"):"; sed 's/^/  | /' "$W/a.err" >> "$TRANSCRIPT"
if [ "$brc" = 1 ] && said 'another teardown --copy run holds' && [ "$(cat "$W/a.rc")" = 0 ] && [ ! -e "$COPY" ] \
  && [ "$(grep -Fc "	$COPY	" "$LAB/data/record-less-copy-removals.log")" = 1 ]; then ok S16; else bad S16 "a=$(cat "$W/a.rc") b=$brc"; fi

section "S17 copy inside a Treehouse pool slot: live claim refuses (own record id too), unreadable claim refuses, stale claim passes"
mkdir -p "$W/pool/1"
G -C "$P" worktree add -q --detach "$W/pool/1/project" main
SLOT=$(cd "$W/pool/1/project" && pwd -P)
printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$SLOT" > "$W/pool/treehouse-state.json"
COPY=$SLOT/.claude/worktrees/slotcopy
mkdir -p "${COPY%/*}"
G -C "$P" worktree add -q -b fm/slotcopy "$COPY" main
HEAD0=$(G -C "$COPY" rev-parse HEAD)
printf 'task=other-task\nhome=%s\n' "$LAB" > "$W/pool/1/.fm-slot-owner"
printf '%s\n' "window=firstmate:fm-other-task" "kind=ship" "spawn_gen=lab" > "$LAB/state/other-task.meta"
td --copy "$COPY"
if [ "$RC" = 1 ] && said 'is claimed by task other-task, whose record is live' && untouched S17a; then ok S17a-live-claim-refuses; else bad S17a "rc=$RC"; fi
td --copy "$COPY" --record-id other-task
if [ "$RC" != 0 ] && untouched S17b; then ok S17b-claim-naming-the-runs-own-record-id-refuses; else bad S17b "rc=$RC"; fi
rm -f "$LAB/state/other-task.meta"
printf 'garbage with no task line\n' > "$W/pool/1/.fm-slot-owner"
td --copy "$COPY"
if [ "$RC" = 1 ] && said 'cannot be read, so who the slot belongs to is unknown' && untouched S17c; then ok S17c-unreadable-claim-refuses; else bad S17c "rc=$RC"; fi
printf 'task=gone-task\nhome=%s\n' "$LAB" > "$W/pool/1/.fm-slot-owner"
td --copy "$COPY"
if [ "$RC" = 0 ] && [ ! -e "$COPY" ] && [ -f "$W/pool/1/.fm-slot-owner" ] && [ -e "$SLOT/.git" ]; then ok S17d-stale-claim-passes-slot-untouched; else bad S17d "rc=$RC"; fi

section "S18 a nested clone planted at the bundle-verify step is refused by the by-path exception, whose row is the final REFUSED line"
mkcopy exc; commit_work
record_bundle rec-4 "$W/bundles/exc.bundle" fm/exc
hold_row rec-4 "Land or drop the unlanded commits of rec-4: preserved in bundle $W/bundles/exc.bundle, recorded tips $BTIPS."
mkdir -p "$W/plant-git"
cat > "$W/plant-git/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" bundle verify "*)
    if [ ! -e "$W/planted" ]; then : > "$W/planted"; "$REAL_GIT" clone -q "$W/origin.git" "$COPY/.claude/planted"; fi ;;
esac
exec "$REAL_GIT" "\$@"
SH
chmod +x "$W/plant-git/git"
TD_PATH="$W/plant-git:$PATH" td --copy "$COPY" --record-id rec-4
last=$(grep '^REFUSED:' "$W/err" | tail -n 1)
log "final REFUSED line: $last"
if [ "$RC" = 1 ] && [ -d "$COPY/.claude/planted/.git" ] && untouched S18 && printf '%s' "$last" | grep -Fq 'no clone registers' \
  && ! printf '%s' "$last" | grep -Fq 'is not proved landed'; then ok S18; else bad S18 "rc=$RC"; fi

section "SUMMARY"
cat "$RESULTS" >> "$TRANSCRIPT"
log "lab torn down by: $TEARDOWN_LINE"
