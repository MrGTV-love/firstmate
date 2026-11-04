. "$(dirname "$0")/common.sh"
H=$W/hook-state; LK=$W/locked; LH=$LK/hook-state
filt() { grep -vE '^\s*("|[]\[{}])' | grep -v -e '^fm-gate-refuse' -e '^warning: ' -e '^notice: ' -e '^waiting: ' | sed 's/^/  | /'; }
windows() { echo "  tmux windows: $(tmux list-windows -a -F '#{window_name}' | tr '\n' ' ')"; }
pred nmt-pred-c >/dev/null 2>&1 || echo "pred-c spawn failed"
pred nmt-pred-d >/dev/null 2>&1 || echo "pred-d spawn failed"
echo "predecessors: $(sed -n 's/^branch=//p' "$L/state/nmt-pred-c.meta") $(sed -n 's/^branch=//p' "$L/state/nmt-pred-d.meta")"
lock() { mkdir -p "$LK"; chmod 500 "$LK"; tmux set-environment -g CODEX_HOOK_STATE_DIR "$LH"; echo "  (helper state dir set to an unwritable $LH, so the real Vernant helper refuses)"; }
unlock() { chmod 700 "$LK"; echo "  (helper state dir made writable again)"; }

echo; echo "=== RECOVERY A: provisioner refusal, then --relaunch while the window lives"
lock
brief nmt-succ-rec
spawn nmt-succ-rec --successor-of nmt-pred-c 2>&1 | filt; echo "  spawn exit=${PIPESTATUS[0]}"
echo "  --- retained record"; meta nmt-succ-rec | sed 's/^/  /'
echo "  markers in $LH: $(markers $LH)"; windows
echo "  --- adversarial: a fresh spawn of the same id WITHOUT the flag (would drop the declaration)"
before=$(snap)
spawn nmt-succ-rec 2>&1 | filt; echo "  exit=${PIPESTATUS[0]}"
[ "$before" = "$(snap)" ] && echo "  state unchanged: yes" || echo "  state unchanged: NO"
unlock
echo "  --- the supported retry while the window lives"
relaunch nmt-succ-rec 2>&1 | filt; echo "  relaunch exit=${PIPESTATUS[0]}"
echo "  --- admitted record"; meta nmt-succ-rec | sed 's/^/  /'
echo "  markers in $LH: $(markers $LH)"; marker_show $LH
carry nmt-succ-rec nmt-pred-c && r13 nmt-succ-rec "$LH"
echo "  --- a later relaunch of the admitted successor (ordinary attestation)"
relaunch nmt-succ-rec 2>&1 | filt; echo "  relaunch exit=${PIPESTATUS[0]}"
meta nmt-succ-rec | sed 's/^/  /'; echo "  markers in $LH: $(markers $LH)"

echo; echo "=== RECOVERY B: provisioner refusal, the window is gone, then a fresh spawn naming the same --successor-of"
rm -rf "$LH"; lock
brief nmt-succ-gone
spawn nmt-succ-gone --successor-of nmt-pred-d 2>&1 | filt; echo "  spawn exit=${PIPESTATUS[0]}"
meta nmt-succ-gone | sed 's/^/  /'; windows
tmux kill-window -t primary:fm-nmt-succ-gone 2>/dev/null && echo "  (killed window fm-nmt-succ-gone, as a reboot or a closed window would)"; windows
unlock
echo "  --- --relaunch once the window is gone"
relaunch nmt-succ-gone 2>&1 | filt; echo "  relaunch exit=${PIPESTATUS[0]}"
echo "  --- adversarial: fresh spawn WITHOUT the flag"
before=$(snap)
spawn nmt-succ-gone 2>&1 | filt; echo "  exit=${PIPESTATUS[0]}"
echo "  --- adversarial: fresh spawn naming a DIFFERENT predecessor"
spawn nmt-succ-gone --successor-of nmt-pred-b 2>&1 | filt; echo "  exit=${PIPESTATUS[0]}"
[ "$before" = "$(snap)" ] && echo "  state unchanged by both: yes" || echo "  state unchanged by both: NO"
echo "  --- the second route: fresh spawn naming the same --successor-of"
spawn nmt-succ-gone --successor-of nmt-pred-d 2>&1 | filt; echo "  spawn exit=${PIPESTATUS[0]}"
meta nmt-succ-gone | sed 's/^/  /'
echo "  markers in $LH: $(markers $LH)"; marker_show $LH
carry nmt-succ-gone nmt-pred-d && r13 nmt-succ-gone "$LH"
tmux set-environment -g CODEX_HOOK_STATE_DIR "$H"
