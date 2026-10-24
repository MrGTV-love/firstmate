H=$OUT/harness
# M1 recorded instance, slow (>=1 s, omp emits wall-time line)
scenario m1-slow-exit0-target target 'no-mistakes axi run' "$H/nm-drive-45.log" 0 1.5
scenario m1-slow-exit1-target target 'no-mistakes axi run' "$H/nm-drive-45.log" 1 1.5
scenario m1-slow-exit0-base   base   'no-mistakes axi run' "$H/nm-drive-45.log" 0 1.5
# Same producer bytes, sub-second (omp omits wall-time line) - round-1 defect
scenario fast-exit0-target target 'no-mistakes axi status' "$H/nm-drive-45.log" 0 0
scenario fast-exit1-target target 'no-mistakes axi status' "$H/nm-drive-45.log" 1 0
scenario fast-exit2-target target 'no-mistakes axi run' "$H/nm-drive-45.log" 2 0
scenario fast-exit0-base   base   'no-mistakes axi status' "$H/nm-drive-45.log" 0 0
# Real installed gh-axi producer, read-only
scenario gh-real-target target 'gh-axi pr list --repo MrGTV-love/firstmate' - 0 0 real
scenario gh-issue-real-target target 'gh-axi issue list --repo MrGTV-love/firstmate' - 0 0 real
scenario gh-real-base   base   'gh-axi pr list --repo MrGTV-love/firstmate' - 0 0 real
# Adversarial
scenario adv-piped-fast-target  target 'no-mistakes axi status | cat' "$H/nm-drive-45.log" 0 0
scenario adv-piped-slow-target  target 'no-mistakes axi run | cat' "$H/nm-drive-45.log" 0 1.5
scenario adv-unknown-fast-target target 'unknown-axi run' "$H/nm-drive-45.log" 0 0
scenario adv-prbody-fast-target target 'gh-axi pr view 42' "$H/adv-pr-body.txt" 0 0
scenario adv-prbody-slow-target target 'gh-axi pr view 42' "$H/adv-pr-body.txt" 0 1.5
scenario adv-root-error-fast-target target 'no-mistakes axi run' "$H/adv-root-error.txt" 1 0
scenario adv-forged-trailer-fast-target target 'no-mistakes axi status' "$H/adv-forged-trailer.txt" 0 0
