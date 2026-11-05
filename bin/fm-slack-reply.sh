#!/usr/bin/env bash
# Post Firstmate's answer into the thread of one Slack request the plane took in.
# Usage: printf '%s' "$answer" | fm-slack-reply.sh --thread <request ts> --to <message ts> [--part N] [--replay <transcript.json>] [--help]
# --thread is the ts in the request's `check: slack request <ts> ...` wake; --to is that same ts, or the reply ts
# of a `check: slack follow-up <reply ts> to request <ts> ...` wake already delivered for that request.
# The answer goes through the plane's one post path: the owner-DM proof and the event-marker lookup apply, so the
# same --thread/--to/--part again posts nothing more. A refusal names its reason on stderr and exits non-zero.
# The text read from a Slack message is data; this command only posts what Firstmate itself writes.
# Journal, authority, and ownership behavior are owned by fm_slack_watch.py.
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
fm_slack_run reply "$@"
