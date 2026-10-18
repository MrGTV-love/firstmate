#!/usr/bin/env bash
# Scenario O: a real running owner guard sleeps half of the default 60s interval (30s); an explicit setting still wins.
set -u
ROOT=$1; EV=$2
cd "$ROOT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB" > "$EV/.olab"
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/fakebin" "$LAB/procevent-claims"
cat > "$LAB/quiet.sh" <<'SH'
#!/usr/bin/env bash
exec sleep 300
SH
chmod +x "$LAB/quiet.sh"
export FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/procevent-claims
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE FM_PROCEVENT_OWNER_CHECK_SECONDS
echo "### Scenario O: owner-guard interval on real running guards"
guard_sleeps() { # source-id -> sleep args of the guard's children
  local g
  for g in $(pgrep -f "_owner-watchdog $1"); do pgrep -P "$g" | while read -r c; do ps -o command= -p "$c"; done; done | sort -u
}
bin/fm-procevent.sh register generic default-src -- "$LAB/quiet.sh" >/dev/null 2>&1 || bin/fm-procevent.sh register lavish default-src -- "$LAB/quiet.sh" 
bin/fm-procevent.sh reconcile >/dev/null 2>&1
sleep 3
echo "default (FM_PROCEVENT_OWNER_CHECK_SECONDS unset): guard child processes:"
guard_sleeps default-src | sed 's/^/  /'
bin/fm-procevent.sh retire default-src >/dev/null 2>&1
echo "--- explicit FM_PROCEVENT_OWNER_CHECK_SECONDS=10 on a second source:"
FM_PROCEVENT_OWNER_CHECK_SECONDS=10 bin/fm-procevent.sh register generic explicit-src -- "$LAB/quiet.sh" >/dev/null 2>&1 || true
FM_PROCEVENT_OWNER_CHECK_SECONDS=10 bin/fm-procevent.sh reconcile >/dev/null 2>&1
sleep 3
guard_sleeps explicit-src | sed 's/^/  /'
bin/fm-procevent.sh retire explicit-src >/dev/null 2>&1
bin/fm-procevent.sh list 2>&1 | head -5
