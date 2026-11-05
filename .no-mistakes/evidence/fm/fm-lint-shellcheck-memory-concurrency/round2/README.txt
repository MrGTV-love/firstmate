Round 2 live validation at head 0812532f796594aa8f13ef742beb8234e0f27ab8, base 9c5874baa. ShellCheck 0.11.0.
live/four-home-standin.txt   four HOME values, stand-in, base and head
live/s2-larger-than-budget.txt root larger than the budget, killed waiter
live/kill.txt                 SIGKILL of a holder tree and of a top process
live/s3-unknown-unreadable-signal.txt unknown record, unreadable table, signalled gate, each with a control
live/s4-fast.txt              --fast record
live/s6-overbound.txt         over-bound root, stand-in and real ShellCheck (2 GiB); s6-overbound.512mib-both-attempts.txt keeps the 512 MiB try, where the narrower retry also crossed the bound and the lint exited 98
live/refusals.txt             every way to leave the bound or use failed state
live/s8-cache.txt             cache hit with the budget full
live/inventory.txt            --list-files and partitions, base vs head
live/diagnostics.txt          real diagnostics, base vs head
live/s12-retry-parity.txt     real memory retry, base vs head
live/s10-real-four-home.txt   real ShellCheck, four HOME values, default host pool, sampled
live/s11-outside-shellcheck.txt raw ShellCheck outside the lint holds a real lint back
live/s13-require-bounds.txt   enforced envelope switch on macOS, base vs head
live/s14-linux-envelope.txt   Linux container, CI posture, real ShellCheck
live/s14-linux-no-usr-bin-time.txt Linux container before /usr/bin/time was added: the memory budget case needs a record, and no record forms without /usr/bin/time
live/s15-worker-signal-linux.txt test_worker_trees_stop_on_signal fails in a container with no init on base and head alike (an orphan stays a zombie)
live/s16-slots-suite-linux.txt whole slots suite on Linux with --init and CI values
suites/fm-lint-slots.head.log whole slots suite on this macOS host through bin/fm-test-run.sh
drivers/                      the scripts that produced the above
