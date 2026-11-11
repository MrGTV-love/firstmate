#!/usr/bin/env bash
# Live driver: runs the real bin/fm-review-record.py (review + verify) against
# disposable FM_HOME / NM_HOME / git fixtures. Usage: drive-verify.sh <code-root> <label>
set -u
CODE=$1; LABEL=$2
REC="$CODE/bin/fm-review-record.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-verify.XXXXXX")
trap 'rm -rf "$T"' EXIT
URL=https://github.com/example/repo/pull/9
SHIP=gpt-5.1-codex
G_UNK='{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
G_ANT='{"ship":["gpt-5.1-codex"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
gi() { git -C "$1" -c user.name=Live -c user.email=live@example.invalid "${@:2}"; }

mkcase() {  # <name> <ship-model> -> sets C, HEAD, BASE
  C="$T/$1"; mkdir -p "$C/home/state" "$C/wt"
  gi "$C/wt" init -q; gi "$C/wt" commit -q --allow-empty -m base
  BASE=$(gi "$C/wt" rev-parse HEAD)
  gi "$C/wt" commit -q --allow-empty -m 'ship implementation'
  gi "$C/wt" commit -q --allow-empty -m 'no-mistakes(review): pipeline repair'
  HEAD=$(gi "$C/wt" rev-parse HEAD)
  printf '%s\n' "worktree=$C/wt" kind=ship "model=$2" branch=fm/fixture mode=no-mistakes > "$C/home/state/task-x1.meta"
}
db() {  # <nm-home> <kind>
  mkdir -p "$1"
  case "$2" in
    corrupt) printf 'not a sqlite db\n' > "$1/state.sqlite"; return ;;
  esac
  python3 - "$1/state.sqlite" "$C/wt" "$URL" "$2" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript('''CREATE TABLE repos (id TEXT, working_path TEXT);
CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT);
CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);''')
db.execute("INSERT INTO repos VALUES ('r', ?)", (sys.argv[2],))
db.execute("INSERT INTO runs VALUES ('run', 'r', 'fm/fixture', ?)", (sys.argv[3],))
row = {'known': ('claude', 'claude-sonnet-5-5', 'anthropic'),
       'nomodel': ('acp:omp', None, None),
       'conflict': ('claude', 'claude-sonnet-5-5', 'openai')}[sys.argv[4]]
db.execute("INSERT INTO agent_invocations VALUES ('run', ?, ?, ?)", row)
db.commit()
PY
}
rev() {  # <verdict> <reader> <groups> [extra]
  printf 'VERDICT: %s head=%s\nLive reader report.\n' "$1" "$HEAD" > "$C/report-$2-$1.md"
  FM_HOME="$C/home" python3 "$REC" review --pr "$URL" --head "$HEAD" --verdict "$1" --reader-model "$2" \
    --author-groups "$3" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$C/report-$2-$1.md" "${@:4}" >/dev/null 2>&1 || echo "  (record $1 $2 refused)"
}
ver() {  # <nm-home> [--json]
  local rc=0 out
  out=$(NM_HOME="$1" FM_HOME="$C/home" python3 "$REC" verify --pr "$URL" --head "$HEAD" --task task-x1 --base "$BASE" "${@:2}" 2>&1) || rc=$?
  printf '  $ verify %s\n' "${*:2}"; printf '%s\n' "$out" | sed 's/^/    /'; printf '    [exit %s]\n' "$rc"
}
hdr() { printf '\n=== %s ===\n%s\n' "$1" "$2"; }

echo "# live verify driver; code root label: $LABEL"

hdr S1-absent-one-outside-reader "ship=$SHIP; NM state.sqlite absent; one sonnet PASS. Expect accept + fact."
mkcase s1 $SHIP; rev PASS claude-sonnet-5-5 "$G_UNK"; ver "$C/absent-nm"; ver "$C/absent-nm" --json

hdr S1b-nomodel-invocation-one-reader "ship=$SHIP; run recorded acp:omp invocation with no model/provider; one sonnet PASS. Expect accept + fact."
mkcase s1b $SHIP; db "$C/nm" nomodel; rev PASS claude-sonnet-5-5 "$G_UNK"; ver "$C/nm"

hdr S2-reader-same-as-ship "ship=$SHIP; absent NM; one gpt-5.1 PASS (same openai family). Expect refuse; message offers one-reader rule naming (openai)."
mkcase s2 $SHIP; rev PASS gpt-5.1 "$G_UNK"; ver "$C/absent-nm"

hdr S3-unknown-ship-one-reader "ship=mystery-9 (unknown); absent NM; one sonnet PASS. Expect refuse, two-reader text, no relief."
mkcase s3 mystery-9; rev PASS claude-sonnet-5-5 '{"ship":["mystery-9"],"no-mistakes:unknown":["unknown"]}'; ver "$C/absent-nm"

hdr S3b-partly-unknown-ship "ship=gpt-5.1-codex + prior mystery-9; absent NM; sonnet PASS all + gemini PASS ship only. Expect refuse on no-mistakes:unknown, two-reader text."
mkcase s3b $SHIP; printf 'model=mystery-9\n' > "$C/home/state/task-x1.control-relaunch.meta-prior"
G_MIX='{"ship":["gpt-5.1-codex","mystery-9"],"no-mistakes:unknown":["unknown"]}'
rev PASS claude-sonnet-5-5 "$G_MIX"; rev PASS gemini-3-pro "$G_MIX" --covered-groups '["ship"]'; ver "$C/absent-nm"

hdr S4-unknown-newest-reader "ship=$SHIP; absent NM; sonnet PASS then mystery-9 PASS (unknown reader newest). Expect refuse: newest reader unknown."
mkcase s4 $SHIP; rev PASS claude-sonnet-5-5 "$G_UNK"; rev PASS mystery-9 "$G_UNK"; ver "$C/absent-nm"

hdr S5a-known-pipeline-same-family-reader "ship=$SHIP; NM db records claude-sonnet-5-5/anthropic; one sonnet PASS. Expect refuse (no-mistakes:anthropic uncovered)."
mkcase s5a $SHIP; db "$C/nm" known; rev PASS claude-sonnet-5-5 "$G_ANT"; ver "$C/nm"

hdr S5b-known-pipeline-two-families "same as S5a plus gemini PASS. Expect accept, NO fact."
rev PASS gemini-3-pro "$G_ANT"; ver "$C/nm"; ver "$C/nm" --json

hdr S6a-corrupt-db-one-reader "ship=$SHIP; NM state.sqlite exists but is corrupt; one sonnet PASS. Expect refuse, two-reader text, no single-reader offer."
mkcase s6a $SHIP; db "$C/nm" corrupt; rev PASS claude-sonnet-5-5 "$G_UNK"; ver "$C/nm"

hdr S6b-conflicting-provider-one-reader "ship=$SHIP; db claude-sonnet-5-5 with provider openai (conflict); one sonnet PASS. Expect refuse, two-reader text."
mkcase s6b $SHIP; db "$C/nm" conflict; rev PASS claude-sonnet-5-5 "$G_UNK"; ver "$C/nm"

hdr S6c-relative-nm-home-one-reader "ship=$SHIP; NM_HOME=relative path; one sonnet PASS. Expect refuse, two-reader text."
mkcase s6c $SHIP; rev PASS claude-sonnet-5-5 "$G_UNK"; (cd "$C/wt" && ver .no-mistakes)

hdr S7-absent-two-families "ship=$SHIP; absent NM; sonnet PASS + gemini PASS. Expect accept, NO fact."
mkcase s7 $SHIP; rev PASS claude-sonnet-5-5 "$G_UNK"; rev PASS gemini-3-pro "$G_UNK"; ver "$C/absent-nm"; ver "$C/absent-nm" --json

hdr S8-after-fail-relief-fact "ship=$SHIP; absent NM; gemini PASS, deepseek FAIL, then sole sonnet PASS. Expect accept + fact (pre-FAIL gemini must not hide it)."
mkcase s8 $SHIP; rev PASS gemini-3-pro "$G_UNK"; rev FAIL deepseek-v3 "$G_UNK"; rev PASS claude-sonnet-5-5 "$G_UNK"; ver "$C/absent-nm"; ver "$C/absent-nm" --json

hdr S8b-after-fail-only-preFAIL-outside-reader "ship=$SHIP; absent NM; sonnet PASS, gemini FAIL, then nothing. Expect refuse; after-FAIL text offers one outside-ship read."
mkcase s8b $SHIP; rev PASS claude-sonnet-5-5 "$G_UNK"; rev FAIL gemini-3-pro "$G_UNK" --covered-groups '["no-mistakes:unknown"]'; ver "$C/absent-nm"

hdr S9-stale-head "ship=$SHIP; absent NM; sonnet PASS at head, verify a different head. Expect refuse."
mkcase s9 $SHIP; rev PASS claude-sonnet-5-5 "$G_UNK"; gi "$C/wt" commit -q --allow-empty -m 'no-mistakes(review): later'; HEAD=$(gi "$C/wt" rev-parse HEAD); ver "$C/absent-nm"
