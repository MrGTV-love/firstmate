# CPU pass pool

The CPU pass pool is one host-wide budget for CPU-heavy test bursts.
A test script, a parallel test worker, a lint root, or a load test takes a pass before it runs and returns it when it ends.
When every pass is held, the next burst waits for one instead of adding to the run queue, and starts by itself when a holder ends.

Burst passes count CPU workers, not agents.
Fresh Firstmate-driven pipeline starts additionally queue through this same pool's start-admission owner, described below.
Interactive agents, lanes, sessions and existing-run reattachments do not request start admission.

This page owns the cross-repository protocol.
`bin/fm-cpu-pass.sh` is its reference implementation; the [`bin/fm-cpu-pass.py` header](../bin/fm-cpu-pass.py) owns command behavior, while `bin/fm-cpu-pass.sh --help` lists subcommands and each subcommand's `--help` lists its options.

## Why file locks

The pool uses Python's standard-library `fcntl.flock` over one lock file per pass, not GNU parallel's `sem`.
A kernel file lock is released when its last owning descriptor closes, including on `SIGKILL`.
Only the pool owner and a guard process it starts before the command retain slot descriptors; commands and their exec children never inherit them, so surviving worker descendants cannot hold a master's reservation after its command ends.
Ordinary termination signals keep that owner until its command exits, and the guard keeps the passes until the command process itself is gone even if the owner is killed with `SIGKILL`, so killing only the owner never frees a pass for a second worker; descendants that outlive the command hold nothing.
The guard exists, and has said it is ready, before the command does, so no moment exists in which a command runs and nothing but its starter holds the passes.
The command writes its own pid into the pipe the guard reads, between fork and exec, so the guard knows the command whatever happens to the owner or to the command's descriptors afterwards.
A guard that cannot be started, or dies before it is ready, returns the passes and the command runs without one, said once (rule 7).
The pool has no stale slot state to repair; `sem` keeps its own bookkeeping that must notice dead holders.
A token directory (rule 6) is a private temporary directory that its holder, or the holder's guard, removes when the command ends; a holder killed together with its guard leaves only that empty directory in the temporary directory.
`python3` is already a runtime dependency of Firstmate's runner and of the Python projects that will join the pool, so the pool adds no new install, while `sem` would add Perl-based GNU parallel and its citation prompt to every host and CI image.
Any language with `flock` can join the protocol below without calling a Firstmate script.

## Protocol

Every participant on a host follows these rules, so one pool is shared by every Firstmate home, worktree, and repository of the same user.

1. **Directory:** `FM_CPU_POOL_DIR` when set, else `$HOME/.cache/fm-cpu-pool`, created with mode `0700` and owned by the user.
2. **Size:** the host's logical CPU count (`os.cpu_count()`, which is `hw.ncpu` on macOS), with no environment override.
   Load average does not shrink the pool: it includes interactive sessions that never take passes, so a load-based gate would hold tests back indefinitely on a host whose baseline load comes from idle sessions.
3. **Passes:** pass `i` is an exclusive, non-blocking `flock` on `slot-<i>.lock` for `i` in `0..size-1`.
   The pool owner alone holds the close-on-exec slot descriptors until its direct command exits; descendants do not inherit reservation ownership.
   A holder may write one line into each slot it holds, `pid=<pid> passes=<k> since=<epoch> label=<text>`, for status display.
   Firstmate publishes that record as each slot is acquired, including while a request is still collecting passes.
4. **Turnstile:** a request first takes an exclusive `flock` on `turnstile.lock`, then collects slots until it holds all it asked for, keeping the slots it already holds, then releases the turnstile.
   Only the turnstile holder collects, so two multi-pass requests cannot deadlock and a large request is not starved by small ones.
   Both locks are polled with backoff; a request queues and never fails for lack of a pass.
5. **Count:** a request asks for exactly as many passes as the CPU-bound workers it will run (one for one test script, `W` for `pytest -n W`).
   Callers read `size` and use that same positive count for their workers and reservation; a count below one or above the pool size is a usage error and never starts work.
   This validation also applies to nested and degraded execution; without Python, oversized counts are refused when the host CPU count can be read using `sysctl` or `getconf`.
   `bin/fm-duration.py gate --passes N` follows the same rule (below one, above the pool size, or above a positive inherited count exits 125 and runs nothing), and a fresh gate takes the N passes it asks for.
6. **Nested work:** a holder exports `FM_CPU_PASS_HELD=<k>` to the work it runs.
   A participant that finds `FM_CPU_PASS_HELD` set runs without taking another pass, because taking another could deadlock a full pool.
   With a positive inherited count, nested work never runs more concurrent CPU-bound workers than that count; a caller needing parallel nested work reserves enough passes before starting the outer work.
   Firstmate's reference holder also exports `FM_CPU_PASS_TOKENS`, a private directory that is a mini pool of that many tokens: a participant that starts a CPU-bound worker under a positive count leases the worker's passes from those tokens and waits while sibling work holds them, so workers started by independent descendants, such as two runners started by one test script, together never exceed the count.
   The leased worker gets a token directory of exactly the leased count, so every level of nesting stays within what the outermost holder took.
   A same-key nested request, whose slot belongs to an ancestor, leases its tokens like any other: the slot exemption never makes CPU work free.
   A holder that exports only the marker (an outside participant, or a hand-set marker) cannot be leased from and is trusted; a participant that runs several nested workers at once then gives each its share of the count, the count divided by the workers and rounded down, never the whole count.
   An explicit pass request above a positive inherited count is a usage error; the [`fm-test-run.sh` header](../bin/fm-test-run.sh) owns the runner's concurrency-reduction behavior.
   The marker must be a nonnegative decimal integer in both Python and no-Python execution; a malformed marker is a usage error, while `0` denotes degraded work with no reservation or concurrency limit.
7. **Degrade, never block:** a participant that cannot use the pool (no `flock`, no pool directory, a foreign-owned directory) runs its work without a pass and says so once.
   Degradation notices use `--log-fd` (default stderr), separate from the work's stdout, including when Python is unavailable.
   A nested participant that cannot lease from its holder's tokens (no file locks, no Python) degrades the same way: it runs under the inherited marker and says so once, never with a traceback and never silently.
   The pool governs throughput; it is not a safety boundary, and a broken pool must not stop every test on the host.
8. **Waiting stays outside work bounds:** take passes before starting any per-test or per-worker timeout, so time spent queued never counts toward that timeout.
   A caller's own overall budget, such as a harness command limit, still includes the wait.
   For a fresh pipeline start, that limit ending the wait means no run was created; the recovery is the re-issue rule under Fresh pipeline starts, not a reattach.

## Calling it

From a shell, with Firstmate's `bin/` reachable:

```sh
workers=$(bin/fm-cpu-pass.sh size)
bin/fm-cpu-pass.sh run --passes "$workers" --label "my-suite" -- pytest -n "$workers"
bin/fm-cpu-pass.sh status
bin/fm-cpu-pass.sh size
```

A repository that cannot assume a Firstmate checkout implements the protocol directly with its language's `flock`, as rules 1-8 describe.
The [`bin/fm-test-run.sh` header](../bin/fm-test-run.sh) owns Firstmate's runner integration.

Firstmate's own heavy entry points take passes outside their timing and bounds; each script's header owns the details:

- `bin/fm-test-run.sh` takes one per executed script, and one for a whole `--check-coverage` scan.
- `bin/fm-duration.py run test.<key>`, the route the generated worker instructions name for an individual suite, takes one together with its per-key slot, before its clock.
- `bin/fm-lint.sh` takes one per cold ShellCheck root, one for the changed-root dependency scan and one for the backend-purity audit.
- `bin/fm-test-isolation-proof.sh` takes min(`--jobs`, candidates, pool size) for its whole run; its header owns how it counts and records concurrency.
- `.github/workflows/ci.yml` routes the long single-worker stock-bash tests (fleet snapshot view, bearings snapshot), the two guard-lint scans and the stock-Bash parse sweep through `bin/fm-cpu-pass.sh run`, so they are named in the runner machine's holder list.
- The pool's own concurrency proofs (`tests/fm-cpu-pass-concurrency.py`) run up to three CPU-bound processes at once, so CI runs them as their own job under `bin/fm-cpu-pass.sh run --passes 3`, and the fixture refuses a smaller held reservation.

A command that takes a per-key slot through `fm-duration.py gate` or `run` takes its pass in the same acquisition and waits holding neither ([configuration.md](configuration.md#test-slots-per-key-fm_test_key_slots)); inside a pass whose holder exported tokens it leases tokens in the same acquisition instead, so a process that took its slot through `gate` or `run` never waits for a pass or a lease while it holds that slot.
Waiting for a pass or a slot is by capacity alone: no elapsed time admits a waiter.

## Fresh pipeline starts

Before a Firstmate-driven fresh/new no-mistakes run, including an authorized rerun, the existing pool's `pipeline-start` owner reads the host's `~/.no-mistakes/state.sqlite` read-only and one host memory and process reading.
It has no option or environment variable that selects another database.
It never admits by load average; in measured mode it admits by the memory the counted runs are measured to need, not by a CPU-count ratio, and the [fallback](#fallback) below uses the count limit.
A counted run is a `runs` row with `status = 'running' AND ci_ready_at IS NULL AND awaiting_agent_since IS NULL`; both of those columns are facts the daemon records.
A CI-ready run that is only monitoring its PR, and a run parked waiting for its agent, are still `running` but are not counted.
A run that leaves `running`, reaches CI-ready or parks for its agent releases its count implicitly; no daemon-lifetime lease or watcher is installed.

### Admission rule

Subject to the one-start minimum and pause-only backstop below, the first waiter in class order is admitted when, in bytes:

```text
projected  <=  budget        where  budget = available_bytes + held
projected  =   the reservations of the counted runs  +  R per incomplete history (at least R per run created before activation)  +  S for the new run
```

| A counted run that is | reserves | why |
|---|---|---|
| waiting on remote CI: its open step is `ci` with status `running`, no launch-gate attempt of it is held, and no agent can be alive: no process of it is visible, and its recorded agent pid is absent or dead | only the resident memory it holds, which is 0 because no process of it is visible, plus the history charge below while its history is not shown complete | it uses memory again only when a fix round starts, and that agent starts only through the [launch gate](#launch-gate), which secures capacity first |
| waiting in its [launch gate](#launch-gate): a live launch-gate entry of it is queued in the pool and no launch-gate attempt of it is held, whatever its step or visibility | only the resident memory it holds, plus the history charge below while its history is not shown complete | its agent has not started, and it reserves capacity only when its gate is admitted |
| visible in the reading at any other step, or with a held launch-gate attempt | its resident memory or `A`, whichever is larger | startup memory alone is not its demand; memory above `A` is counted as it is, never capped at `R`, `S` or a recorded peak |
| not visible yet: just registered, between steps, with an unreadable step, or a launch-gate start the reading cannot see | `R` | the reading cannot show what it will use, so it is never read as idle |
| any of the above whose launch history is not shown complete | one more `R` beside its row's reservation, once per run; for a run created before activation, the larger of its row's reservation and `R` instead | an agent launch the gate did not record may still linger, and `R` is a whole run's measured peak |

| Symbol | Meaning | Source |
|---|---|---|
| `R` | one run's reservation while the reading cannot see it: the 75th percentile (nearest rank) of the per-run peak resident memory of recorded no-mistakes runs, leaving out runs still running that are not CI-ready yet, so their peak may still rise | `peak_bytes` of every `no-mistakes:` entry with at least 2 samples in the root home's `state/.memory-calibration.json`, written by `bin/fm-mem-guard.sh probe`, leaving out every run whose `runs` row is `status = 'running'` with `ci_ready_at IS NULL`, parked or not; CI-ready running runs are ranked |
| `S` | the new run, which may reach the largest peak recorded for any run | the largest peak of every such entry, running or not (a peak so far is a lower bound, so it never makes `S` too low) |
| `A` | the active-run term: the largest per-run concurrent demand of every run but the largest, `(sum - largest) / (count - 1)` over each error-free reading of this host and RAM size that saw at least 2 no-mistakes run trees, rounded up | the root home's `state/memory-readings.jsonl`, read-only and re-read when it changes |
| `available_bytes` | free, file-backed and purgeable pages, never compressed or swapped memory | one `bin/fm-mem-guard.py` `admission_sample()` reading: a waiting start may reuse one up to 2 s old, but each grant takes a new reading, with the process-count reading, so a signal that turns bad after a healthy read cannot admit |
| `held` | resident memory the counted runs hold now, summed over their process trees and never capped; a run the reading cannot see yet holds 0 | the same reading, keyed `no-mistakes:<repo_id>/<run id>` |

A counted run's resident memory appears in both `projected` and `budget`, so memory a run holds is never treated as free for new starts, and only the part of its reservation it does not hold yet must fit in `available_bytes`.
The open step is the highest-ordered `step_results` row in `running` or `fixing`, read with the run rows.
A run's launch history is shown complete only when the pool's activation record, `gate-activation.json` (`activated_at` in epoch seconds and `gate_sha256`, written once by [activation](#activation)), is dated before the run's `created_at`, every `agent_invocations` row of the run names a gated agent, and its rows and the gate's attempt records bind one to one by session key.
Every other run created after activation is charged one `R` for its history beside its demand while it is counted, queued or holds an attempt.
A run created before activation, every run while no activation record exists, is charged `max(demand, R)` instead, until it leaves the census.
Against the base rule, `(counted + 1) x R + S` against `available_bytes` plus each counted run's resident memory up to `R`, that interim charge is never stricter for a CI waiter, a run the reading cannot see, or a visible active run while `A` is at most `R` (measured: 1.82 against 5.77 GiB): each is charged no more beyond what it holds than the base rule's `R`, and the new run carries `S` without the base rule's extra `R`.
A counted run with no open step row is charged `R` beside what it holds, so for it the interim is stricter than the base by the smaller of `R` and its resident memory.
With no other counted run, one start is admitted even when the rule does not fit, a one-start minimum, so a large `S` or a low `available_bytes` never holds an idle host closed; the pause-only backstop below still pauses that start.
The admission and waiting lines print every input: the counted runs, each run's reservation and why (`reserved=[run:kind:bytes]`, `holding_only=[...]`, `:unseen` for a run the reading cannot see), the projection, the budget, `R`, `A`, `S` and the class.
The records belong to the host: they must name this host and its RAM size.
The owning home is `FM_HOME`, else the `FM_DURATION_HOME` that `bin/fm-spawn.sh` exports to workers, else the checkout holding the engine; a secondmate home reads its root home's records, found by `fm_firstmate_root_home` in `bin/fm-secondmate-parent-lib.sh`, the same walk the records' writer uses; a walk that fails takes the fallback below.

`R` and `S` are measurements, and taking the 75th percentile as `R` is a policy choice (Main 2473 ruling).
`A` is a measurement with no chosen margin: because `S` covers one run at the largest recorded peak, `k x A + S` is at least the summed run memory of every recorded reading with `k` runs, so the projection never falls below what the record measured in use together.
Measured on the root home's records of 2026-11-03 (373 readings, 347 of them with at least 2 runs): `A` is 1.82 GiB and `S` 13.39 GiB; the most run memory recorded at once was 20.1 GiB, with 10 and with 12 runs.
At 12 visible runs whose histories are all shown complete the projection is at least 12 x 1.82 + 13.39 = 35.2 GiB, against 88 GiB under the previous rule, which reserved `R` for every counted run at once; each of them whose history is not shown complete adds one `R`, or, created before activation, is charged at least `R`.
The replay of every recorded reading against both rules, including the only pressure-2 episode (2026-11-02 21:11Z to 22:44Z), is in the task's private evidence; the pressure hold refuses every reading of that episode, and the rule alone never projects below the run memory a reading measured.
The protection still has residuals: a run admitted just before pressure rises is not visible in the reading until it registers and grows, and an agent that raises its own memory after it starts is bounded by the next decision and the pressure hold, not by its reservation.
A CI run is released only on positive proof that no agent of it lives, never by what its processes are named or who their parent is: the daemon records an agent's pid at the agent's start and clears it at its exit, so a visible tree, whatever its recorded pid (a reparented agent can outlive its launcher's dead pid), or a live pid keeps the active term `A`.
A CI waiter whose worktree still holds a short daemon command or a leftover process therefore keeps `A` until that process ends; this errs toward holding.

Process count is not a reservation: a run's tree peaked at 34 processes against the host's 10,666 per-user cap, and every recorded pile-up was a runaway `bash` chain, not a run tree.
Processes appear only in the backstop below.

### Fallback

With fewer than 2 recorded runs left to rank for `R`, a calibration record for another host or RAM size, an unreadable calibration record, or no native memory facts on this platform, the start is admitted while `counted < max(1, floor(logical CPUs / 3))`.
No recorded reading of this host and RAM size with at least 2 runs for `A` is not a fallback: `A` is then `R`, so every visible active run counts at least `R`.
That is the previous count limit, kept only until the host has measured runs; a missing record never refuses a start and never reads as an empty host.

### Pause-only backstop

While either signal reports an actual overload, or cannot be read, no new start is admitted and a notice names the reason:

- the memory reading is unreadable or would make `bin/fm-mem-guard.sh admit` exit 75 (native pressure level 2 or higher, or a required fact unavailable; `admission_evaluate` returns the same list);
- `bin/fm-proc-guard.py` reports a pile-up (user process count above its fixed 60 % warning line of the host's per-user cap, a proc-guard constant) or cannot read the count or, on macOS, the per-user cap.

Nothing running is stopped, paused or reprioritised.
This backstop covers the tail the reservation does not: a run that grows past what it reserves, memory used outside the runs, and process pile-ups.
It only delays a start; a run database that cannot be opened at all, or an unreadable CPU count, still refuses with 125, and a failed read of a database that opens waits with a named reason.

### Launch gate

A run waiting on remote CI reserves only what it holds, beside its history charge, so its capacity is secured when its fix round resumes, before the fix agent starts.
`bin/fm-cpu-pass.sh launch-gate -- AGENT [ARGS...]` is the agent launcher's final exec: the daemon starts the launcher named by `agent_path_override` in `~/.no-mistakes/config.yaml` in the run worktree, and the launcher's last line `exec <firstmate>/bin/fm-cpu-pass.sh launch-gate -- <agent> "$@"` keeps the gate as the agent's parent.
The [engine header](../bin/fm-cpu-pass.py) owns its exact sequence, refusal text, hold bound and process hygiene; in short:

1. It maps its working directory to exactly one `runs.worktree_dir`; an unmapped or ambiguous directory or an unreadable database refuses, visibly.
   A directory that is no run's worktree but a registered repository's checkout (`repos.working_path`, the attach wizard) is no run's work, and its agent runs unchanged.
2. A step it cannot establish (step facts unreadable, no open step, an unrecognized step name) refuses.
   A counted run's launch at any step other than `ci` starts the agent at once, with no hold, because that run is already counted; its attempt record is still published under the start lock.
3. Every other launch, a `ci` launch or any launch of a run that is not counted, waits in this same class-ordered queue in class `other` and asks this same rule for one more active run, with its own run and every other run whose gate waits in the queue counted as waiters.
4. On admission it publishes the attempt's record, `attempt-<id>.json` in the pool, under the start lock, then starts the agent at once without waiting for it to appear in memory, then releases the lock.
   An attempt is held while a process of it is proven or possibly alive, and ends only when two successive censuses in one decision show none of them.
   Held records of one run that share one session key (a resumed session) are one attempt and are charged once; every other held attempt carries its own reservation.
   Every later decision counts a held attempt at `R` while it is invisible and at its resident memory or `A` afterwards.
5. It holds at most the daemon's per-invocation agent budget minus the 99th percentile of completed CI-fix invocation durations, and refuses at that bound, including a fit that comes only after a wait past it; a fit at the very first decision is admitted, so a bound of 0 holds not at all.

The gate also refuses when it cannot record the attempt before its agent runs (process facts unreadable) and when a first hold cannot write its wake (hold line not recorded).
A refusal exits 75 with one line naming the cause and the next action.
For a counted run at its `ci` step the daemon logs it as `warning: CI fix failed` and does not fail the run.
Each such refusal spends one of the run's `auto_fix.ci` attempts; after the last one the CI findings park as the ordinary ask-user decision, whose owner answers it once capacity has returned.
A run that is not counted reaches the hold bound only as a failed launch, and its run fails with it; its owner restarts the run once capacity has returned.
Every hold (the first time the gate is not admitted, whatever the cause: a decision that does not fit, a start ahead of it, or start-lock contention however short), admission after a hold and refusal also appends one check wake naming the run, the reason and the time waited to the root home's wake queue, the durable record supervision drains.
The gate never waits for the wake queue's lock: when another process holds it, the wake is spilled to the root home's `state/.wake-spill.<seq>`, and the next append to that queue, or the watcher's next start, replays it.
A spill is published by a hard link that never replaces an existing spill, so a gate's spill and the watcher's, or two gates', each keep their own file.
The live launcher is captain-private host configuration outside this repository: the gate protects nothing until that one line is applied, and a fix-round agent launched through any other path is not gated.

### Activation

`bin/fm-cpu-pass.sh activate --gate GATE_FILE` writes the pool's `gate-activation.json` once: `activated_at` (now, in epoch seconds) and `gate_sha256` (the sha256 of `GATE_FILE`, the gate file the launcher line names).
It writes through a temporary file in the pool directory, hard-linked into place, so it never replaces a record and activation never moves later.
It writes nothing and exits 1 with one `activate refused: <reason>` line when the record already exists, when `GATE_FILE` cannot be read, when the pool's waiters cannot be read, when a live waiter of the earlier engine (an entry with no `pid`) is queued (that waiter's owner re-issues its start first), or when the pool cannot be used or written.

Deployment is one operator step.
First apply the launcher line.
Then, immediately after it, run `bin/fm-cpu-pass.sh activate --gate <the gate file the launcher line names>`.
Then read the record with `cat ~/.cache/fm-cpu-pool/gate-activation.json` (or the pool directory `FM_CPU_POOL_DIR` names): it must be one JSON object with an integer `activated_at` at the time of the step and a 64-digit lowercase hexadecimal `gate_sha256` equal to `shasum -a 256` of that gate file.
Residual: each run created before activation is charged `max(demand, R)` until it leaves the census, so the admission the corrected reservation allows is reached only after those runs drain; until then admission is held to about the base rule's level, never stricter except as stated for a run with no open step row.

Queued classes are ordered `merge-train`, `machinery`, `vernant-build`, then `other`, with arrival order within each class.
Admission never preempts an already granted start or stops running work.
The short start lock covers each decision and the publication of its admitted start's pending reservation, then is released: every later decision counts an admitted start at the full `R` (and as one run in the count fallback and the one-start minimum), so simultaneous starts cannot spend the same observed headroom, a burst of ready starts is admitted back to back while the rule fits, with no spacing between them, and a start nested inside an admitted command never waits on its own enclosing start.
The one exception: a decision does not count a pending start while a run it counts as active (not CI-ready, not awaiting an agent) is on the repository and branch the start was bound to when it was admitted or claimed.
That run is the one the start's client drives or replaces, because the no-mistakes daemon keeps one active run per repository and branch: it cancels the old run and waits for it to end before it writes the new row, and a client with no `--launch-nonce` reattaches to the branch's active run.
A covered start adds nothing only when it is a proven reattach: `axi run` with no `--launch-nonce` whose recorded HEAD is the run's `head_sha` or `submitted_head_sha`.
A word of a real argument vector is never refused for its characters (`$`, a backtick, `*`, `?`, `[`, `~`, `{`); the pending start records where its arguments were read from: real arguments, a shell's command string, or an `env -S` string.
A start through `env -S` is never a proven reattach, whatever its words hold, because `env` reads the string with escapes (such as `\_`) and `${VAR}` that the admission does not read as `env` does.
Every other covered start (a `rerun`, a caller's own `--launch-nonce`, a HEAD that differs or is not known, a word read from a shell's command string that the shell expands later, which may hide a nonce) may replace the run, and that run's own charge can be far below `R`: a CI waiter is charged only what it holds.
So the branch then carries the larger of the covering run's demand and `R`, once per branch however many such starts it has.
The cost: while such a start's command runs, a run it only drives is charged `R` instead of the larger of its size and `A`, an overcharge and never an undercount.
The exact rule needs a launch identity in the no-mistakes fork.
Coverage is read again at every decision, so the start counts at `R` again in the gap between a replaced run's end and its replacement's row, and once the run is CI-ready, parked or ended.
A start with no binding (a directory that is no registered repository's, a detached HEAD) is covered by no run; its client starts no run there, so it is charged once, by its reservation.
A stale `running` row that an earlier daemon left, which no cancel reaches, also covers its branch's starts; it is charged as any counted run is (a CI waiter at what it holds), and a replacing start on its branch still makes the branch carry at least `R`.
A pending start ends when its command returns, or when the client that claimed it through the exec interception has exited.
A start nested inside an admitted command does not count that command's own pending start while it is unclaimed and no process in the command runs the admitted client (the client, called by its absolute path past the interception, ended without a run), so it never waits on capacity only its own command's end would free; and a pending start is not claimed when a run created since its admission covers no other start (it may be the first client's run), so that later client is decided as another start.
The [engine header](../bin/fm-cpu-pass.py) owns the coverage rule, failure behavior and the limit of read-only coordination with starts that bypass it.
Unusable run-database, CPU-count, memory or process observations do not imply an empty host.

A route that begins a new run in a form the parser below recognizes, or through the exec interception after it, joins this one queue, judged by the facts the no-mistakes CLI itself uses: `no-mistakes rerun` always creates a run, and `no-mistakes axi run` creates one only with an intent input (`--intent TEXT`, `--intent -`, `--intent-file PATH` or their `=` forms); without one it reattaches an active run or exits 2.
Only the executable position counts: leading `VAR=value` words, the wrappers `env`, `nice`, `nohup`, `command`, `exec`, `time` and `stdbuf` with their options (clustered short options, a valued option's attached or next word, `--option=value`), a Python interpreter or shell running a script, and the admission routes themselves are followed to the program they run, so `env A=1 /abs/path/no-mistakes axi run --intent ...` is a start and `printf no-mistakes axi run --intent ...` is not.
`env -S STRING` and `--split-string` read STRING's words, split as a shell splits a quoted line, in its place; `command -v` and `-V` only print a path, so they begin nothing.
A start through `env -C DIR` or `--chdir` is bound to the repository and branch of DIR, joined onto the admitting directory, not of the admitting directory.
A command the parser finds no start in still meets the exec interception: `bin/fm-mem-guard.sh run`, and `bin/fm-duration.py run` under any key, put a private directory first on the command's `PATH` holding one symlink named `no-mistakes` to `bin/fm-cpu-pass.sh`.
A `no-mistakes` the command reaches through `PATH`, however it is wrapped (`xargs`, `timeout`, an `env -S` string whose escapes or `${VAR}` hide the program name, a program name in a shell variable, a script), runs `fm-cpu-pass.py exec-intercept`, which judges the client's own arguments by the facts above, admits a new run once in the route's class, then runs the real client with that directory removed from `PATH`; reattachment and every other command pass straight through.
The directory is `fm-exec-intercept-<uid>-<checkout digest>` in the user's temporary directory, created 0700 and used only when this user owns it; when it cannot be made the route says why and holds the command as a fresh start in its class only when a word of the command names `no-mistakes` and the command is not the `no-mistakes` client itself judged no new run (a reattachment, response or status read); every other command runs at once.
An admitted command keeps the directory unless it runs the client directly (through `VAR=value` words, the transparent wrappers and the admission routes only), so each further fresh client inside it, in a shell line, a script or a background job, is admitted on its own; the admitted client itself claims its own pending start, matched by its arguments (a word the shell still expands, such as `"$X"`, matches what it becomes) and by the admitting process among its ancestors, and is not admitted twice.
Limit: a fresh start that no wrapper in this repository can see, the real client called by its absolute path past the interception, a wrapper that resets `PATH` (`sudo`, `env -i`), or a start made outside every route (a bare typed `no-mistakes axi run --intent ...`), is admitted only by admission at run creation inside the no-mistakes fork, backlog task `nm-run-creation-admission`.
A shell's `-c` string, after the shell's other options (`bash -l -c`, `bash -o pipefail -c`), is read as a command line without its comments and redirections, split at its control operators and newlines, so `cd x&&no-mistakes axi run --intent ...` is a start too.
`bin/fm-duration.py run` routes such a command through this owner before starting its execution clock; its `--pipeline-priority` option selects the class.
`bin/fm-mem-guard.sh run` hands its command to `pipeline-start --only-fresh` after its own memory reading: a new run queues in class `other`, and every other command runs unchanged.
Generated worker delivery instructions name both routes.
Existing-run reattachment, responses and status reads do not requeue, restart a run or consume another start.
Each recognized or intercepted start is admitted once, and a second fresh start inside an admitted command is admitted on its own.
Only the measured runner the owner re-executes skips a second admission, through an internal argument it consumes.
When the admitted start runs behind another route (for example `fm-duration.py run -- bash -c '... fm-mem-guard.sh run -- no-mistakes axi run --intent "$X"'`), that nested route finds the owner's pending start, with the same arguments and the owner among its ancestors, claims it and runs without queueing again; any other start, a second descendant, an identical invocation from elsewhere or one the wrapped client starts, is decided on its own with the owner's pending start counted.
A nested start that cannot prove that ancestry (one that detached to another parent, or an inner route on a checkout without pending starts) is decided on its own, with the owner's pending start counted, so it waits only for capacity, never on the owner.
Every route resolves the same pool directory from `HOME`, so every home and worker of one user shares one queue; a home whose checkout predates this route does not ask the queue at all until that home is updated.
A fresh-start call that ends - killed, timed out, or by its harness command limit - before it prints `fm-cpu-pass: pipeline-start admitted` was still queued and created no run.
Issue the same fresh start again the same way, through `bin/fm-duration.py run` or `bin/fm-mem-guard.sh run`, not a flagless reattach or a status read; the new request queues again from its own arrival time.
The admitted line proves only that the client was launched, not that a run exists, so after it the worker reattaches normally.
If that reattach refuses because no run is active and `no-mistakes axi status` shows no run created since the fresh-start call began, the start created no run and is issued again the same way; when status shows such a run, the worker reads its outcome and never starts another.
Admission adds no inherited CPU-worker budget, reduces no worker counts and serializes none of a task's required checks.
It is not start authority: explicit task admission, original intent and verification evidence, Test/Document and all other validation gates still apply.

The start gate does not use load average; post-deployment acceptance below still uses measured one-minute load p95, not a synthetic gate result.
Cross-project CPU-worker participation, including `vernant-cpu-pass-pool-participation`, remains a separate dependency.

## Phase 1 cutover

F6 is installed and live on this host since 2026-10-08 00:54 in the private no-mistakes build `v1.86.1-private.f6.20261008`.
Its gate overlay disables the omp advisor and eager sub-agents for pipeline agents only.
This change delivers the Firstmate side of Phase 1: the pool, `fm-test-run.sh` wiring, the cross-repository contract, and the measurement recipe.
Phase 1 completes only when the Vernant participant lands as a separate Vernant-repository change, tracked as backlog item `vernant-cpu-pass-pool-participation`, alongside this Firstmate change and the live F6 overlay.

## Judging the pool

`bin/fm-load-report.sh` records host load and reads pipeline agent durations; its [engine header](../bin/fm-load-report.py) owns the sample format and command behavior, while this recipe owns the measurement window and acceptance criteria.

1. Only once Phase 1 is complete, note the time with `date +%s` and start one recorder per host: `nohup bin/fm-proc-budget.sh -- bin/fm-load-report.sh watch --interval 60 >/dev/null 2>&1 &`.
2. After 24 to 48 hours of normal fleet work, run `bin/fm-proc-budget.sh -- bin/fm-load-report.sh report --since <that epoch>`.
3. Read its two verdicts: `load_within_2x_cpus` (1-minute load p95 at or under twice the CPU count) and `converged_within_2_fix_rounds` (the fixed first ten pipeline runs that reached review and were created after the recorded cutover epoch, ordered by creation time then run id, completed successfully with at most two review-fix rounds and none hit a timeout).
   Failed and cancelled cohort members count as not converged.
   The convergence verdict is pending (`null` in JSON, `pending` in text) until ten review-reaching runs exist and every pending or running run that sorts at or before the tenth member is terminal, including runs that have not reached review yet.
   Once those earlier runs are terminal, cohort membership and the true or false verdict are fixed; later-created runs do not change them.
   Its list of timeout-class run errors should be empty.
4. Stop the recorder when the window closes.
5. Compare per-purpose agent durations over a week and aggregate wall time with the pre-Phase-1 baseline; aggregate wall time must not worsen, review-fix time should be about 25 minutes, and post-merge defects must not rise.
   Neither report verdict measures post-merge defects or makes the before/after comparison automatically.
