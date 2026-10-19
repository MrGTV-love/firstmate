#!/usr/bin/env bash
# DOD-06: the keyed-answer intake still refuses what Slack must never reach.
# Usage: tests/fm-slack-intake-unchanged.test.sh
# Asserts the reserved reconcile value, a task not held for the captain, and an
# unknown key are refused, and that binding the slack-dm source is no bypass.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'skip: tasks-axi not found\n'; exit 0; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(fm_test_tmproot fm-slack-intake-unchanged)

home="$TMP/home"
mkdir -p "$home"/{data,state,config}
cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
(
  cd "$home"
  tasks-axi add held-call "Held call" --kind captain --repo sample >/dev/null
  tasks-axi add work-call "Work call" --kind ship --repo sample >/dev/null
)
export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config"
"$ROOT/bin/fm-captain-hold.sh" hold held-call --reason "captain choice" >/dev/null
"$ROOT/bin/fm-captain-hold.sh" bind slack-dm >/dev/null

rows=$'held-call\treconcile\t\nwork-call\tyes\t\nunknown-key\tyes\t\n'
set +e
printf '%s' "$rows" | bash "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source slack-dm > "$TMP/out"
set -e
[ "$(grep -c '^refused: held-call ' "$TMP/out")" = 1 ] || fail "reconcile was not refused"
[ "$(grep -c '^skipped: work-call ' "$TMP/out")" = 1 ] || fail "unheld work was not refused"
[ "$(grep -c '^skipped: unknown-key ' "$TMP/out")" = 1 ] || fail "unknown key was not refused"
"$ROOT/bin/fm-captain-hold.sh" open held-call || fail "a refused reconcile closed the held call"
# Binding the source must not become a reconcile bypass.
printf 'held-call\treconcile\t\n' | bash "$ROOT/bin/fm-captain-hold.sh" answers --any-origin --source slack-dm > "$TMP/bound.out" || true
grep -q '^refused: held-call ' "$TMP/bound.out" || fail "binding bypassed the reconcile refusal"
printf 'ok - intake refusals hold\n'
