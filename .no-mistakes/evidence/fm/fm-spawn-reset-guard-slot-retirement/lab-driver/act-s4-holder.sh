# S4: ask the driver to start an unrelated process with its cwd in the slot.
touch "$FM_LAB_SCRATCH/.need-holder"
for _ in $(seq 1 60); do [ -e "$FM_LAB_SCRATCH/.holder-go" ] && break; sleep 0.5; done
ls "$FM_LAB_SCRATCH"
