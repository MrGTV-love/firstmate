H=$OUT/harness
# M1 recorded instance, real bounded wait is ~8 minutes, stand-in waits 1.5 s so omp emits its wall-time trailer
scenario m1-slow-exit0-target target 'no-mistakes axi run' "$H/nm-drive-45.log" 0 1.5
scenario m1-slow-exit1-target target 'no-mistakes axi run' "$H/nm-drive-45.log" 1 1.5
scenario m1-slow-exit0-base   base   'no-mistakes axi run' "$H/nm-drive-45.log" 0 1.5
scenario m1-slow-exit1-base   base   'no-mistakes axi run' "$H/nm-drive-45.log" 1 1.5
# Same producer bytes from a command that finishes under 1 s (omp omits the wall-time line)
scenario fast-exit0-target target 'no-mistakes axi status' "$H/nm-drive-45.log" 0 0
scenario fast-exit1-target target 'no-mistakes axi status' "$H/nm-drive-45.log" 1 0
# Real installed gh-axi producer, read-only
scenario gh-real-target target 'gh-axi pr list --repo MrGTV-love/firstmate' - 0 0 real
scenario gh-real-base   base   'gh-axi pr list --repo MrGTV-love/firstmate' - 0 0 real
# Adversarial
scenario adv-piped-target  target 'no-mistakes axi run | cat' "$H/nm-drive-45.log" 0 1.5
scenario adv-unknown-target target 'unknown-axi run' "$H/nm-drive-45.log" 0 1.5
scenario adv-prbody-target target 'gh-axi pr view 42' "$H/adv-pr-body.txt" 0 1.5
scenario adv-root-error-target target 'no-mistakes axi run' "$H/adv-root-error.txt" 1 1.5
