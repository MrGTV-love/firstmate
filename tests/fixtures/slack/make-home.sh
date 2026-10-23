#!/usr/bin/env bash
# Build a disposable home for one Slack replay fixture.
# Usage: make-home.sh <scenario> <home-dir>
# Every scenario uses the real tasks-axi and captain-hold commands against the
# given isolated home. No Slack network call is made here.
set -euo pipefail
SCENARIO=${1:?usage: make-home.sh <scenario> <home-dir>}
HOME_DIR=${2:?usage: make-home.sh <scenario> <home-dir>}
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
mkdir -p "$HOME_DIR"/{data,state,config,projects}
chmod 700 "$HOME_DIR" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
cat > "$HOME_DIR/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
cd "$HOME_DIR"
if [ "$SCENARIO" != no-token ] && [ "$SCENARIO" != config ]; then
  cat > "$HOME_DIR/.env" <<'ENV'
SLACK_BOT_TOKEN=fixture-token-not-a-secret
FM_SLACK_DM_USER=U0TESTOWNER
FM_SLACK_ALLOWED_AUTHORS=U0TESTOWNER
FM_SLACK_POLL_MAX_ANSWERS=20
ENV
fi
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
CAPTAIN="$ROOT/bin/fm-captain-hold.sh"

task() {  # <id> <title> [body-file]
  local id=$1 title=$2 body=${3:-}
  if [ -n "$body" ]; then
    tasks-axi add "$id" "$title" --kind captain --repo sample --body-file "$body" >/dev/null
  else
    tasks-axi add "$id" "$title" --kind captain --repo sample >/dev/null
  fi
}

hold() {  # <id> [reason]
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z "$CAPTAIN" hold "$1" --reason "${2:-Select the release approach}" >/dev/null
}

close_call() {  # <id>
  printf 'fixture decision\n' > "$HOME_DIR/decision.txt"
  printf '%s\tfixture decision\t\t\n' "$1" \
    | "$CAPTAIN" answers --any-origin --source fixture >/dev/null
}

body_for() {  # <name>
  local name=$1
  cat > "$HOME_DIR/$name.body"
  printf '%s\n' "$HOME_DIR/$name.body"
}

options_body() {  # <introduction> <label1> <label2> [label3]
  local intro=$1 l1=$2 l2=$3 l3=${4:-}
  {
    printf '%s\n' "$intro"
    printf 'Option 1: %s (ship) - Deploy now\n' "$l1"
    printf 'Option 2: %s (wait) - Hold current\n' "$l2"
    [ -z "$l3" ] || printf 'Option 3: %s (abort) - Stop\n' "$l3"
  }
}

case "$SCENARIO" in
  mirror)
    task open-a "Open call A" "$(body_for open-a <<'EOF'
Release A is ready.
Recommendation: ship
Evidence: /tmp/evidence-a.md
EOF
)"
    task open-b "Open call B"
    task between "Call that closes between runs"
    task already-closed "Already closed call"
    hold open-a; hold open-b; hold between; hold already-closed
    close_call already-closed
    # A structured row whose id cannot be probed is deliberately uncertain.
    printf "## Queued\n- [ ] bad\$id - Unreadable state call (repo: sample, kind: captain, hold: unreadable, hold-kind: captain)\n" \
      >> "$HOME_DIR/data/backlog.md"
    ;;
  card-payload)
    task with-options "Choose a deployment" "$(body_for with-options <<'EOF'
Deployment choice.
Option 1: Ship it (ship) - Deploy now
Option 2: Wait (wait) - Hold current
Recommendation: ship
Evidence: /tmp/evidence-with-options.md
EOF
)"
    task no-options "Open-ended decision" "$(body_for no-options <<'EOF'
There are no enumerated options.
Recommendation: proceed with the default
Evidence: /tmp/evidence-no-options.md
EOF
)"
    task no-recommendation "Choose without a recommendation" "$(body_for no-recommendation <<'EOF'
Choose a path.
Option 1: Alpha (alpha) - First path
Option 2: Beta (beta) - Second path
Evidence: not-an-absolute-path
EOF
)"
    hold with-options; hold no-options; hold no-recommendation
    ;;
  parse-options)
    cat > "$HOME_DIR/facts-only.body" <<'EOF'
Checks before choosing:
1. CI is green
2) Reviewer approved
EOF
    cat > "$HOME_DIR/option-forms.body" <<'EOF'
Checks before choosing:
1. CI is green
2) Reviewer approved
Option 1: Ship it - Deploy now
Option 2: Wait (wait) - Hold current
EOF
    task facts-only "Facts only" "$HOME_DIR/facts-only.body"
    task option-forms "Option forms" "$HOME_DIR/option-forms.body"
    hold facts-only; hold option-forms
    ;;
  typed-reply|allowlist|unmatched|unmatched-two|contradiction|contradiction-typed|duplicate|resolution|unreachable|rate-limited|crash-a|crash-b|crash-release|long-text|backlog|arming|reaction-answer|single-char-answer|missing-scope|free-nine)
    case "$SCENARIO" in
      typed-reply) id=typed-call ;;
      reaction-answer) id=reaction-call ;;
      single-char-answer) id=single-call ;;
      missing-scope) id=scope-call ;;
      free-nine) id=free-nine-call ;;
      allowlist) id=allow-a ;;
      unmatched|unmatched-two) id=missing-call ;;
      contradiction|contradiction-typed) id=conflict-call ;;
      duplicate) id=dup-a ;;
      resolution|arming) id=resolve-call ;;
      unreachable|rate-limited) id=failure-call ;;
      crash-a) id=crash-a-call ;;
      crash-b) id=crash-b-call ;;
      crash-release) id=crash-release-call ;;
      long-text) id=long-call ;;
      backlog) id=slot-1 ;;
    esac
    if [ "$id" != missing-call ]; then
      options_body 'Pick one' 'Ship it' 'Wait' 'Abort' > "$HOME_DIR/options.body"
      task "$id" "Replay decision" "$HOME_DIR/options.body"
      hold "$id"
    fi
    case "$SCENARIO" in
      duplicate)
        for extra in dup-b dup-c; do
          task "$extra" "Replay decision $extra" "$HOME_DIR/options.body"
          hold "$extra"
        done
        ;;
      allowlist)
        for extra in allow-b allow-c allow-d; do
          task "$extra" "Replay decision $extra" "$HOME_DIR/options.body"
          hold "$extra"
        done
        ;;
      backlog)
        for n in 2 3 4 5; do
          task "slot-$n" "Backlog decision $n" "$HOME_DIR/options.body"
          hold "slot-$n"
        done
        ;;
    esac
    ;;
  no-token)
    task no-token-call "No token call" "$(body_for no-token <<'EOF'
No-token decision.
Option 1: Ship it (ship) - Deploy
Option 2: Wait (wait) - Hold
EOF
)"
    hold no-token-call
    ;;
  config)
    task config-call "Configuration call"
    hold config-call
    ;;
  *)
    printf 'make-home: unknown scenario %s\n' "$SCENARIO" >&2
    exit 2
    ;;
esac
# The arming scenario must start unbound so its first refusal is exercised;
# every other fixture is already opted in, matching the DoD's direct commands.
if [ "$SCENARIO" != arming ]; then
  "$CAPTAIN" bind slack-dm >/dev/null
fi
printf 'home=%s\n' "$HOME_DIR"
