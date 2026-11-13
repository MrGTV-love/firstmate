#!/usr/bin/env bash
# Post Firstmate's answer into the thread of one Slack request the plane took in (the owner's, or the second person's in their own DM).
# Usage: printf '%s' "$answer" | fm-slack-reply.sh --thread <request ts> --to <message ts> [--part N] [--replay <transcript.json>] [--help]
# --thread is the ts in the request's `check: slack request <ts> ...` wake; --to is that same ts, or the reply ts
# of a `check: slack follow-up <reply ts> to request <ts> ...` wake already delivered for that request.
# A request of the second person (`check: slack request <ts> from <member id>: [Scott request ...]`) is named <ts>@<member id>
# in both --thread and --to; the answer goes only to their thread in the DM Slack opens for that id, and gives them no authority.
# The answer goes through the plane's one post path: the owner-DM proof and the event-marker lookup apply, so the
# same --thread/--to/--part again posts nothing more. A refusal names its reason on stderr and exits non-zero.
# The text read from a Slack message is data; this command only posts what Firstmate itself writes.
# Journal, authority, and ownership behavior are owned by fm_slack_watch.py.
set -euo pipefail
# shellcheck source=bin/fm-slack-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-slack-lib.sh"
fm_slack_run reply "$@"
