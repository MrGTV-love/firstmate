#!/usr/bin/env bash
# The exact scenario list for this evidence set.
cd "/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6AKWSASHPZCERM1ZWF23AQD"
D="/Users/charlesabrooker/.no-mistakes/evidence/01M6AKWSASHPZCERM1ZWF23AQD/final-head-af9abab0/driver/drive.sh"; R="/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6AKWSASHPZCERM1ZWF23AQD"; B="/Users/charlesabrooker/tmp/fm-before-tree-af9abab0"
"$D" "$R" "$B" before-slow-latency 'ok@arm@' 'latency:6@watch@120' &
"$D" "$R" "$B" before-starved-sigstop 'ok@arm@' 'stop:22@watch@90' &
"$D" "$R" "$R" after-slow-latency 'ok@arm@' 'latency:6@watch@170' 'ok@watch@40' &
"$D" "$R" "$R" after-starved-sigstop 'ok@arm@' 'stop:22@watch@90' 'ok@watch@40' &
"$D" "$R" "$R" after-hang-once-per-episode 'ok@arm@' 'ok@watch@30' 'hang@watch@60' 'hang@watch@45' 'ok@watch@30' 'hang@watch@60' 'ok@watch@30' &
"$D" "$R" "$R" after-hang-before-any-card 'ok@arm@' 'hang@watch@120' 'ok@watch@40' &
"$D" "$R" "$R" after-trickle-owner-bound 'ok@arm@' 'ok@watch@30' 'trickle@watch@200' 'trickle@watch@120' 'ok@watch@40' &
"$D" "$R" "$R" after-lost-post-reply 'ok@arm@' 'postlost@watch@60' 'ok@watch@40' &
"$D" "$R" "$R" after-request-over-timeout 'ok@arm@' 'ok@watch@30' 'latency:12@watch@60' 'ok@watch@30' &
"$D" "$R" "$R" after-http500 'ok@arm@' 'ok@watch@30' 'http500@watch@40' 'http500@watch@30' 'ok@watch@30' &
"$D" "$R" "$R" after-connection-reset 'ok@arm@' 'ok@watch@30' 'reset@watch@40' 'reset@watch@30' 'ok@watch@30' &
wait
