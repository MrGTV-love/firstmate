#!/usr/bin/env bash
# Live drive of bin/fm-tasks-axi.sh intake checks and closing proofs against a
# disposable marked lab home (bin/fm-lab-home.sh env) with real tasks-axi.
# Usage: drive-intake-and-close.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE FM_DURATION_FILE FM_DURATION_HOME; do unset "$v"; done
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
PEER=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-peer.XXXXXX")
trap 'bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME" "$PEER"' EXIT
W="$WT/bin/fm-tasks-axi.sh"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
echo "lab FM_HOME=$FM_HOME (marked lab home); tasks-axi $(tasks-axi --version)"

n=0
run() {  # <label> <expect ok|refused> <args...>
  local label=$1 expect=$2 out rc
  shift 2
  n=$((n+1))
  echo
  echo "=== [$n] $label"
  echo "\$ fm-tasks-axi.sh $*"
  out=$("$W" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'
  echo "    -> exit $rc"
  if [ "$expect" = ok ] && [ "$rc" -ne 0 ]; then echo "    !! UNEXPECTED: expected success"; fi
  if [ "$expect" = refused ] && [ "$rc" -eq 0 ]; then echo "    !! UNEXPECTED: expected refusal"; fi
}
show_state() { echo "--- backlog.md:"; sed 's/^/    /' "$FM_HOME/data/backlog.md"; echo "--- backlog-review.tsv:"; sed 's/^/    /' "$FM_HOME/data/backlog-review.tsv" 2>/dev/null || echo "    (absent)"; }

echo; echo "##### M2: objective link #####"
run "add with no --objective is refused" refused add lock-a "Lock holder crash" --kind ship --repo firstmate
run "add with unknown objective O9 is refused" refused add lock-a "Lock holder crash" --objective O9
run "add with --objective none and no reason is refused" refused add lock-a "Lock holder crash" --objective none
run "add with --objective O7 files the item" ok add lock-a "Lock holder crash" --objective O7 --kind ship --repo firstmate
run "add with --objective none + reason files the item" ok add paint-b "Repaint harbour signage colours" --objective none --objective-reason "fixture: no objective fits"
run "add with --mint and O6 files a minted id" ok add "Quarterly guard registry audit" --mint --objective O6
show_state

echo; echo "##### M1: duplicate check at intake #####"
run "overlapping title is refused, shows neighbours and both overrides" refused add lock-b "Lock holder crash recovery" --objective O7
run "unrelated title is filed with no prompt" ok add zebra-c "Migrate zebra telemetry exporter" --objective O3
run "--not-dup naming a non-neighbour is refused" refused add lock-b "Lock holder crash recovery" --objective O7 --not-dup zebra-c
run "--not-dup naming the listed neighbour files the item" ok add lock-b "Lock holder crash recovery" --objective O7 --not-dup lock-a
run "--dup-of appends to the kept item and files nothing" ok add lock-c "Lock holder crash on reboot" --objective O7 --body "seen again after a reboot" --dup-of lock-a
run "kept item shows the appended duplicate" ok show lock-a --full
grep -q 'lock-c' "$FM_HOME/data/backlog.md" && echo "    !! lock-c row was filed" || echo "    (lock-c has no row of its own: nothing filed)"
run "--backend value is not read as the title (id form): still refused at 0.75" refused add --backend markdown bid2 "Lock holder crash recovery" --objective O1
run "--backend value is not read as the title (--mint form)" refused add --backend markdown "Lock holder crash recovery" --mint --objective O1
run "a third overlapping title is refused again (env-var bypass attempts are in the part-2 transcript)" refused add lock-d "Lock holder crash watchdog" --objective O7
# A Done item pruned to the archive is still a neighbour
run "close a scratch docs item through tasks-axi path" ok add arch-a "Rotate kraken webhook secret" --objective O7 --kind docs
run "close it (non-ship row closes as before), prune to archive" ok done arch-a --note "rotated" --keep 0
echo "--- done-archive.md:"; sed 's/^/    /' "$FM_HOME/data/done-archive.md" 2>/dev/null
run "overlap with an archived Done item is still refused" refused add arch-b "Rotate kraken webhook secret again" --objective O7
run "--dup-of an archive-only item is refused with a pointer to --not-dup" refused add arch-b "Rotate kraken webhook secret again" --objective O7 --dup-of arch-a
show_state

echo; echo "##### M3: done --duplicate-of / --moved-to #####"
"$W" add dup-k "Kestrel cache warmer" --objective O7 --kind ship --repo firstmate >/dev/null 2>&1
"$W" add dup-x "Kestrel cache warmer startup" --objective O7 --kind ship --repo firstmate --body "duplicate body text" --not-dup dup-k >/dev/null 2>&1
run "done --duplicate-of closes a ship duplicate on proof, no PR, no owner words" ok done dup-x --duplicate-of dup-k
run "kept item now carries the duplicate's title/body" ok show dup-k --full
grep -n 'dup-x' "$FM_HOME/data/backlog.md" | sed 's/^/    /'
# kept item missing / closed
"$W" add dup-y "Kestrel cache warmer metrics" --objective O7 --not-dup dup-k >/dev/null 2>&1
run "--duplicate-of a missing kept item is refused" refused done dup-y --duplicate-of no-such-item
run "--duplicate-of a closed kept item is refused" refused done dup-y --duplicate-of dup-x
# owner-filed items
"$W" add own-a "Owner flagged heron queue" --objective O7 --body "Captain's words, 2026-10-20 (via /kun): keep this" >/dev/null 2>&1
"$W" add own-b "Owner dated heron queue drain" --objective O7 --body "Owner 2026-11-01: do this" --not-dup own-a >/dev/null 2>&1
run "owner-filed item (Captain's words) is refused for --duplicate-of" refused done own-a --duplicate-of dup-k
run "owner-filed item (Owner <date>:) is refused for --duplicate-of" refused done own-b --duplicate-of dup-k
# held for owner
"$W" add held-a "Pelican archive restore drill" --objective O7 >/dev/null 2>&1
echo; echo "\$ fm-captain-hold.sh hold held-a --reason 'which archive?'"
"$WT/bin/fm-captain-hold.sh" hold held-a --reason "which archive?" 2>&1 | sed 's/^/    /'
run "item held for the owner is refused for --duplicate-of" refused done held-a --duplicate-of dup-k
# live task
"$W" add live-a "Osprey shard rebalance" --objective O7 --kind ship --repo firstmate >/dev/null 2>&1
printf 'kind=ship\n' > "$FM_HOME/state/live-a.meta"
run "item with a live task record is refused for --duplicate-of" refused done live-a --duplicate-of dup-k
# blocks an open item
"$W" add blk-a "Walrus quota sync" --objective O7 >/dev/null 2>&1
"$W" add blk-b "Narwhal billing export" --objective O7 --blocked-by blk-a >/dev/null 2>&1
run "item that blocks an open item is refused and names it" refused done blk-a --duplicate-of dup-k
run "--duplicate-of with --pr together is refused" refused done blk-b --duplicate-of dup-k --pr https://github.com/o/r/pull/1

# moved-to
mkdir -p "$PEER/data" "$PEER/state"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$PEER/data/backlog.md"
tasks-axi add peer-open "Peer open item" --file "$PEER/data/backlog.md" >/dev/null
tasks-axi add peer-done "Peer done item" --file "$PEER/data/backlog.md" >/dev/null
tasks-axi done peer-done --file "$PEER/data/backlog.md" >/dev/null
printf -- '- sm-one - A local home (home: %s; scope: demo scope; projects: p; added 2026-11-01)\n' "$PEER" > "$FM_HOME/data/secondmates.md"
printf -- '- sm-self - This same home (home: %s; scope: alias; projects: q; added 2026-11-01)\n' "$FM_HOME" >> "$FM_HOME/data/secondmates.md"
"$W" add mov-a "Albatross ingest move" --objective O7 --kind ship --repo firstmate >/dev/null 2>&1
run "--moved-to an unregistered home is refused" refused done mov-a --moved-to sm-nope peer-open
run "--moved-to a registered home without that item is refused" refused done mov-a --moved-to sm-one peer-absent
run "--moved-to a registered home where the item is closed is refused" refused done mov-a --moved-to sm-one peer-done
run "--moved-to an alias of this same backlog is refused" refused done mov-a --moved-to sm-self dup-k
run "--moved-to owner-filed item is refused" refused done own-a --moved-to sm-one peer-open
run "--moved-to a registered home with the item open closes on proof" ok done mov-a --moved-to sm-one peer-open
grep -n 'mov-a' "$FM_HOME/data/backlog.md" | sed 's/^/    /'

echo; echo "##### M4: existing proofs unchanged #####"
"$W" add ship-z "Puffin deploy rewrite" --objective O7 --kind ship --repo firstmate >/dev/null 2>&1
"$W" add scout-z "Investigate gannet latency" --objective O7 --kind scout --repo firstmate >/dev/null 2>&1
run "ship row with no proof is refused (as before)" refused done ship-z
run "ship row with --note only is refused (as before)" refused done ship-z --note "done"
printf 'Drop it; the premise is gone.\n' > "$FM_HOME/words.txt"
run "ship row with --drop-file closes (as before)" ok done ship-z --drop-file "$FM_HOME/words.txt"
ls -l "$FM_HOME/data/ship-z/captain-drop.md" | sed 's/^/    /'
mkdir -p "$FM_HOME/data/scout-z"; printf '# Report\nfindings\n' > "$FM_HOME/data/scout-z/report.md"
run "scout row with --report closes (as before)" ok done scout-z --report data/scout-z/report.md
echo; echo "--- final backlog.md:"; sed 's/^/    /' "$FM_HOME/data/backlog.md"
echo "--- final backlog-review.tsv:"; sed 's/^/    /' "$FM_HOME/data/backlog-review.tsv"
echo "--- guard events (guard, decision, extra):"
jq -rc '[.guard, .decision, (.override // ""), (.cleared_by // "")] | @tsv' "$FM_HOME/state/guard-events.jsonl" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
