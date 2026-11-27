#!/bin/sh
PATH=<worktree>/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin; export PATH
eval "exec $SSH_ORIGINAL_COMMAND"
