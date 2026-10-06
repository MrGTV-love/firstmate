#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2;; --) shift; break;; *) exit 90;; esac; done
host=$1; entry=$2; shift 2
[ "$host" = localhost-lab ] && [ "$entry" = fm-remote-entrypoint.sh ] || exit 91
exec /usr/bin/ssh -p 65101 -i /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48YDAJ274FP0KSXR35TAEYY/.live-validation/remote/user -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48YDAJ274FP0KSXR35TAEYY/.live-validation/remote/known_hosts charlesabrooker@127.0.0.1 /usr/bin/env FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48YDAJ274FP0KSXR35TAEYY/.live-validation/remote/jobs /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M48YDAJ274FP0KSXR35TAEYY/.live-validation/remote/checkout/bin/fm-remote-entrypoint.sh "$@"
