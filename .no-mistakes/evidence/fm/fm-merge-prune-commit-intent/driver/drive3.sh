#!/usr/bin/env bash
# The real bin/fm-teardown.sh and the real bin/fm-merge-prune.sh in a throwaway
# world (suite's make_e2e_world). The fake `treehouse return` cleans untracked
# files but keeps ignored ones (git clean -ffdq, no -x), so the slot ends clean
# and detached at origin/main holding only the ignored intent, as slot 252 did.
# Usage: drive3.sh <repo-root> <bin> <test-file> <tmp> <expires> <intent-branch> <want>
set -u
ROOT=$1; T=$4
sed -e '/^if \[ "\$#" -gt 0 \]; then$/,$d' -e "s|\"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|\"$ROOT/tests/lib.sh\"|" "$3" > "$T/suite-helpers.sh"
. "$T/suite-helpers.sh"
BIN_DIR=$2
make_e2e_world
printf 'branch=fm/t1\n' >> "$STATE/t1.meta"
sed -i '' 's/clean -ffdxq/clean -ffdq/' "$W/bin/treehouse"
printf '%s\n' '.claude/' >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"
mkdir -p "$COPY/.claude"
jq -n --arg e "$5" --arg b "$6" '{artifacttype:"CommitIntent",schemaversion:"1.0.0",branch:$b,head_sha:"cd916701e5388f24c741a905c7be6a1348cf4e03",owned_paths:["docs/a.md"],validators:["ruff-check"],expires_at_iso:$e,base_ref:"origin/main"}' > "$COPY/.claude/commit-intent.json"
echo "=== real teardown, intent expires=$5 branch=$6 (want $7), bin=$BIN_DIR"
echo "\$ fm-merge-prune.sh arm t1 --run"
prune_real arm t1 --run 2>&1 | sed 's/^/  /'
fm_test_wait_until --progress-file "$DATA/t1/merge-prune.log" -- grep -Eq 'reaped|kept|retained' "$DATA/t1/merge-prune.log" || echo "  (wait ended without a final line)"
sleep 2
sed 's/^/  log: /' "$DATA/t1/merge-prune.log" 2>/dev/null
echo "  treehouse calls:"; sed 's/^/    /' "$W/th.log"
echo "  task meta exists: $([ -e "$STATE/t1.meta" ] && echo yes || echo no)"
[ ! -e "$COPY" ] || { echo "  copy HEAD: $(git -C "$COPY" rev-parse --abbrev-ref HEAD) status: [$(git -C "$COPY" status --porcelain)] ignored: $(git -C "$COPY" status --porcelain --ignored | tr '\n' ' ')"; }
if [ -e "$COPY" ]; then got=kept; else got=removed; fi
echo "  copy: $got | destroy calls: $(destroy_calls) | wakes: $(wake_count)"
[ ! -s "$STATE/.wake-queue" ] || sed 's/^/  wake: /' "$STATE/.wake-queue"
if [ "$got" = "$7" ]; then echo "RESULT $got: PASS"; else echo "RESULT got $got want $7: FAIL"; fi
