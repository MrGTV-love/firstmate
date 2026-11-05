#!/usr/bin/env bash
# Independent live drive of the contribution merge-owner classifier.
# Usage: live-drive.sh <firstmate-root> <scratch-dir>
# Builds one disposable FM_HOME per scenario with a fake GitHub transport
# (gh), a real git worktree, a real no-mistakes-shaped empty NM_HOME and the
# real review-record store; then runs the real CLI path:
#   fm-captain-hold.sh / fm-review-record.py / fm-contributions.sh verdict
#   -> fm-contributions.sh poll -> fm-fleet-snapshot.sh --contribution-input
#   -> fm-contributions.sh snapshot --all, and fm-bearings-snapshot.sh --json.
set -u
ROOT=$1
SCRATCH=$2
NOW=2026-09-16T08:00:00Z
URL=https://github.com/o/r/pull/8
mkdir -p "$SCRATCH"
unset NM_HOME

home_new() { # name
  local home="$SCRATCH/$1"
  rm -rf "$home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects" "$home/fakebin" "$home/forge" "$home/root/bin"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 1\n' > "$home/fakebin/tmux"
  printf '#!/bin/sh\nexit 0\n' > "$home/fakebin/no-mistakes"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/fakebin/"* "$home/root/bin/fm-guard.sh"
  ln -s "$ROOT/bin/fm-review-record.py" "$home/root/bin/fm-review-record.py"
  # Real task worktree: base commit, then the shipped head commit.
  mkdir -p "$home/wt"
  git -C "$home/wt" init -q -b main
  printf '# wt\n' > "$home/wt/README.md"
  git -C "$home/wt" add README.md
  git -C "$home/wt" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial
  git -C "$home/wt" rev-parse HEAD > "$home/forge/base"
  git -C "$home/wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m ship
  git -C "$home/wt" rev-parse HEAD > "$home/forge/head"
  printf 'main\n' > "$home/forge/base-ref"
  printf '0\n' > "$home/forge/behind"
  printf 'true\n' > "$home/forge/push"
  printf 'worktree=%s/wt\nkind=ship\nmodel=gpt-5.1\nbranch=fm/lab\nmode=direct-PR\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  printf -- '- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n' "$URL" >> "$home/data/backlog.md"
  mkdir -p "$home/data/delivery" "$home/nm-home"
  python3 -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$home/nm-home/state.sqlite"
  printf '[]\n' > "$home/forge/empty.json"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Fake GitHub transport. Logs every call; serves one open PR o/r#8.
set -eu
printf '%s\n' "$*" >> "$FORGE/calls.log"
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api'*'repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" --arg base "$(cat "$FORGE/base")" --arg ref "$(cat "$FORGE/base-ref")" '
      {base:{sha:$base,ref:$ref},state:"open",user:{login:"author"},head:{sha:$head},draft:false,mergeable:true,merged_at:null}' ;;
  'api'*'repos/o/r/issues/8/comments?'*|'api'*'repos/o/r/pulls/8/reviews?'*|'api'*'repos/o/r/pulls/8/comments?'*) printf '[]\n' ;;
  'api'*'repos/o/r/commits/'*'/check-runs?'*)
    printf '{"check_runs":[{"name":"test","id":1,"status":"completed","conclusion":"success","started_at":"2026-09-16T08:00:00Z"}]}\n' ;;
  'api'*'repos/o/r/commits/'*'/statuses?'*) printf '[]\n' ;;
  'api'*'repos/o/r/compare/'*)
    [ ! -e "$FORGE/compare-fail" ] || exit 1
    jq -n --argjson behind "$(cat "$FORGE/behind")" '{behind_by:$behind}' ;;
  'api'*'repos/o/r') jq -n --argjson push "$(cat "$FORGE/push")" '{permissions:{push:$push}}' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
  # Wrap in the repository's HTTP shim so `gh api -i` gets real-looking headers.
  mv "$home/fakebin/gh" "$home/fakebin/gh-backend"
  cp "$ROOT/tests/assets/gh-http-shim.sh" "$home/fakebin/gh" 2>/dev/null \
    || cp "$(dirname "$0")/gh-http-shim.sh" "$home/fakebin/gh"
  chmod +x "$home/fakebin/gh"
  printf '%s\n' "$home"
}

run() { # home cmd...
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" GH_SHIM_LOG="$home/forge/shim.log" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    NM_HOME="$home/nm-home" FM_SNAPSHOT_NOW="${SNAP_NOW:-$NOW}" FM_CONTRIBUTIONS_NOW="$NOW" \
    FM_BEARINGS_NOW="${SNAP_NOW:-$NOW}" "$@"
}

poll() { run "$1" bash "$ROOT/bin/fm-contributions.sh" poll >/dev/null 2>"$1/poll.err" || printf '  (poll exit %s: %s)\n' $? "$(tr '\n' ' ' < "$1/poll.err")"; }

show() { # home label
  local home=$1 out
  run "$home" bash "$ROOT/bin/fm-fleet-snapshot.sh" --contribution-input > "$home/input.json" 2>/dev/null
  out=$(run "$home" bash "$ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" --all 2>&1)
  printf '%s' "$out" | jq -r --arg label "$2" '
    "  [\($label)] row: actor=\(.rows[0].actor) | reason=\(.rows[0].reason) | hold=\(.rows[0].hold // "-")"
    + "\n  [\($label)] summary: counts.captain=\(.counts.captain) captain_list=\([.captain[]?.url]|length) proven_clear=\(.proven_clear) unreadable=\(.unreadable_records)"' 2>/dev/null \
    || printf '  [%s] snapshot output: %s\n' "$2" "$out"
}

bearings_line() { # home label
  run "$1" bash "$ROOT/bin/fm-bearings-snapshot.sh" --json 2>/dev/null | jq -r --arg label "$2" '
    "  [\($label)] /bearings --json: contributions.counts=\(.contributions.counts|tojson) captain=\([.contributions.captain[]? | {url,reason,hold}]|tojson)"'
}

review() { # home verdict reader [head]
  local home=$1 head=${4:-$(cat "$1/forge/head")}
  printf 'VERDICT: %s head=%s\nIndependent review.\n' "$2" "$head" > "$home/report.md"
  run "$home" "$ROOT/bin/fm-review-record.py" review --pr "$URL" --head "$head" --verdict "$2" \
    --reader-model "$3" --author-groups '{"all":["gpt-5.1"]}' --loosens-deny-allow-list no \
    --widens-guard no --customer-data-billing-spend no --report "$home/report.md" >/dev/null \
    && printf '  recorded review: %s by %s at head %s\n' "$2" "$3" "${head:0:8}"
}

hold() { # home args...
  local home=$1; shift
  FM_CAPTAIN_HOLD_NOW="${HOLD_NOW:-$NOW}" run "$home" bash "$ROOT/bin/fm-captain-hold.sh" "$@" >/dev/null 2>"$home/hold.err" \
    && printf '  fm-captain-hold.sh %s: ok\n' "$*" || printf '  fm-captain-hold.sh %s: FAILED %s\n' "$*" "$(cat "$home/hold.err")"
}

echo "== firstmate root: $ROOT ($(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.rev" 2>/dev/null))"

echo; echo "S1 green PR, fresh base, NO review record"
h=$(home_new s1); poll "$h"; show "$h" S1; bearings_line "$h" S1

echo; echo "S2 green PR, base behind main by 3 commits (stale base), qualifying PASS present"
h=$(home_new s2); review "$h" PASS sonnet; printf '3\n' > "$h/forge/behind"; poll "$h"; show "$h" S2

echo; echo "S3 green PR, fresh base, qualifying PASS (sonnet reader vs gpt-5.1 author) at exact head"
h=$(home_new s3); review "$h" PASS sonnet; poll "$h"; show "$h" S3; bearings_line "$h" S3

echo; echo "S4a PASS from same model family as the author (not qualifying)"
h=$(home_new s4a); review "$h" PASS gpt-5.1; poll "$h"; show "$h" S4a
echo "S4b PASS recorded for a different head"
h=$(home_new s4b); review "$h" PASS sonnet bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; poll "$h"; show "$h" S4b
echo "S4c FAIL verdict at exact head"
h=$(home_new s4c); review "$h" FAIL sonnet; poll "$h"; show "$h" S4c

echo; echo "S5 real live owner hold on a green PR with a qualifying PASS"
h=$(home_new s5); review "$h" PASS sonnet; poll "$h"; hold "$h" hold delivery --reason 'pick API shape A or B'; show "$h" S5; bearings_line "$h" S5

echo; echo "S6 hold answered with --release (answered decision)"
h=$(home_new s6); poll "$h"; hold "$h" hold delivery --reason 'pick API shape A or B'
printf 'Use shape A.\n' > "$h/decision.txt"; hold "$h" answer delivery --decision-file "$h/decision.txt" --release
show "$h" S6
echo "S6b same task held again with a new live hold"
HOLD_NOW=2026-09-16T08:00:01Z hold "$h" hold delivery --reason 'new owner question'; SNAP_NOW=2026-09-16T08:01:00Z show "$h" S6b

echo; echo "S7 dated hold (--until 2099-01-01, explicit pause)"
h=$(home_new s7); poll "$h"; hold "$h" hold delivery --reason 'wait for vendor' --until 2099-01-01; show "$h" S7

echo; echo "S8 worker declared 'paused:' wait, no hold"
h=$(home_new s8); poll "$h"; printf 'paused: waiting for external CI\n' > "$h/state/delivery.status"; show "$h" S8

echo; echo "S9 recorded owner decision: captain-actor verdict on current head, no hold"
h=$(home_new s9); poll "$h"
run "$h" bash "$ROOT/bin/fm-contributions.sh" verdict delivery "$URL" "$(cat "$h/forge/head")" "$URL#issuecomment-1" captain 'owner must choose X or Y' >/dev/null 2>&1 \
  && echo "  recorded captain verdict (at=$(jq -r '.records[0].verdict.at // "none"' "$h/data/delivery/contributions.json"))"
show "$h" S9
echo "S9b owner decision answered: hold filed then answered --release after the verdict"
hold "$h" hold delivery --reason 'owner must choose X or Y'
printf 'Choose X.\n' > "$h/decision.txt"; hold "$h" answer delivery --decision-file "$h/decision.txt" --release
show "$h" S9b

echo; echo "S10a compare read fails (base freshness unknown), qualifying PASS present"
h=$(home_new s10a); review "$h" PASS sonnet; touch "$h/forge/compare-fail"; poll "$h"; show "$h" S10a
echo "S10b verifier missing (PASS fact unknown), fresh base"
h=$(home_new s10b); rm "$h/root/bin/fm-review-record.py"; poll "$h"; show "$h" S10b
echo "S10c base branch name with a slash (release/1.0), qualifying PASS"
h=$(home_new s10c); review "$h" PASS sonnet; printf 'release/1.0\n' > "$h/forge/base-ref"; poll "$h"; show "$h" S10c
grep -o 'compare/[^ ]*' "$h/forge/calls.log" | sed 's/^/  compare path requested: /' | sort -u

echo; echo "S11 away merge authority unchanged: not tested here (covered by test_away_merge_action)"

echo; echo "S12 forge call log for S3 home (read-only check): every distinct call shape"
sed -E 's/[0-9a-f]{40}/<sha>/g' "$SCRATCH/s3/forge/calls.log" | sort -u | sed 's/^/  gh /'
if grep -Ev '^(api( -i)?( -H [^ ]+ [^ ]+)* repos/|api repos/|pr view )' "$SCRATCH/s3/forge/calls.log" | grep -q .; then echo '  NON-READ CALL SEEN'; else echo '  only api GET reads and pr view seen'; fi
grep -E -- '(-X|--method) *(POST|PUT|PATCH|DELETE)|pr (merge|edit|close|update-branch)' "$SCRATCH"/*/forge/calls.log && echo '  WRITE SEEN' || echo '  no write method or mutating gh verb in any scenario call log'
