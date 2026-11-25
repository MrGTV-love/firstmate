#!/usr/bin/env bash
# renew.sh [--owner-id x] [--base-sha s] <owned...>: the project's live renewal of the durable slot record.
set -eu
. "$FM_HOME/projects/ids.env"
owner=rrt base=$M1
while [ "$#" -gt 0 ]; do case "$1" in --owner-id) owner=$2; shift 2;; --base-sha) base=$2; shift 2;; *) break;; esac; done
args=(); for p in "$@"; do args+=(--owned-path "$p"); done
mv "$MAN" "$FM_HOME/projects/manifests/moved-aside.$RANDOM.json"
FM_TEST_PROVISION_CALLED=$SENT FM_TEST_SLOT_RECORD=$MAN python3 "$P/scripts/git-stability/provision_existing_slot.py" \
  --repo-root "$P" --worktree-path "$WT" --owner-id "$owner" --branch fm/rrt --base-sha "$base" "${args[@]}" >/dev/null
: > "$SENT"
echo "renewed: owner=$owner base=$base scope=$*"
