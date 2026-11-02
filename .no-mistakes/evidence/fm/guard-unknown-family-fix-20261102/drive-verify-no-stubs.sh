#!/usr/bin/env bash
# Evidence driver with no stand-in at all. It runs the real bin/fm-review-record.py
# with the machine's normal PATH, against a throwaway HOME, FM_HOME, real git repo
# and real no-mistakes-shaped state.sqlite. The guard decision comes from this CLI.
# Usage: drive-verify-no-stubs.sh <repo-worktree>
set -u
WT=$1
RECORD="$WT/bin/fm-review-record.py"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-unknown-live.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
OLD="$ROOT/old"; mkdir -p "$OLD"
git -C "$WT" archive f77b7973ce14d0eb8813476cf380f8cb022ab9fb bin | tar -x -C "$OLD"
URL=https://github.com/example/repo/pull/9
UNKNOWN='{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
OTHER=2222222222222222222222222222222222222222
FAILS=0
g() { git -c user.name=lab -c user.email=lab@example.invalid "$@"; }
unset NM_HOME FM_STATE_OVERRIDE FM_ROOT_OVERRIDE

setup() {  # <name>
  C="$ROOT/$1"
  mkdir -p "$C/home/state" "$C/user/.no-mistakes"
  g init -q -b main "$C/wt"
  g -C "$C/wt" commit -q --allow-empty -m base
  BASE=$(g -C "$C/wt" rev-parse HEAD)
  g -C "$C/wt" commit -q --allow-empty -m 'ship implementation'
  g -C "$C/wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline repair by acp:omp'
  HEAD=$(g -C "$C/wt" rev-parse HEAD)
  printf 'worktree=%s\nkind=ship\nmodel=gpt-5.1-codex\nbranch=fm/fixture\nmode=no-mistakes\n' "$C/wt" > "$C/home/state/task-x1.meta"
  python3 - "$C/user/.no-mistakes/state.sqlite" "$C/wt" "$BASE" "$HEAD" "$URL" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, base_sha TEXT, head_sha TEXT, last_pushed_sha TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, step_name TEXT, agent TEXT, model TEXT, model_provider TEXT, status TEXT);''')
db.execute('INSERT INTO repos VALUES (?, ?)', ('repo', sys.argv[2]))
db.execute('INSERT INTO runs VALUES (?, ?, ?, ?, ?, ?, ?)', ('run', 'repo', 'fm/fixture', sys.argv[3], sys.argv[4], sys.argv[4], sys.argv[5]))
db.execute('INSERT INTO agent_invocations VALUES (?, ?, ?, ?, ?, ?)', ('run', 'review', 'acp:omp', '', None, 'completed'))
db.commit()
PY
}

read_as() {  # <reader> [PASS|FAIL] [head] [groups] [extra...]
  local reader=$1 verdict=${2:-PASS} head=${3:-$HEAD} groups=${4:-$UNKNOWN}
  [ "$#" -ge 4 ] && shift 4 || shift "$#"
  local report="$C/report-$RANDOM.md"
  printf 'VERDICT: %s head=%s\nReader evidence.\n' "$verdict" "$head" > "$report"
  HOME="$C/user" FM_HOME="$C/home" "$RECORD" review --pr "$URL" --head "$head" --verdict "$verdict" \
    --reader-model "$reader" --author-groups "$groups" --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$report" "$@" >/dev/null || { echo "  RECORD ERROR for $reader"; FAILS=$((FAILS + 1)); }
}

check() {  # <label> <want: pass|refuse|word> [--old] [verify flags]; prints the real JSON
  local label=$1 want=$2 cli=$RECORD rc=0 out got
  shift 2
  if [ "${1:-}" = --old ]; then cli="$OLD/bin/fm-review-record.py"; shift; fi
  out=$(HOME="$C/user" FM_HOME="$C/home" "$cli" verify --pr "$URL" --head "$HEAD" --task task-x1 --base "$BASE" --json "$@" 2>&1) || rc=$?
  case "$(jq -r 'if .ok then .basis else "refuse" end' <<<"$out" 2>/dev/null)" in
    independent-review) got=pass ;;
    captain-word) got=word ;;
    refuse) got=refuse ;;
    *) got="unparsed" ;;
  esac
  if [ "$got" = "$want" ]; then printf 'PASS  %s\n' "$label"; else printf 'FAIL  %s (wanted %s, got %s)\n' "$label" "$want" "$got"; FAILS=$((FAILS + 1)); fi
  printf '  verify exit=%s %s\n' "$rc" "$(jq -c 'if .ok then {ok,basis,head:(.head[0:12]),reader_model} else {ok,kind:.error.kind,message:(.error.message[0:170])} end' <<<"$out" 2>/dev/null || cut -c1-300 <<<"$out")"
}

printf 'PATH has no stand-in: gh=%s\n\n' "$(command -v gh)"

setup two; read_as claude-opus-5-5; read_as gpt-5.1-codex
sqlite3 "$C/user/.no-mistakes/state.sqlite" "SELECT 'author evidence: agent=' || agent || ' model=[' || model || ']' FROM agent_invocations"
check 'new rule: acp:omp empty model, two known families, --review-only' pass --review-only
check 'new rule: same reads, default verify' pass
check 'old rule at base f77b7973: same reads refused' refuse --old

setup one; read_as claude-opus-5-5
check 'one known family refused' refuse
setup same; read_as claude-opus-5-5; read_as sonnet
check 'two readers of one family refused' refuse
setup stale; read_as gpt-5.1-codex PASS "$OTHER"; read_as claude-opus-5-5
check 'second family on another head refused' refuse
setup newstale; read_as claude-opus-5-5; read_as gpt-5.1-codex; read_as gemini-3-pro PASS "$OTHER"
check 'newest read on another head refused' refuse
setup skip; read_as claude-opus-5-5; read_as gpt-5.1-codex PASS "$HEAD" "$UNKNOWN" --covered-groups '["ship"]'
check 'second family did not read the unknown group: refused' refuse
setup hide; read_as claude-opus-5-5 PASS "$HEAD" '{"all":["gpt-5.1-codex"]}'; read_as gemini-3-pro PASS "$HEAD" '{"all":["gpt-5.1-codex"]}'
check 'declaration that hides the unknown author: refused' refuse
setup allgood; read_as claude-opus-5-5 PASS "$HEAD" '{"all":["gpt-5.1-codex","unknown"]}'; read_as gemini-3-pro PASS "$HEAD" '{"all":["gpt-5.1-codex","unknown"]}'
check 'all-declaration that names the unknown author, two families: covered' pass --review-only
setup unkreader; read_as mistral-large; read_as claude-opus-5-5
check 'unknown-family reader never counts toward two families: refused' refuse

setup failorder; read_as gpt-5.1-codex; read_as gemini-3-pro FAIL; read_as claude-opus-5-5
check 'FAIL: earlier PASS does not count, one later family refused' refuse
read_as gpt-5.1-codex
check 'FAIL: two later families clear it' pass --review-only
setup failafter; read_as claude-opus-5-5; read_as gpt-5.1-codex; read_as gemini-3-pro FAIL
check 'FAIL after two families refused' refuse
read_as gpt-5.1-codex PASS "$OTHER"; read_as claude-opus-5-5 PASS "$OTHER"
check 'FAIL is not cleared by reads of another head' refuse

setup trig; read_as claude-opus-5-5; read_as gpt-5.1-codex PASS "$HEAD" "$UNKNOWN" --widens-guard yes
check 'yes trigger on the newest PASS: --review-only refused' refuse --review-only

setup word; read_as claude-opus-5-5
HOME="$C/user" FM_HOME="$C/home" "$RECORD" captain-word --pr "$URL" --head "$HEAD" --words 'merge pr 9 at this head' >/dev/null
check 'owner words at the exact head still clear one family' word
check 'owner words never satisfy --review-only' refuse --review-only

setup mixed
python3 - "$C/user/.no-mistakes/state.sqlite" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("INSERT INTO agent_invocations VALUES ('run','review','claude','claude-sonnet-5-5','anthropic','completed')")
db.commit()
PY
GROUPS3='{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
read_as claude-opus-5-5 PASS "$HEAD" "$GROUPS3"
check 'unknown and Claude pipeline authors, one Claude read refused' refuse
read_as gpt-5.1-codex PASS "$HEAD" "$GROUPS3"
check 'unknown and Claude pipeline authors, Claude and OpenAI reads covered' pass --review-only

printf '\nDRIVER FAILURES: %s\n' "$FAILS"
exit "$FAILS"
