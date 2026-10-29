#!/usr/bin/env bash
# Live drive of the project-freeze change against disposable, marked lab homes.
# Real product: bin/fm-captain-hold.sh (hold/freeze/frozen/answer), tasks-axi,
# bin/fm-idle-session-reap.sh (scan and reap), bin/fm-teardown.sh admission.
# Seeded fixture state: task meta/status/busy-state/merge markers only.
# Usage: drive-freeze.sh <worktree> <base-bin-dir>
set -u
WT=$1
BASE_BIN=$2
cd "$WT" || exit 1
NOW=$(date +%s)
OLD=$((NOW - 7200))
PR=https://github.com/acme/widget/pull/41
OFFERS=$(mktemp "${TMPDIR:-/tmp}/fm-offers.XXXXXX")
WRAP=$(mktemp "${TMPDIR:-/tmp}/fm-td-wrap.XXXXXX")
# Logs each teardown offer, then runs the REAL bin/fm-teardown.sh.
cat > "$WRAP" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$OFFERS"
exec "$WT/bin/fm-teardown.sh" "\$@"
SH
chmod +x "$WRAP"

say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[rc=%s]\n' "$?"; }

mklab() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  bin/fm-lab-home.sh create "$d"
}

ROOTH=$(mklab); MATE=$(mklab); GRAND=$(mklab)
for h in "$ROOTH" "$MATE" "$GRAND"; do
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$h/.tasks.toml"
done
printf 'd7\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOTH" > "$MATE/.fm-secondmate-parent"
printf 'grand\n' > "$GRAND/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MATE" > "$GRAND/.fm-secondmate-parent"
echo "labs: root(Main)=$ROOTH mate(d7)=$MATE grand=$GRAND"

touch_old() { local s; s=$(TZ=UTC0 date -r "$OLD" +%Y%m%d%H%M.%S); TZ=UTC0 touch -t "$s" "$@"; }
mk_ship() {  # <home> <id> <project>
  local h=$1 id=$2 p=$3
  printf '%s\n' "window=w:$id" kind=ship harness=claude backend=tmux "pr=$PR" "project=$h/projects/$p" > "$h/state/$id.meta"
  printf 'done [at=%s]: PR %s checks green\n' "$OLD" "$PR" > "$h/state/$id.status"
  printf 'g1.1.1\n' > "$h/state/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$h/state/$id.busy-state"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n41\n' > "$h/state/$id.pr-poll-merge-notified"
  chmod 0600 "$h/state/$id.pr-poll-merge-notified"; touch_old "$h/state/$id.pr-poll-merge-notified"
}
hold() { FM_HOME=$1 bin/fm-captain-hold.sh "${@:2}"; }
scan() { FM_HOME=$1 bin/fm-idle-session-reap.sh scan; }
frozen() { FM_HOME=$1 bin/fm-captain-hold.sh frozen "$2"; }

# Main home: the 4 Vernant tasks from the incident plus same-prefix and no-project controls.
for id in vernant-b10-u4-register vernant-claude-guard-policy-probe-scope; do mk_ship "$ROOTH" "$id" vernant; done
mk_ship "$ROOTH" other-name-merged vernant
mk_ship "$ROOTH" vernant-sibling sample
# d7 mate: the other two incident tasks plus a control.
for id in vernant-graft-stop-coalesce vernant-provision-adopt-existing-branch; do mk_ship "$MATE" "$id" vernant; done
mk_ship "$MATE" sample-mate-merged sample
mk_ship "$GRAND" vernant-grand-merged vernant
printf 'Released by the captain.\n' > "$ROOTH/release.txt"

say "S0 no hold: everything is reap-ready (root, mate, grand)"
run scan "$ROOTH"; run scan "$MATE"; run scan "$GRAND"

say "S1 captain files the freeze hold in Main (no project declared yet)"
run hold "$ROOTH" hold vernant-freeze-20261023 --title "Vernant freeze" --reason "captain froze the Vernant lanes" --repo vernant
run frozen "$ROOTH" vernant-b10-u4-register
run scan "$ROOTH"

say "S2 captain declares the frozen project"
run hold "$ROOTH" freeze vernant-freeze-20261023 --project vernant
echo "--- hold record in Main backlog:"; (cd "$ROOTH" && tasks-axi show vernant-freeze-20261023 --full 2>&1 | sed -n '1,30p')
run frozen "$ROOTH" vernant-b10-u4-register
run frozen "$ROOTH" vernant-sibling
run scan "$ROOTH"

say "S2-base same Main home, same open freeze, BASE commit reaper (541b9ff6c)"
printf '$ FM_HOME=%s %s/fm-idle-session-reap.sh scan\n' "$ROOTH" "$BASE_BIN"
FM_HOME=$ROOTH "$BASE_BIN/fm-idle-session-reap.sh" scan; echo "[rc=$?]"

say "S3 real sweep in Main: frozen tasks never offered to teardown"
: > "$OFFERS"
printf '$ FM_HOME=%s FM_IDLE_REAP_TEARDOWN_BIN=<log+exec real fm-teardown.sh> bin/fm-idle-session-reap.sh reap\n' "$ROOTH"
FM_HOME=$ROOTH FM_IDLE_REAP_TEARDOWN_BIN=$WRAP bin/fm-idle-session-reap.sh reap; echo "[rc=$?]"
echo "--- teardown offers:"; cat "$OFFERS"
echo "--- state/idle-sessions.report:"; cat "$ROOTH/state/idle-sessions.report"
echo "--- refusal memos:"; ls "$ROOTH/state/.idle-reap" 2>&1
echo "--- frozen task records still present:"; ls "$ROOTH/state/" | grep -E '^(vernant-b10|vernant-claude|other-name).*\.meta$'

say "S4 automatic teardown admission refuses a frozen task (real fm-teardown.sh)"
printf '$ FM_HOME=%s FM_IDLE_REAP_ADMISSION=1 bin/fm-teardown.sh vernant-b10-u4-register\n' "$ROOTH"
FM_HOME=$ROOTH FM_IDLE_REAP_ADMISSION=1 bin/fm-teardown.sh vernant-b10-u4-register; echo "[rc=$?]"
ls "$ROOTH/state/vernant-b10-u4-register.meta"

say "S5 interrupted teardown record of a frozen task is not retried"
printf 'spawn_gen=\nslot=%s/pool/1/project\n' "$ROOTH" > "$ROOTH/state/vernant-claude-guard-policy-probe-scope.teardown-return-pending"
run scan "$ROOTH"
rm -f "$ROOTH/state/vernant-claude-guard-policy-probe-scope.teardown-return-pending"

say "S6 d7 mate and grandchild honor Main's freeze with no mirror hold"
run scan "$MATE"; run scan "$GRAND"
run frozen "$MATE" vernant-graft-stop-coalesce

say "S7 adversarial: broken links fail closed"
mv "$ROOTH/data" "$ROOTH/data.off"; echo "(Main data dir moved away)"
run scan "$MATE"
mv "$ROOTH/data.off" "$ROOTH/data"
mv "$MATE/.fm-secondmate-parent" "$MATE/.fm-secondmate-parent.off"; echo "(d7 binding removed, marker kept)"
run scan "$MATE"; run scan "$GRAND"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$GRAND" > "$MATE/.fm-secondmate-parent"; echo "(d7 binding loops to grand)"
run scan "$GRAND"
mv "$MATE/.fm-secondmate-parent.off" "$MATE/.fm-secondmate-parent"

say "S8 adversarial: a body that only quotes the freeze line below the header freezes nothing"
run hold "$ROOTH" hold quoted-note --title "note" --reason "note" --repo sample
(cd "$ROOTH" && b=$(mktemp) && tasks-axi show quoted-note --full | sed -n 's/^body: //p' >/dev/null; \
  printf 'Captain hold set: 2026-10-29T00:00:00Z\n\nNote: someone wrote\nCaptain hold freezes project: sample\n' > "$b" && tasks-axi update quoted-note --body-file "$b" >/dev/null && rm -f "$b")
run frozen "$ROOTH" vernant-sibling

say "S8b adversarial: re-holding with a new --origin keeps the freeze"
run hold "$ROOTH" hold vernant-freeze-20261023 --reason "captain froze the Vernant lanes" --origin reset-ask-20261023
run frozen "$ROOTH" vernant-b10-u4-register

say "S9 captain releases the freeze: tasks become eligible again everywhere"
run hold "$ROOTH" answer vernant-freeze-20261023 --decision-file "$ROOTH/release.txt" --release
run frozen "$ROOTH" vernant-b10-u4-register
run scan "$ROOTH"; run scan "$MATE"; run scan "$GRAND"

say "teardown of labs"
for h in "$ROOTH" "$MATE" "$GRAND"; do bin/fm-lab-home.sh teardown "$h" && rm -rf "$h"; done
rm -f "$OFFERS" "$WRAP"
echo done
