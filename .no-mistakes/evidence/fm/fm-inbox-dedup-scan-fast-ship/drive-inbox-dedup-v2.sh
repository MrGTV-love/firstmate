#!/usr/bin/env bash
# Live drive of the idempotent inbox enqueue through the REAL bin/fm-send.sh
# (--fire-and-forget to a kind=secondmate tmux task -> fm_task_inbox_write_idempotent)
# in a disposable marked lab home on a private tmux socket.
# Usage: drive-inbox-dedup.sh <lab-helper-root> <fm-send-root> <label>
#   <lab-helper-root>: tree whose bin/fm-lab-home.sh mints the lab (the run worktree)
#   <fm-send-root>:    tree whose bin/fm-send.sh is driven (head worktree, or a base export)
set -u
HELPER_ROOT=$1
SEND_ROOT=$2
LABEL=$3
N_HANDLED=${N_HANDLED:-1500}
N_ROOT=${N_ROOT:-271}

eval "$("$HELPER_ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"
[ -n "${FM_HOME:-}" ] && [ -n "${TMUX_TMPDIR:-}" ] || { echo "lab env failed"; exit 1; }
export FM_HOME TMUX_TMPDIR
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-shim.XXXXXX")
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec %q -L fm-lab "$@"\n' "$REAL_TMUX" > "$SHIM/tmux"
chmod +x "$SHIM/tmux"
export PATH="$SHIM:$PATH"
unset TMUX
cleanup() {
  tmux kill-server 2>/dev/null || true
  "$HELPER_ROOT/bin/fm-lab-home.sh" teardown "$FM_HOME" >/dev/null 2>&1 && rm -rf "$FM_HOME"
  rm -rf "$SHIM"
}
trap cleanup EXIT

echo "== [$LABEL] lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR fm-send root=$SEND_ROOT"
tmux new-session -d -s fmlab -n fm-domain -x 200 -y 50 'cat'
echo "-- tmux sessions on the private fm-lab socket:"; tmux list-sessions

META="$FM_HOME/state/domain.meta"
printf '%s\n' "window=fmlab:fm-domain" "endpoint_task_id=domain" "worktree=$FM_HOME" \
  "project=$FM_HOME" "harness=echo" "kind=secondmate" "mode=secondmate" "yolo=off" \
  "home=$FM_HOME" "projects=alpha" > "$META"
INBOX="$FM_HOME/state/domain.inbox"

send() { # <id> <text>  -> prints elapsed seconds and record lines
  local t0 t1 rc out
  rm -f "$FM_HOME/.poll-stop" "$FM_HOME/.poll-out"
  # Independent observer: poll for the inbox sequence lock every 2 ms and record how long each hold lasted.
  perl -MTime::HiRes=time,sleep -e '
    my ($lock,$stop,$out)=@ARGV; my ($held,$t)=(0,0); my @h;
    while (!-e $stop) { my $e = (-e $lock || -l $lock) ? 1 : 0;
      if ($e && !$held) { $held=1; $t=time } elsif (!$e && $held) { $held=0; push @h, time-$t }
      sleep 0.002 }
    push @h, time-$t if $held;
    open my $fh, ">", $out; print $fh join(" ", map { sprintf "%.3fs", $_ } @h);' \
    "$INBOX/.seq.lock" "$FM_HOME/.poll-stop" "$FM_HOME/.poll-out" &
  local poller=$!
  sleep 0.2
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    "$SEND_ROOT/bin/fm-send.sh" domain --fire-and-forget "$1" -- "$2" 2>&1); rc=$?
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  touch "$FM_HOME/.poll-stop"; wait "$poller" 2>/dev/null
  printf 'send id=%s rc=%s fm-send-wall=%ss inbox-.seq.lock-hold(observed)=[%s]\n' "$1" "$rc" "$(perl -e "printf '%.2f', $t1-$t0")" "$(cat "$FM_HOME/.poll-out" 2>/dev/null)"
  [ -z "$out" ] || printf '  fm-send said: %s\n' "$out"
  pane
}
count() { local a b; a=$(find "$INBOX" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' '); b=$(find "$INBOX/handled" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' '); echo "records: root=$a handled=$b"; }
leftovers() { local l; l=$(find "$INBOX" -maxdepth 2 \( -name '.dedup.*' -o -name '.staging.*' -o -name '.seq.lock' -o -name '.lock-probe.*' \) | tr '\n' ' '); echo "leftover temp/lock files: [${l}]"; }
newest() { local n; n=$(ls "$INBOX" | grep -E '^[0-9]+\.msg$' | sort -n | tail -1); printf '%s/%s\n' "$INBOX" "$n"; }
pane() { sleep 0.5; printf 'doorbell seen in lab pane: %s\n' "$(tmux capture-pane -p -t fmlab:fm-domain | grep . | tail -1)"; }

echo; echo "== seed: one real send to learn the exact record shape"
send 00000000000000aa "seed message"
SEED=$(newest); echo "seed record: $SEED"; echo "--- seed record bytes:"; cat "$SEED"; echo; echo "---"
# Body prefix fm-send adds before 'delivery=<id> <text>'
PREFIX=$(awk 'f{print; exit} /^--$/{f=1}' "$SEED" | sed 's/delivery=00000000000000aa seed message$//')
printf 'derived body prefix bytes: '; printf '%s' "$PREFIX" | od -An -c | head -2
mv "$SEED" "$INBOX/handled/"

echo; echo "== bulk: $N_HANDLED records in handled/ + $N_ROOT in the inbox root, distinct first lines, fire-and-forget"
mk() { # <path> <seq>
  printf 'schema=%s\nat=2026-11-01T00:00:00Z\ndelivery=fire-and-forget\n--\n%sdelivery=%016x bulk steer number %s\nsecond line %s' \
    "$(sed -n 's/^schema=//p' "$INBOX/handled/001.msg")" "$PREFIX" "$2" "$2" "$2" > "$1"
}
i=2; while [ "$i" -le $((N_HANDLED + 1)) ]; do mk "$INBOX/handled/$(printf %03d "$i").msg" "$i"; i=$((i+1)); done
while [ "$i" -le $((N_HANDLED + N_ROOT + 1)) ]; do mk "$INBOX/$(printf %03d "$i").msg" "$i"; i=$((i+1)); done
# numbering traps: a leading-zero max in handled/, and non-record names that must be ignored
MAXSEQ=2000
mk "$INBOX/handled/0$MAXSEQ.msg" "$MAXSEQ"
for junk in 12a.msg abc.msg 99999x.msg .9999.msg; do printf 'junk\n' > "$INBOX/$junk"; done
count
echo "highest real sequence: handled/0$MAXSEQ.msg (leading zero); junk names present: 12a.msg abc.msg 99999x.msg .9999.msg"

echo; echo "== S1 big-inbox fresh send (expect a NEW record $((MAXSEQ+1)).msg, well under the 30 s remote budget)"
send 1111111111111111 "please reconcile the ledger now"
R1=$(newest); echo "record: $R1"; count; leftovers

echo; echo "== S2a exact re-run, record still in the inbox root (expect SAME path, no new record)"
send 1111111111111111 "please reconcile the ledger now"
echo "newest record now: $(newest)"; count; leftovers

echo; echo "== S2b exact re-run of a bulk record deep in handled/ (#1200, past the 500-file grep chunk) (expect handled/1200.msg, no new record)"
send "$(printf %016x 1200)" "bulk steer number 1200
second line 1200"
echo "newest record now: $(newest)"; count; leftovers
echo "== S2c exact re-run of a bulk record in the inbox root (#1700) (expect 1700.msg, no new record)"
send "$(printf %016x 1700)" "bulk steer number 1700
second line 1700"
echo "newest record now: $(newest)"; count; leftovers

echo; echo "== S3 near-duplicate: same id, same first line, different second line (expect a NEW record)"
send 3333333333333333 "shared first line
variant A"
A=$(newest); echo "record A: $A"
send 3333333333333333 "shared first line
variant B"
B=$(newest); echo "record B: $B"; count
[ "$A" != "$B" ] && echo "RESULT S3: distinct records" || echo "RESULT S3: COLLAPSED (wrong)"

echo; echo "== S4 hostile regex/glob bytes in the first line, sent twice (expect ONE record)"
H='.*[\ ^$ (a|b) "q" `x` -e --null *.msg'
send 4444444444444444 "$H"
H1=$(newest); echo "record: $H1"; count
send 4444444444444444 "$H"
echo "newest after re-run: $(newest)"; count; leftovers

echo; echo "== final listing of the newest root records"
ls "$INBOX" | grep -v '^handled$' | sort | tail -8
echo "== [$LABEL] done"
