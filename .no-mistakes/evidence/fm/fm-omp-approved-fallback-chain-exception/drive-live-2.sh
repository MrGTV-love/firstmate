#!/usr/bin/env bash
# Live driver for the omp approved-fallback-chain exception.
# Runs the REAL bin/fm-bootstrap.sh and the REAL bin/fm-remote-doctor.sh from the run worktree
# against a disposable lab (throwaway HOME, FM_HOME and code root). Nothing here touches the
# operator's real ~/.omp, real FM_HOME, real config/, Herdr, or credentials.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5DYNQNAK5X5J9AHVAG18XEQ
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
USERH="$LAB/user"      # fixture HOME
HOMEDIR="$LAB/home"    # fixture FM_HOME (operational home)
ROOTDIR="$LAB/root"    # fixture code root (FM_ROOT_OVERRIDE)
AGENT="$USERH/.omp/agent"
CFG="$AGENT/config.yml"
TOOLS="$LAB/tools"; FAKEUNAME="$LAB/fakeuname"
mkdir -p "$AGENT" "$HOMEDIR/config" "$ROOTDIR/config" "$TOOLS" "$FAKEUNAME"
for t in git jq python3 ruby; do ln -sf "$(command -v $t)" "$TOOLS/$t"; done
# Doctor fixture: pretend to be a Linux host with no herdr so no launchd/Herdr state is touched.
printf '#!/bin/sh\nexec /usr/bin/uname "$@" | sed s/Darwin/Linux/\n' > "$FAKEUNAME/uname"; chmod +x "$FAKEUNAME/uname"
DOCTOR_PATH="$FAKEUNAME:$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

SOL=openai-codex/gpt-6.1-sol; MIMO=openrouter/xiaomi/mimo-v2.6-pro; HAIKU=openrouter/anthropic/claude-haiku-5.5
write_real_shape() { # the real Studio two-entry shape
  cat > "$CFG" <<YAML
retry:
  fallbackChains:
    $SOL:
      - $MIMO
    $MIMO:
      - $HAIKU
YAML
}
write_two_lines() { printf '# 2026-10-20 captain approval\n%s %s\n%s %s\n' "$SOL" "$MIMO" "$MIMO" "$HAIKU" > "$1"; }

bootstrap_lines() { # extra env as args
  env -u PI_CODING_AGENT_DIR -u OMP_PROFILE -u FM_CONFIG_OVERRIDE -u NO_MISTAKES_GATE "$@" \
    HOME="$USERH" FM_HOME="$HOMEDIR" FM_ROOT_OVERRIDE="$ROOTDIR" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    "$WT/bin/fm-bootstrap.sh" 2>&1 | grep '^OMP_API_BILLING:' || echo "(no OMP_API_BILLING lines)"
}
doctor_lines() {
  env -u PI_CODING_AGENT_DIR -u OMP_PROFILE -u FM_CONFIG_OVERRIDE -u NO_MISTAKES_GATE "$@" \
    HOME="$USERH" PATH="$DOCTOR_PATH" FM_HOME="$HOMEDIR" FM_ROOT_OVERRIDE="$ROOTDIR" \
    "$WT/bin/fm-remote-doctor.sh" 2>&1 | grep -E '^check omp-api-billing=' || echo "(no omp-api-billing line)"
}
both() { echo "--- bootstrap:"; bootstrap_lines "$@"; echo "--- doctor:"; doctor_lines "$@"; }
hdr() { printf '\n=== %s ===\n' "$1"; }
sum() { shasum -a 256 "$@" 2>/dev/null | awk '{print $1}' | tr '\n' ' '; }

REC="$HOMEDIR/config/omp-approved-fallback-chains"
case_run() { hdr "$1"; shift; both "$@"; }

write_real_shape
rm -rf "$REC"; mkdir "$REC"
case_run "T1 record path is a directory -> config problem reported, no exceptions"
rm -rf "$REC"; write_two_lines "$REC.real"; chmod 000 "$REC.real"; ln -s "$REC.real" "$REC"
case_run "T2 record is a symlink to an unreadable file -> config problem reported, no exceptions"
chmod 644 "$REC.real"; rm -f "$REC" "$REC.real"
ln -s "$LAB/does-not-exist" "$REC"
case_run "T3 dangling symlink record -> config problem reported, no exceptions"
rm -f "$REC"
printf '%s\t%s   \r\n%s %s\r\n' "$SOL" "$MIMO" "$MIMO" "$HAIKU" > "$REC"
case_run "T4 tab-separated, trailing space and CRLF line endings -> still approved (documented separators)"
printf '%s %s # inline comment\n%s %s\n' "$SOL" "$MIMO" "$MIMO" "$HAIKU" > "$REC"
case_run "T5 inline comment on a record line -> line 1 invalid, all exceptions invalidated"
printf 'openrouter/* openrouter/xiaomi/mimo-v2.6-pro\n' > "$REC"
case_run "T6 wildcard record -> invalid, nothing exempted"
printf '%s %s\n%s %s\n' "$SOL" "$MIMO" "$MIMO" "$HAIKU" > "$REC"
cat > "$CFG" <<YAML
retry:
  fallbackChains:
    $SOL:
      - $MIMO
    $MIMO:
      - $HAIKU
      - $HAIKU
YAML
case_run "T7 recorded entry with an extra (duplicate) target -> that entry stays flagged"
cat > "$CFG" <<YAML
retry:
  fallbackChains:
    "  $SOL":
      - "$MIMO  "
    $MIMO:
      - $HAIKU
YAML
case_run "T8 padded selector variants of recorded routes -> padded entry stays flagged"
echo "(done; lab removed on exit)"
