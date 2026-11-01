#!/usr/bin/env bash
# The exact scenario list for this evidence set. STEP = mode@action@bound.
cd "/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6AKWSASHPZCERM1ZWF23AQD"
D="/Users/charlesabrooker/.no-mistakes/evidence/01M6AKWSASHPZCERM1ZWF23AQD/final-head-3e1a0ef7/driver/drive.sh"; R="/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6AKWSASHPZCERM1ZWF23AQD"; B="/Users/charlesabrooker/tmp/fm-tree-base-ff15a3d5"; P="/Users/charlesabrooker/tmp/fm-tree-prefix-af9abab0"
"$D" "$R" "$B" before-starved-sigstop 'ok@arm@' 'stop:22@watch@90' &
"$D" "$R" "$B" before-slow-latency6 'ok@arm@' 'latency:6@watch@120' &
"$D" "$R" "$B" before-steady-latency9 'ok@arm@' 'ok@watch@30' 'latency:9@watch@90' 'ok@watch@30' &
"$D" "$R" "$P" prefix-af9abab0-latency9-run1 'ok@arm@' 'latency:9@watch@170' 'ok@watch@40' &
"$D" "$R" "$P" prefix-af9abab0-steady-latency9 'ok@arm@' 'ok@watch@30' 'latency:9@watch@90' 'ok@watch@30' &
"$D" "$R" "$R" after-starved-sigstop 'ok@arm@' 'stop:22@watch@90' 'ok@watch@40' &
"$D" "$R" "$R" after-latency1 'ok@arm@' 'latency:1@watch@60' 'ok@watch@30' &
"$D" "$R" "$R" after-latency3 'ok@arm@' 'latency:3@watch@90' 'ok@watch@30' &
for i in 1 2 3; do
  "$D" "$R" "$R" after-latency6-run$i 'ok@arm@' 'latency:6@watch@130' 'ok@watch@30' &
  "$D" "$R" "$R" after-latency9-run$i 'ok@arm@' 'latency:9@watch@170' 'ok@watch@30' &
done
"$D" "$R" "$R" after-steady-latency9 'ok@arm@' 'ok@watch@30' 'latency:9@watch@120' 'latency:9@watch@120' 'ok@watch@30' &
"$D" "$R" "$R" after-hang-once-per-episode 'ok@arm@' 'ok@watch@30' 'hang@watch@60' 'hang@watch@45' 'ok@watch@30' 'hang@watch@60' 'ok@watch@30' &
"$D" "$R" "$R" after-hang-before-any-card 'ok@arm@' 'hang@watch@120' 'ok@watch@40' &
"$D" "$R" "$R" after-request-over-timeout 'ok@arm@' 'ok@watch@30' 'latency:12@watch@60' 'ok@watch@30' &
"$D" "$R" "$R" after-trickle-owner-bound 'ok@arm@' 'ok@watch@30' 'trickle@watch@200' 'trickle@watch@120' 'ok@watch@40' &
"$D" "$R" "$R" after-finished-then-trickle 'ok@arm@' 'ok@watch@30' 'trickle-after:2@watch@200' 'ok@watch@40' &
FM_DURATION_ABSOLUTE_SECS=20 "$D" "$R" "$R" after-progressing-absolute-limit 'ok@arm@' 'latency:6@watch@90' 'ok@watch@60' &
"$D" "$R" "$R" after-lost-post-reply 'ok@arm@' 'postlost@watch@60' 'ok@watch@40' &
"$D" "$R" "$R" after-http500 'ok@arm@' 'ok@watch@30' 'http500@watch@40' 'http500@watch@30' 'ok@watch@30' &
"$D" "$R" "$R" after-connection-reset 'ok@arm@' 'ok@watch@30' 'reset@watch@40' 'reset@watch@30' 'ok@watch@30' &
"$D" "$R" "$R" after-hand-run-stderr 'ok@arm@' 'ok@mirror@' 'ok@poll@' 'ok@handcheck@' &
wait
