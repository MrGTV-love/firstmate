#!/usr/bin/env bash
# r3-drive.sh <scenario>: run one rerecord-slot scenario against the real bin/fm-control.sh in the lab; print a transcript.
# Needs FM_HOME and TMUX_TMPDIR exported (from bin/fm-lab-home.sh env). Faults are injected only through the
# environment (a PATH-front mktemp wrapper in the lab); the product scripts are run unmodified from the gate worktree.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M89W4CZM5PXRFWG112YQ3V2Q
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M89W4CZM5PXRFWG112YQ3V2Q
. "$FM_HOME/projects/ids.env"
cd "$W"
C=bin/fm-control.sh
META=$FM_HOME/state/rrt.meta
AD=$FM_HOME/data/rrt/slot-rerecord
FB=$FM_HOME/fakebin
NOTE="Lab ruling: re-record after the slot renewal"
g() { git -C "$1" -c user.name=Lab -c user.email=lab@example.invalid "${@:2}"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }
msha() { sha "$MAN"; }
run() { echo "\$ fm-control.sh $*"; "$C" "$@" 2>&1 | grep -v '^fm-gate-refuse:'; echo "rc=${PIPESTATUS[0]}"; }
frun() { echo "\$ [PATH fault: $FAULT] fm-control.sh $*"; PATH="$FB:$PATH" FM_LAB_FAULT=$FAULT FM_LAB_FAULT_DIR=$FM_HOME "$C" "$@" 2>&1 | grep -v '^fm-gate-refuse:'; echo "rc=${PIPESTATUS[0]}"; }
audits() { ls "$AD"/*.record 2>/dev/null; }
latest_audit() { ls -t "$AD"/*.record 2>/dev/null | head -1; }
results() { for a in $(audits); do echo "  $(basename "$a"): $(grep ^result= "$a")"; done; }
crash() { local a; a=$(latest_audit); sed -i '' 's/^result=published$/result=pending/' "$a"; echo "# simulated SIGKILL after publish: $(basename "$a") result=$(grep ^result= "$a" | cut -d= -f2)"; }
move_head() { printf 'moved %s\n' "$RANDOM" >> "$WT/src/owned.txt"; g "$WT" commit -qam "move HEAD inside scope"; echo "# copy HEAD moved inside scope to $(g "$WT" rev-parse --short HEAD)"; }
# Guard: never let tmux fall back to the default socket when the lab's private socket dir has gone.
tmux() { case "${TMUX_TMPDIR:-}" in /tmp/fml.*) ;; *) echo "GUARD: TMUX_TMPDIR '${TMUX_TMPDIR:-}' is not a lab dir" >&2; return 99 ;; esac
  [ -d "$TMUX_TMPDIR" ] || { echo "GUARD: lab tmux dir $TMUX_TMPDIR is missing; refusing tmux $*" >&2; return 99; }
  command tmux "$@"; }
count() { printf '%s\n' "$1" | grep -c "$2"; }
make_fakebin() {
  mkdir -p "$FB"; real=$(command -v mktemp)
  cat > "$FB/mktemp" <<SH
#!/usr/bin/env bash
# lab fault wrapper: FM_LAB_FAULT=commit+restore fails the 2nd .audit. stage (the audit commit) and every restore stage;
# FM_LAB_FAULT=restore fails every restore stage; FM_LAB_FAULT=slow-archive sleeps 4s on the 1st .audit. stage.
n=\$(cat "\$FM_LAB_FAULT_DIR/.mk-audit" 2>/dev/null || echo 0)
case "\$*" in
  *.meta.rerecord-restore.*) case "\$FM_LAB_FAULT" in *restore*) echo "lab-fault: mktemp \$*" >&2; exit 1 ;; esac ;;
  *.audit.*) n=\$((n + 1)); echo \$n > "\$FM_LAB_FAULT_DIR/.mk-audit"
    case "\$FM_LAB_FAULT" in commit*) [ "\$n" -lt 2 ] || { echo "lab-fault: mktemp \$*" >&2; exit 1; } ;; slow-archive) [ "\$n" != 1 ] || sleep 4 ;; esac ;;
esac
exec $real "\$@"
SH
  chmod +x "$FB/mktemp"; rm -f "$FM_HOME/.mk-audit"
}
agent_up() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  tmux new-session -d -s fmlab -n fm-rrt -c "$WT" -e FM_HOME="$FM_HOME" /Users/charlesabrooker/.local/bin/claude; sleep 5
  echo "# lab tmux (private TMUX_TMPDIR=$TMUX_TMPDIR) panes:"; tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} pid=#{pane_pid}'; }
agent_down() { tmux kill-server 2>/dev/null; echo "# lab tmux server stopped: $(tmux list-panes -a 2>&1 | head -1)"; }
case "$1" in
  S1) echo "# S1: relaunch before rerecord, after the project renewed the slot (base M1, scope src+lib+tools/x.sh)"
      bash "$EV/lab-renew.sh" src lib tools/x.sh; grep ^slot_ "$META"
      run rrt relaunch --note "resume after slot renewal"; grep ^slot_ "$META" ;;
  S2) echo "# S2: --check reports the write and writes nothing"; b=$(sha "$META"); ls -la "$FM_HOME/data/rrt" | wc -l
      run rrt rerecord-slot --check; echo "record sha before=$b after=$(sha "$META")"; echo "audit dir: $(ls "$AD" 2>&1)" ;;
  S3) echo "# S3: write with a wrong --manifest-sha"; b=$(sha "$META")
      run rrt rerecord-slot --manifest-sha 0000000000000000000000000000000000000000000000000000000000000000 --note "$NOTE"
      [ "$(sha "$META")" = "$b" ] && echo "record unchanged"; echo "audit dir: $(ls "$AD" 2>&1)" ;;
  S3b) echo "# S3b: write with no --note"; b=$(sha "$META"); run rrt rerecord-slot --manifest-sha "$(msha)"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged" ;;
  S4) echo "# S4: real claude agent running in the task window -> refused"; agent_up; b=$(sha "$META")
      run rrt rerecord-slot --check
      run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged"; agent_down ;;
  S5) echo "# S5: renewal whose base is not merge-base origin/main HEAD (M0 kept) -> refused"; bash "$EV/lab-renew.sh" --base-sha "$M0" src lib tools/x.sh
      b=$(sha "$META"); run rrt rerecord-slot --check; run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged" ;;
  S6) echo "# S6: renewal with a scope entry outside recorded scope and changed paths (docs.txt) -> refused"; bash "$EV/lab-renew.sh" src lib tools/x.sh docs.txt
      b=$(sha "$META"); run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged" ;;
  S6b) echo "# S6b: renewal that does not cover a changed path (tools missing) -> refused"; bash "$EV/lab-renew.sh" src lib
      b=$(sha "$META"); run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged" ;;
  S6c) echo "# S6c: renewal owned by another task -> refused"; bash "$EV/lab-renew.sh" --owner-id other-task src lib tools
      b=$(sha "$META"); run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; [ "$(sha "$META")" = "$b" ] && echo "record unchanged" ;;
  S7) echo "# S7: good renewal; write publishes, second write is a no-op"; bash "$EV/lab-renew.sh" src lib tools/x.sh; b=$(sha "$META")
      run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; echo "record sha $b -> $(sha "$META")"; grep ^slot_ "$META"; results
      a=$(latest_audit); arch=$(grep ^archive= "$a" | cut -d= -f2-); echo "archive: $(basename "$arch")"
      run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; echo "audit count: $(audits | wc -l | tr -d ' ')"
      run rrt rerecord-slot --check ;;
  S8) echo "# S8: own publish, then the audit commit fails, then the restore cannot stage (fault: commit+restore)"
      make_fakebin; FAULT=commit+restore
      cp "$META" "$FM_HOME/prior.meta"; a0=$(audits | wc -l)
      # make the record need a write again: put the prior record (pre-S7) back from S7's archive
      arch=$(grep ^archive= "$(latest_audit)" | cut -d= -f2-); cp "$arch" "$META"; echo "# record reset to the S7 archive (prior slot lines):"; grep ^slot_ "$META"
      out=$(frun rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"); printf '%s\n' "$out"
      a=$(latest_audit); echo "new audit $(basename "$a"): $(grep ^result= "$a")"
      [ "$(sha "$META")" = "$(grep ^staged_sha256= "$a" | cut -d= -f2)" ] && echo "record holds this run's staged bytes (publish landed, restore failed)"
      echo "count 'could not be restored'=$(count "$out" 'could not be restored')  'this run stopped'=$(count "$out" 'this run stopped')  'reconciled earlier interrupted runs'=$(count "$out" 'reconciled earlier interrupted runs')"
      echo "# next write run without the fault reconciles it:"; run rrt rerecord-slot --check; run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; results ;;
  S9) echo "# S9: step 3 closes a first audit (superseded-other), then the resumed restore of a crashed write fails (fault: restore)"
      make_fakebin; FAULT=restore
      arch=$(grep ^archive= "$(latest_audit)" | cut -d= -f2-); cp "$arch" "$META"
      run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE" >/dev/null; crash; move_head
      printf 'result=pending\nprior_sha256=%064d\nstaged_sha256=%064d\nprior_block_sha256=x\nstaged_block_sha256=y\n' 0 1 > "$AD/0-first.record"; chmod 600 "$AD/0-first.record"
      echo "# audits before:"; results
      out=$(frun rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"); printf '%s\n' "$out"
      echo "# audits after:"; results
      echo "count 'reconciled earlier interrupted runs'=$(count "$out" 'reconciled earlier interrupted runs')  'this run stopped'=$(count "$out" 'this run stopped')" ;;
  S10) echo "# S10: same state, fault removed: the next write rolls the crash back, then refuses (HEAD moved -> write must re-check)"
      run rrt rerecord-slot --check; run rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE"; results; grep ^slot_ "$META" ;;
  S11) echo "# S11: SIGTERM while the archive is staged (before publish) -> nothing published"
      make_fakebin; FAULT=slow-archive; b=$(sha "$META"); a0=$(audits | wc -l | tr -d ' ')
      PATH="$FB:$PATH" FM_LAB_FAULT=$FAULT FM_LAB_FAULT_DIR=$FM_HOME "$C" rrt rerecord-slot --manifest-sha "$(msha)" --note "$NOTE" > "$FM_HOME/s11.out" 2>&1 & pid=$!
      i=0; until [ -f "$FM_HOME/.mk-audit" ] || [ "$i" -ge 600 ]; do sleep 0.5; i=$((i+1)); done; sleep 1
      echo "# archive mktemp reached (RERECORD_STAGE=staged, before publish); sending TERM to pid $pid"; kill -TERM "$pid"; wait $pid; echo "rc=$?"; grep -v '^fm-gate-refuse:' "$FM_HOME/s11.out"
      [ "$(sha "$META")" = "$b" ] && echo "record unchanged"; echo "audits: before=$a0 after=$(audits | wc -l | tr -d ' ')"; ls -a "$FM_HOME/state" | grep rerecord || echo "no staged leftovers in state/" ;;
  S12) echo "# S12: relaunch after rerecord is admitted (endpoint: a plain shell pane in fmlab:fm-rrt)"
      tmux new-session -d -s fmlab -n fm-rrt -c "$WT" bash; tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command}'; grep ^slot_ "$META"; run rrt relaunch --note "resume after slot renewal"; sleep 3
      tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command}' 2>&1; agent_down ;;
esac
