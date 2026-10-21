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

hdr "S1 real two-entry chain, NO approval record"
write_real_shape; rm -f "$HOMEDIR/config/omp-approved-fallback-chains" "$ROOTDIR/config/omp-approved-fallback-chains"
both

hdr "S2 same chain + two-line record in the home config"
write_two_lines "$HOMEDIR/config/omp-approved-fallback-chains"
B1=$(sum "$CFG" "$HOMEDIR/config/omp-approved-fallback-chains")
both
B2=$(sum "$CFG" "$HOMEDIR/config/omp-approved-fallback-chains")
[ "$B1" = "$B2" ] && echo "config + record bytes unchanged by both consumers: yes" || echo "config + record bytes unchanged: NO"

hdr "S3 adversarial: add a THIRD unrecorded entry"
cat >> "$CFG" <<YAML
    openrouter/anthropic/claude-haiku-5.5-extra:
      - openrouter/deepseek/deepseek-v4-flash
YAML
both

hdr "S4 adversarial: old one-line three-route record against the real two-entry shape"
write_real_shape; printf '%s %s %s\n' "$SOL" "$MIMO" "$HAIKU" > "$HOMEDIR/config/omp-approved-fallback-chains"
both

hdr "S5 adversarial: merged single entry (sol -> mimo, haiku) with the two-line record"
cat > "$CFG" <<YAML
retry:
  fallbackChains:
    $SOL:
      - $MIMO
      - $HAIKU
YAML
write_two_lines "$HOMEDIR/config/omp-approved-fallback-chains"
both

hdr "S6a adversarial: GPT-named OpenRouter route listed in record stays flagged"
cat > "$CFG" <<YAML
retry:
  fallbackChains:
    $SOL:
      - openrouter/openai/gpt-6.1-sol
YAML
printf '%s openrouter/openai/gpt-6.1-sol\n' "$SOL" > "$HOMEDIR/config/omp-approved-fallback-chains"
both
hdr "S6b adversarial: openai/* route + modelRoles OpenRouter route stay flagged; openai/ in record is malformed"
cat > "$CFG" <<YAML
modelRoles:
  default: $MIMO
retry:
  fallbackChains:
    $SOL:
      - openai/gpt-6.1-sol
    $MIMO:
      - $HAIKU
YAML
printf '%s openai/gpt-6.1-sol\n%s %s\n' "$SOL" "$MIMO" "$HAIKU" > "$HOMEDIR/config/omp-approved-fallback-chains"
both
hdr "S6c adversarial: valid record + modelRoles OpenRouter route (record must not exempt a role)"
cat > "$CFG" <<YAML
modelRoles:
  default: $MIMO
retry:
  fallbackChains:
    $MIMO:
      - $HAIKU
YAML
printf '%s %s\n' "$MIMO" "$HAIKU" > "$HOMEDIR/config/omp-approved-fallback-chains"
both
hdr "S6d adversarial: case change of an approved route stays flagged"
cat > "$CFG" <<YAML
retry:
  fallbackChains:
    $SOL:
      - OpenRouter/xiaomi/mimo-v2.6-pro
YAML
printf '%s %s\n' "$SOL" "$MIMO" > "$HOMEDIR/config/omp-approved-fallback-chains"
both

hdr "S7 malformed record: valid line first, bad line 3 -> no exceptions, line number only, contents not echoed"
write_real_shape
printf '%s %s\n# note\nSECRET-TOKEN-do-not-echo *\n%s %s\n' "$SOL" "$MIMO" "$MIMO" "$HAIKU" > "$HOMEDIR/config/omp-approved-fallback-chains"
both | tee "$LAB/s7.out"
grep -q 'SECRET-TOKEN' "$LAB/s7.out" && echo "LEAK: record contents echoed" || echo "record contents not echoed: yes"

hdr "S8 review-6: NO omp config.yml + invalid approval record stays silent"
rm -f "$CFG"; printf 'garbage *\n' > "$HOMEDIR/config/omp-approved-fallback-chains"
both
hdr "S8b same, with ruby absent from PATH (shared function only)"
( set +u; PATH=/nonexistent HOME="$USERH" FM_HOME="$HOMEDIR" FM_ROOT_OVERRIDE="$ROOTDIR"; unset PI_CODING_AGENT_DIR OMP_PROFILE FM_CONFIG_OVERRIDE
  . "$WT/bin/fm-api-key-guard-lib.sh"; out=$(fm_omp_api_billing_config_diagnostics); echo "output=[${out}]" )

hdr "S9a code-root fallback: home has no record, code root has the two-line record"
write_real_shape; rm -f "$HOMEDIR/config/omp-approved-fallback-chains"; write_two_lines "$ROOTDIR/config/omp-approved-fallback-chains"
both
hdr "S9b home record wins even when empty (files never merged): code root record ignored"
: > "$HOMEDIR/config/omp-approved-fallback-chains"
both
rm -f "$HOMEDIR/config/omp-approved-fallback-chains" "$ROOTDIR/config/omp-approved-fallback-chains"

hdr "S10 FM_CONFIG_OVERRIDE selects the record directory"
mkdir -p "$LAB/alt"; write_two_lines "$LAB/alt/omp-approved-fallback-chains"
both FM_CONFIG_OVERRIDE="$LAB/alt"
hdr "S10b OMP_PROFILE selects the config that is checked"
mkdir -p "$USERH/.omp/profiles/mini/agent"
write_real_shape; cp "$CFG" "$USERH/.omp/profiles/mini/agent/config.yml"   # profile config holds the paid chain
printf 'modelRoles:\n  default: openai-codex/gpt-6.1-sol\n' > "$CFG"          # default agent config is clean
rm -f "$HOMEDIR/config/omp-approved-fallback-chains"
echo "profile selected, no record:"; both OMP_PROFILE=mini
write_two_lines "$HOMEDIR/config/omp-approved-fallback-chains"
echo "profile selected, record present:"; both OMP_PROFILE=mini
echo "no profile (clean default config):"; both
echo "(done; lab removed on exit)"
