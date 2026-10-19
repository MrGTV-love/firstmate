#!/usr/bin/env bash
# Live check: drive the REAL bin/fm-spawn.sh and bin/fm-promote.sh from the gate
# worktree against a throwaway FM_HOME, fake omp (no network, no API key), fake
# tmux (no pane/window) and fake treehouse (no slot). Prints what a reader would
# actually be launched with.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M59M0NYR8JSM2TY9C6FKQ0NM
cd "$WT" || exit 1
# shellcheck disable=SC1091
. "$WT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-fixed-family)
export NODE_NO_WARNINGS=1 PI_CODING_AGENT_DIR= OMP_PROFILE='' PI_PROFILE=''

make_fake_omp() {
  cat > "$1/omp" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version) printf 'omp/%s\n' "${FM_FAKE_OMP_VERSION:-18.1.20}" ;;
  models) printf '%s\n' '{"models":[{"provider":"openai-codex","id":"gpt-6.1-sol","selector":"openai-codex/gpt-6.1-sol"},{"provider":"deepseek","id":"deepseek-v4-flash","selector":"deepseek/deepseek-v4-flash"}]}' ;;
  usage) if [ -n "${OMP_USAGE_FIXTURE:-}" ]; then cat "$OMP_USAGE_FIXTURE"; else printf '{}\n'; fi ;;
esac
exit 0
SH
  chmod +x "$1/omp"
}

new_case() {  # <name> <harness> <id>  -> sets C_HOME C_PROJ C_WT C_BIN C_LOG
  local name=$1 harness=$2 id=$3 d
  d="$TMP_ROOT/$name"
  C_HOME="$d/home"; C_PROJ="$d/project"; C_WT="$d/wt"
  C_BIN=$(make_spawn_fakebin "$d/fake" claude)
  make_fake_omp "$C_BIN"
  fm_test_spawn_home "$C_HOME" "$harness"
  fm_git_worktree "$C_PROJ" "$C_WT" "wt-$name"
  fm_test_spawn_brief "$C_HOME" "$id"
  C_LOG="$d/launch.log"; : > "$C_LOG"
  printf '%s\n' '{"rules":[{"when":"review","use":{"harness":"omp","model":"openai-codex/gpt-6.1-sol","effort":"high"},"fallback":[{"harness":"omp","model":"deepseek/deepseek-v4-flash","effort":"high"}]}]}' > "$C_HOME/config/crew-dispatch.json"
  jq -n --argjson now "$(date +%s)" '{reports:[{provider:"openai-codex",fetchedAt:($now*1000),metadata:{meterStates:{chat:{allowed:true,limitReached:false}}}}]}' > "$d/usage.json"
  C_USAGE="$d/usage.json"
  mkdir -p "$C_HOME/user-home/.omp/agent"
}

spawn() {  # <id> <args...>
  local id=$1; shift
  OMP_USAGE_FIXTURE="$C_USAGE" FM_FAKE_LAUNCH_LOG="$C_LOG" \
    fm_test_run_spawn "$C_HOME" "$C_WT" "$C_BIN" "$id" "$C_PROJ" "$@"
}

relaunch() {  # <id> <args...>
  local id=$1; shift
  local bin="$C_BIN/relaunch-shell"
  mkdir -p "$bin"
  cat > "$bin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *pane_current_command*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$C_BIN/tmux" "\$@"
SH
  chmod +x "$bin/tmux"
  : > "$C_LOG"
  OMP_USAGE_FIXTURE="$C_USAGE" FM_FAKE_DUPLICATE_WINDOW="$(sed -n 's/^window=[^:]*://p' "$C_HOME/state/$id.meta")" FM_FAKE_LAUNCH_LOG="$C_LOG" \
    fm_test_run_spawn "$C_HOME" "$C_WT" "$bin:$C_BIN" "$id" --relaunch "$@"
}

chains() { jq -c '.retry.fallbackChains' "$C_HOME/state/$1.omp-fallback.yml" 2>/dev/null || echo "(no overlay)"; }
hdr() { printf '\n===== %s =====\n' "$*"; }
SOL=(--harness omp --model openai-codex/gpt-6.1-sol --effort high --dispatch-rule rule_1)

hdr "S1 baseline: review-reader scout WITHOUT --fixed-family (the Vernant bug shape)"
new_case s1 omp reader-default
out=$(spawn reader-default --scout "${SOL[@]}"); echo "exit=$?"
echo "chains: $(chains reader-default)"
echo "meta fixed_family: $(grep -c '^fixed_family=' "$C_HOME/state/reader-default.meta")"

hdr "S2 review-reader scout WITH --fixed-family: chains must be empty"
new_case s2 omp reader-fixed
out=$(spawn reader-fixed --scout --fixed-family "${SOL[@]}"); echo "exit=$?"
echo "chains: $(chains reader-fixed)"
echo "meta: $(grep '^fixed_family=' "$C_HOME/state/reader-fixed.meta")"
echo "launch uses overlay: $(grep -c 'omp-fallback.yml' "$C_LOG") line(s) reference omp-fallback.yml"
echo "any 'deepseek' anywhere in the overlay: $(grep -c deepseek "$C_HOME/state/reader-fixed.omp-fallback.yml")"

hdr "S3 relaunch of fixed-family scout (flag NOT repeated) keeps empty chains"
out=$(relaunch reader-fixed "${SOL[@]:2}"); echo "exit=$?"
echo "chains: $(chains reader-fixed)"
echo "meta: $(grep '^fixed_family=' "$C_HOME/state/reader-fixed.meta")"

hdr "S4 promote fixed-family scout to ship, then relaunch (review-1 decision: drop key)"
out=$(FM_ROOT_OVERRIDE="$WT" FM_HOME="$C_HOME" FM_STATE_OVERRIDE="$C_HOME/state" FM_DATA_OVERRIDE="$C_HOME/data" FM_CONFIG_OVERRIDE="$C_HOME/config" "$WT/bin/fm-promote.sh" reader-fixed --mode local-only --yolo off 2>&1); echo "promote exit=$?"
echo "meta kind: $(grep '^kind=' "$C_HOME/state/reader-fixed.meta") ; fixed_family lines: $(grep -c '^fixed_family=' "$C_HOME/state/reader-fixed.meta")"
out=$(relaunch reader-fixed "${SOL[@]:2}"); echo "relaunch exit=$?"; echo "$out" | tail -3
echo "chains after ship relaunch: $(chains reader-fixed)"

hdr "S5 adversarial: --fixed-family on a ship"
new_case s5 omp ship-ff
out=$(spawn ship-ff --mode no-mistakes --yolo off --harness omp --fixed-family); echo "exit=$?"; echo "$out" | tail -2
echo "meta exists: $([ -e "$C_HOME/state/ship-ff.meta" ] && echo YES || echo no); overlay exists: $([ -e "$C_HOME/state/ship-ff.omp-fallback.yml" ] && echo YES || echo no); launched: $([ -s "$C_LOG" ] && echo YES || echo no)"

hdr "S6 adversarial: --fixed-family on a secondmate"
new_case s6 omp sm-ff
out=$(spawn sm-ff --secondmate --harness omp --fixed-family); echo "exit=$?"; echo "$out" | tail -2
echo "meta exists: $([ -e "$C_HOME/state/sm-ff.meta" ] && echo YES || echo no); launched: $([ -s "$C_LOG" ] && echo YES || echo no)"

hdr "S7 adversarial: --fixed-family with a raw launch command"
new_case s7 omp raw-ff
out=$(spawn raw-ff --scout 'omp --auto-approve' --fixed-family); echo "exit=$?"; echo "$out" | tail -2
echo "meta exists: $([ -e "$C_HOME/state/raw-ff.meta" ] && echo YES || echo no); launched: $([ -s "$C_LOG" ] && echo YES || echo no)"

hdr "S8 non-omp harness (claude) scout with --fixed-family: no-op with notice"
new_case s8 claude cl-ff
out=$(spawn cl-ff --scout --harness claude --fixed-family); echo "exit=$?"; echo "$out" | grep -i 'fixed-family'
echo "omp overlay present: $([ -e "$C_HOME/state/cl-ff.omp-fallback.yml" ] && echo YES || echo no); fixed_family in meta: $(grep -c '^fixed_family=' "$C_HOME/state/cl-ff.meta")"

hdr "S9 adversarial: relaunch of an existing SHIP with explicit --fixed-family"
new_case s9 omp ship-rl
out=$(spawn ship-rl --mode local-only --yolo off "${SOL[@]}"); echo "ship spawn exit=$?"
out=$(relaunch ship-rl "${SOL[@]:2}" --fixed-family); echo "relaunch exit=$?"; echo "$out" | tail -2

hdr "S10 adversarial: tampered meta (fixed_family=junk) on a scout relaunch"
new_case s10 omp junk
out=$(spawn junk --scout --fixed-family "${SOL[@]}"); echo "spawn exit=$?"
sed -i.bak 's/^fixed_family=on$/fixed_family=junk/' "$C_HOME/state/junk.meta"
out=$(relaunch junk "${SOL[@]:2}"); echo "relaunch exit=$?"; echo "$out" | tail -2

hdr "S11 combo: --fixed-family + --omp-no-helpers on a scout"
new_case s11 omp combo
out=$(spawn combo --scout --fixed-family --omp-no-helpers "${SOL[@]}"); echo "exit=$?"; echo "$out" | tail -2
echo "chains: $(chains combo)"
echo "meta: $(grep -E '^(fixed_family|omp_no_helpers)=' "$C_HOME/state/combo.meta" | tr '\n' ' ')"

hdr "S12 bad promote guard: ordinary scout promote leaves meta sane (no fixed_family introduced)"
new_case s12 omp plain
out=$(spawn plain --scout "${SOL[@]}"); echo "spawn exit=$?"
out=$(FM_ROOT_OVERRIDE="$WT" FM_HOME="$C_HOME" FM_STATE_OVERRIDE="$C_HOME/state" FM_DATA_OVERRIDE="$C_HOME/data" FM_CONFIG_OVERRIDE="$C_HOME/config" "$WT/bin/fm-promote.sh" plain --mode local-only --yolo off 2>&1); echo "promote exit=$?"
echo "kind: $(grep '^kind=' "$C_HOME/state/plain.meta"); fixed_family lines: $(grep -c '^fixed_family=' "$C_HOME/state/plain.meta")"
