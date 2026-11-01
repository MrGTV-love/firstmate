#!/usr/bin/env bash
# Second pass with few runs at once, after the 25-run pass overloaded the host.
cd "/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6AKWSASHPZCERM1ZWF23AQD"
D="/Users/charlesabrooker/.no-mistakes/evidence/01M6AKWSASHPZCERM1ZWF23AQD/final-head-3e1a0ef7/driver/drive.sh"; R="/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6AKWSASHPZCERM1ZWF23AQD"; P="/Users/charlesabrooker/tmp/fm-tree-prefix-af9abab0"
"$D" "$R" "$P" quiet-prefix-latency9 'ok@arm@' 'latency:9@watch@200' 'ok@watch@60' &
"$D" "$R" "$R" quiet-after-latency9 'ok@arm@' 'latency:9@watch@200' 'ok@watch@60' &
"$D" "$R" "$P" quiet-prefix-latency6 'ok@arm@' 'latency:6@watch@150' 'ok@watch@60' &
"$D" "$R" "$R" quiet-after-latency6 'ok@arm@' 'latency:6@watch@150' 'ok@watch@60' &
"$D" "$R" "$R" quiet-after-steady-latency9 'ok@arm@' 'ok@watch@90' 'latency:9@watch@150' 'ok@watch@60' &
"$D" "$R" "$R" quiet-after-http500 'ok@arm@' 'ok@watch@90' 'http500@watch@90' 'http500@watch@60' 'ok@watch@90' 'http500@watch@90' &
"$D" "$R" "$R" quiet-after-hang-recovery 'ok@arm@' 'ok@watch@90' 'hang@watch@90' 'ok@watch@90' 'hang@watch@90' &
wait
