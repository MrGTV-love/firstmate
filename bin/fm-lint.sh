#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Runs ShellCheck's default severity and extended, source-aware analysis with
# ambient configuration disabled and one maintained ShellCheck version.
# CI selects the complete canonical set; local branches select changed files,
# known transitive sourcing callers, and possible callers of unresolved imports.
# Every mode attempts --norc --external-sources and the same diagnostic rules.
# A root that hits the memory ceiling while following sources is retried once
# without --external-sources and with SC1091, SC2034, SC2153, and SC2329
# excluded (see the memory fallback in fm_lint_run_root); the roots log marks
# the retry, and CI still checks those codes on every source-following attempt.
# --fast remains an explicit local-only opt-out from extended dataflow.
# Selection retains the roots' source directives and call-site context; checking
# a library separately cannot replace joint source analysis.
# The default (no explicit-path) path also runs bin/fm-lint-workflows.sh so a
# malformed GitHub workflow, including a self-broken ci.yml, fails locally
# before merge instead of only failing to run as CI.
#
# The ShellCheck and actionlint versions are maintained pins, not a freeze.
# CI and --strict-version refuse a different local ShellCheck; an ordinary local
# run warns and proceeds so a newer local tool is not a wall. --strict-version
# also exits 2 on every host that is not macOS, where the per-root resident cap
# is not enforced. --check-version
# compares both pins with the latest upstream releases (exit 0 current, 1
# behind, 2 unknown) so a bump is routine rather than discovered by a failure.
#
# With no explicit paths, the file set depends on context:
#   - In CI (GITHUB_ACTIONS=true or CI=true), on the main branch, or when no
#     merge-base against origin/main (or local main) can be found, it lints
#     the full canonical set: bin/*.sh bin/backends/*.sh tests/*.sh, with
#     --external-sources and full dataflow first. CI coverage never depends
#     on a local diff; memory failures may take the narrower retry below.
#   - Otherwise it selects canonical roots whose transitive source closure
#     contains a path changed since the merge-base, including staged, unstaged,
#     untracked, deleted and renamed paths. An unchanged imported library is not
#     a separate root; its callers analyze it through their sources. Runtime
#     backend imports participate in selection even when their static source
#     annotations intentionally isolate adapter analysis.
#     Unresolved runtime imports select possible callers on changed/deleted shell
#     or known source inputs, regardless of annotations.
#     Discovery recognizes source/. command words, balanced substitutions, and
#     executable bash/sh -c and program-stdin heredocs. Source annotations remain
#     inputs; ordinary comments, inert quoted programs, and heredoc data do not.
#     Quoted child positional arguments are resolved; <<- strips leading tabs.
#     Changes to bin/fm-lint.sh or bin/fm-lint-cache.pl select all. An empty
#     set skips ShellCheck but still checks backend purity and workflows. A
#     changed widely sourced library still costs a source-aware analysis of
#     every caller.
# Explicit paths bypass changed-file selection and are linted as given, without
# the workflow YAML check.
# Explicit core bin/ and bin/backends/ scripts still receive the
# backend-purity check. The backend-purity check rejects direct Beads CLI
# invocations in the core bin/ and bin/backends/ scripts so every configured
# backlog backend follows the same tasks-axi lifecycle path.
# No analysis result is reused between or within runs: every root a run starts is
# analysed by ShellCheck. A run that refuses or stops (a pool or table refusal, an
# abort mark, a version refusal) starts no further root, and --list-files starts
# none. No sampled reading can prove which ShellCheck a launcher at the resolved
# path runs for an analysis, and a success reused for another ShellCheck could hide
# a diagnostic, so the analysis cache was removed until a non-sampled proof exists.
# FM_LINT_CACHE_DIR is no longer read; files an earlier version left in
# ${XDG_CACHE_HOME:-$HOME/.cache}/firstmate/lint are unused and may be removed by hand.
#
# Dependency selection is a private Perl helper using the Perl runtime already
# required for worker cleanup; no extra tool is installed.
# Lint defaults to two concurrency-limited workers over two stable logical
# shards, and each worker runs ONE canonical root per ShellCheck process, so a
# run holds at most JOBS concurrent ShellCheck processes. Diagnostics replay
# in stable shard/root order. FM_LINT_JOBS=1 changes concurrency, not diagnostics
# or exit selection.
# That bound is per run; every root enters the host-wide pool. Roots share the
# pool per lint run, not
# per worker: a free slot goes to the waiting run holding the fewest slots, then
# the run served least recently, so a two-worker run cannot take two turns for
# each turn of a one-worker run. Within a run, roots stay FIFO and newer roots
# cannot bypass an older one. Killed waiters, and waiters stopped for a second
# while a slot sits free, are skipped automatically. After an update to this
# gate merges, restart in-flight lints that still run the older code.
# The pool bounds the total resident memory T of the ShellCheck processes this
# script starts, host-wide, in bytes. The budget is fixed: 3670016 KiB = 3.5 GiB =
# 3758096384 bytes, the value Main recorded on 2026-11-06. No environment variable
# or flag sets it (FM_LINT_HOST_RSS_KIB is refused by name), this script is the
# only place that holds the number, and it is printed as the host_memory_budget_kib
# line of the roots log. Inside it the version probe has a lane of its own,
# PROBE_RESERVE_KIB = 65536 KiB (one probe at a time on the host), and the roots'
# admission works with the rest, ROOTS_RSS_KIB = 3604480 KiB; the total stays
# 3670016 KiB. The two parts sum to B only while the probe holds at most 64 MiB.
# That is measured for the real `shellcheck --version` (about 15 MB, for the
# time noted at PROBE_BOUND_SECONDS) and enforced only by the macOS resident
# watch, from its first sample one second after the probe starts; a probe that
# holds more than 64 MiB under the enforced envelope,
# or before that first sample, can put the total above B by its excess (for example
# 64 MiB over B for a 128 MiB probe). That gap is arithmetic, not a measurement:
# no probe above 64 MiB has been measured; it is stated, not claimed closed. Tests get no seam either: a test uses a private
# FM_LINT_SLOT_DIR pool, and a test that starts ShellCheck counts against this same
# host-wide budget and may queue on it.
# T is at most the budget at the moment a root is admitted, and the bound it keeps
# afterwards is stated exactly under "THE BOUND THIS GIVES" below (it is not "at
# most the budget at every moment"). A root larger than the budget runs alone and
# is ended at the per-root cap
# (FM_LINT_ROOT_RSS_KIB, default 8388608 KiB = 8 GiB; a larger value is clamped
# to that default, and stderr and the roots log name the requested and the applied
# value). R, the residual host total of one lone root, is the contract's
# constant: R = 10353888 KiB = 10602381312 bytes. No code path compares a root
# with R or with H_cal; a lone root is held only by the per-root cap above. H_cal,
# the host memory calibration Main recorded (Main 1566/1572), is that cap plus the
# watch's sampling overshoot measured in this repository's runs: H_cal = 11227136
# KiB = 11496587264 bytes (10.71 GiB), the largest peak of any root in those runs
# (10948657152 bytes, tests/fm-launch-prompt-signals-live-e2e.test.sh, in the
# after-run of head f61015af on 2026-11-07, evidence m2) times 1.05, rounded up to
# a whole MiB. The peak is the watch's own reading, the larger of resident size and
# physical footprint of the root's whole tree, which is the figure the watch
# compares with the cap and writes to the roots log; the per-process sampler read
# 10685235200 bytes for the same root. The watch is not tightened to end a root
# that needs that memory.
# Measured basis (this repository's real full lint, sampled every 0.25 s, each
# ShellCheck process attributed to its lint run by its parent chain). These are
# figures of earlier runs, none of the delivered head:
#   the before-run at base 37a733cba (2026-11-07T07:03Z, evidence m2) peaked at
#   T = 13.31 GiB (14287716352 bytes) with two roots, above the budget;
#   the real pair at head f61015af (2026-11-07T08:45Z, evidence m3/real-pair) had
#   at most 3.05 GiB (3271426048 bytes) with two roots, and no sample above the
#   budget;
#   the smallest ShellCheck total among the memory-pressure level 2 readings of
#   the readings snapshot of 2026-11-15T18:16:26Z (3207 lines of
#   state/memory-readings.jsonl; processes among the ten largest) is 676.5 MiB =
#   692704 KiB (2026-11-08T16:23:52Z, 1 process), below the budget; the 52 such
#   readings hold 0.66 to 17.35 GiB of ShellCheck.
# An unrecorded root is charged more than that budget (the 8 GiB watch bound
# below), so with no history each root runs alone, and recorded roots share the
# budget.
# Each root is charged its own recorded peak times 1.10 plus 64 MiB (at most the
# per-root worst case below), the peak being the larger of resident size and
# physical footprint over its earlier complete analyses, kept per analysis mode
# (full or fast) and repo-relative root path in the pool's history/ directory
# together with the input size that peak was measured on: the root file plus
# every file the analysis follows, as the dependency walk finds them.
# The history lives in the pool, the one directory every run of this user shares.
# A record is trusted only when the root's input now is more than 90 and less
# than 110 percent of the input it was measured on. A root with no record, a
# record in another format (records written before input sizes were kept
# included) or an input outside that band is charged the per-root worst case
# (the 8 GiB resident watch bound, or the address-space limit under the enforced
# envelope). The cost: a root whose input changed by more than 10 percent runs
# once on the worst-case charge, so the first lint after an edit that big runs
# such roots one at a time.
# A cold root takes its turn only when its charge and every held root's current
# charge (every root admitted on this host, in any pool: the host-wide ledger
# below) together fit the budget; a held root's current charge is the larger
# of its charge at admission and what its tree holds now, read when the root
# asks for its turn. That reading is the live process table (resident size
# only, from ps or libproc) and, where the macOS watch runs, the watch's own
# peak of resident size and footprint. A held root is charged the worst case
# when its record names no charge. A root waiting for its turn reads that table
# at most every 0.5 s, before it takes the host lock, and reuses the reading until
# the next read; the ledger and the slot charges are read fresh on every pass under
# the host lock. Admission
# needs that table: while neither ps
# nor bin/fm-proc-info.py (its table and memory commands) can read it, no root
# is admitted in any pool. This script reads that table once, before any root
# starts, and exits 2 naming the host process table, ps and fm-proc-info.py and
# the fix after about 5 s if it cannot; a table lost while the run is under way
# makes the root whose turn it is wait about 5 s and exit 2 the same way, and
# that refusal stops both workers from starting any further root, so the run
# does not spend 5 s on every root or hold the head of the shared queue. The
# version probe (`shellcheck --version`, once per lint in every mode except
# --list-files) is a ShellCheck start too. Every run probes (no version is kept
# between runs: nothing proves which ShellCheck a script or a compiled launcher
# runs), in the probe's own lane of the budget above: one probe at a time on the
# host, held to 64 MiB by the resident watch on native macOS (it holds about
# 15 MB, for the time noted at PROBE_BOUND_SECONDS); under the enforced
# envelope the probe is held only to the per-root address-space limit, not to
# 64 MiB, and on another host without the envelope nothing holds it (see the
# non-macOS rule below). It is never queued
# behind roots, so a run with no root to analyse reserves nothing in the
# roots' budget; the probe's own bounded wait for its lane is the one wait such a
# run has, an allowed wait inside B (Main 1775). Every run probes its own ShellCheck:
# no run takes another run's answer. The roots log's probe_wait_ms meta line records
# the wait for the lane. The lane is a record naming the probe by its exact
# identity, and it frees only when that probe has provably ended (its pid is gone,
# or holds another start time), never because the run that started it or any
# descriptor died; a probe that runs past its bound
# (PROBE_BOUND_SECONDS, 30 s) is never ended, and it and every run waiting that
# long report "blocked" on stderr and keep waiting. With nothing held, one root
# is always admitted, so a root larger than the budget runs alone, and queued
# roots wait rather than fail. THE BOUND COVERS GOVERNED ROOTS ONLY (Main 4257,
# option C): the ShellCheck this script starts, through a gate that the ledger
# names. Memory no ledger entry governs (another caller's ShellCheck, a lint run
# from a checkout without the ledger) is neither counted against the budget nor
# ever the reason a governed root waits or is held: counting it let other runs'
# use starve this one (Main 4252). That residual is owned by the host memory
# guard (bin/fm-mem-guard.sh), which reads host memory pressure when a
# no-mistakes run is admitted. When a root's analysis completes, a record whose input
# is in the band above is raised to the peak this run measured (the watch's
# peak and /usr/bin/time's maximum resident size) if that is higher, keeping
# its input size, and is never lowered, so the narrower memory retry, which
# reads the same input, cannot shrink it; any other record is replaced by that
# peak and the input size now. Complete means its
# gate caught no signal and the analysis exited 0 or 1 (clean or findings), 98
# (ended by the watch at its bound) or 251 (GHC heap exhaustion); a signal, a
# deadline, a gate ended by KILL or any other end raises no record. Without
# /usr/bin/time and the macOS watch no record forms, so every root stays
# charged the worst case. Because a record is trusted only for the input it
# was measured on, the sum of the charges is at most the budget at every admission.
# THE BOUND THIS GIVES, stated exactly (Main 1566, Design A; Main 1572): only
# the charges taken at admission bound T, and only at admission, where T is at
# most the budget; nothing after admission guarantees R or H_cal. Afterwards, T is at
# most the budget plus the sum, over
# the running roots, of (actual peak minus charge) where that is positive, each
# root being ended at the 8 GiB per-root cap (plus the watch's sampling overshoot,
# H_cal above). The 10 percent and 64 MiB margin covers the 8.5 percent run-to-run
# variation of one root's peak measured in this repository's runs (largest ratio
# 1.085 over 463 common roots, 0 of 2632 samples with two or more roots above the
# budget); it is not a proof for a root that grows past it. The ceiling of that
# expression is not R or H_cal: roots that all grow from their charges to the 8 GiB cap
# together could hold the number of admitted roots times 8 GiB (an algebraic
# ceiling, never measured here: with this host's 41 roots admissible at once it
# is 352262914048 bytes, about 328 GiB. It is unmeasured, so no ceiling is
# claimed (Main 1770)).
# A strict byte bound at
# every moment is not available on this host without a kernel limit or killing
# and re-running a grown root (a design Main withdrew), and SIGSTOP releases
# nothing. The residual is a root that grows beyond its charge (analysis noise,
# or a file it follows that the dependency walk does not see), so each gate also
# watches the host
# while its root runs: while the running governed roots (its own and every gate
# the ledger names, in any pool) hold more than the budget, a
# gate holds its own root unless it belongs to the oldest running governed gate (it writes
# <peak file>.hold, and the root's resident watch stops the root's process group
# with SIGSTOP; no process of the root is signalled by its pid), and releases it once the total
# fits again or its gate is the oldest. A root on a host without the resident
# watch is not held. A stopped root keeps what it holds but cannot grow
# further, and the oldest running governed gate is never stopped, so its growth is
# bounded by the per-root bounds below and every root still finishes. No
# polling guard can remove what roots grow inside one reading interval (up to
# 2 s at or below 60 percent of the budget, 0.5 s above it); the trusted
# charge, not the guard, is what keeps the total within the budget.
# The time a root spends stopped counts toward
# its deadline. The guard learns which gates are governed by listing the ledger
# directory by name only; a ledger it cannot list governs no other gate, so the
# guard counts its own root alone and says so once on stderr naming the path
# (admission, which reads the same ledger under the host lock, refuses every
# new root while it cannot; see below).
# The oldest is judged by each process's absolute start time (ps lstart), ties
# broken by pid, so every gate names the same one. A gate reads the host every
# 0.5 s while its last reading was above 60 percent of the budget and every 2 s
# otherwise, starting 0.5 s after its root starts, and not at all while it holds
# no root (waiting for admission, or after its root ends). Measured on the Studio
# (18 CPUs, about 1,520 processes), with /usr/bin/time -p around one gate whose
# command is sleep, less the same gate around sleep 0: about 0.10 s of CPU per
# reading (ps included), so about 0.05 of a core per gate at the 2 s rate
# (3.06 s in 60 s) and about 0.20 of a core at the 0.5 s rate (6.1 s in 30 s);
# a lone two-worker run below 60 percent spends about 0.1 of a core on it.
# A lone default two-worker run keeps both workers only while
# both roots' charges fit the budget: on a pool with
# no history it runs one root at a time until its roots are recorded, and two
# recorded roots of 7.2 GiB each (14.4 GiB) also run one at a time.
# Admission also needs a free slot among the count cap; fairness does not
# increase host concurrency.
# The default pool is /var/tmp/firstmate-lint-<uid>/lint-slots, which does not
# depend on HOME or XDG_CACHE_HOME, so every run of one user on a host meets in
# one pool and one count cap. Every analysis, the real ShellCheck or not, goes
# through this shared admission, and no setting opts out: FM_LINT_SLOT_DIR=off
# is refused (exit 2). FM_LINT_SLOT_DIR set to another directory is only a
# fixture seam for tests: that run keeps its own queue, count cap and history,
# and shares the one host-wide ledger of charges below, so it is bounded host-wide
# like every other pool. Every pool's admission decisions take one lock,
# /var/tmp/firstmate-lint-<uid>/admission.lock beside the default pool, for the
# reading they decide on, and an admitted gate keeps it until its root's command
# has started, so two pools never admit on one reading and each sees the
# other's started roots. They also share one ledger beside that lock,
# /var/tmp/firstmate-lint-<uid>/admission.lock.ledger/ (one path, independent of
# any pool directory): an admitted gate writes its charge there under the lock
# and keeps the entry's flock through its command, and every admission, in any
# pool, charges every live entry what it names (or what the root holds now, if
# more), so a root just admitted in another pool counts at its charge and not at
# the few MiB it holds in the instant of the reading. The ledger is read only while
# the host lock is held, immediately before the decision taken on it; a gate that
# cannot take the lock waits, and no path decides without it. A live entry that
# cannot be opened or read is a charge the gate cannot account for: the gate
# refuses (exit 2) and names it. The pool, the lock and the ledger are per user
# (the shell's UID), and the bound applies to the runs of one UID only: a lint run
# by another OS user on the same host keeps its own and is not counted here.
# That is a residual; no cross-UID bound is claimed. A held slot of the deciding
# gate's own pool whose gate predates the ledger is still counted through its slot
# file and its gate's tree; another pool's such gates are not counted (above). Each lint
# run also writes a run entry there (run.<pid>.<time>, held for the run's life)
# naming the perl and python it resolved, its bound mechanism and its per-root
# address-space and resident limits; the private modes this script runs for its
# own roots (--internal-worker, --internal-timed, --internal-root) take those
# values from a live run entry and an admitted gate entry in this ledger, whose
# owners are their ancestors, and from no setting or inherited variable, or exit 2
# and start nothing. Residual: a process of the same user that writes a forged
# entry into the 0700 ledger directory, naming a checker of its choice, is not
# refused; such an actor is outside the confused-agent threat model this guards. Host load
# average never changes admission, so unrelated machine load cannot starve lint.
# FM_LINT_HOST_SLOTS sets the count cap; unset or empty uses max(2, floor(ncpu/2)).
# A nonempty FM_LINT_HOST_SLOTS must be a positive decimal integer without
# leading zeros, or lint exits 2; a nonempty FM_LINT_HOST_RSS_KIB exits 2. The per-root address-space limit is enforced only where ulimit -v works, and
# native macOS cannot enforce it.
# Each cold root also takes one pass from the host-wide CPU pass pool before its host
# slot (docs/cpu-pass-pool.md). That pool bounds CPU only. It is separate from the
# memory budget above and never reads it. A lone default two-worker run also needs
# the CPU pool to have at least two passes and no explicit cap of one.
# The CPU-derived default keeps the memory protection of the original pool (some
# ShellChecks reach several GB).
# On native macOS, where the enforced envelope below does not apply, each root's
# process tree (the root, its descendants in any process group, and each process
# the watch saw in the tree that was later orphaned) is instead watched for
# memory, the larger of its resident size
# and its physical footprint (FM_LINT_ROOT_RSS_KIB, default 8388608 = 8 GiB, a
# positive decimal integer or lint exits 2 on every host; a value above the default
# is clamped to it). A root that crosses
# it is ended and takes the memory retry described below, and the roots log's
# last end-record column counts the libproc reader's samples and names any
# attempt that gave up its reader, with the reason; the reader is the only source
# of a sample, and a tick it cannot answer is a miss. Each reply has 6 s; a late or
# unconfirmed reply is read once more in the same tick (at most 1 s more) before it
# is a miss, so a reply is late only after 7 s; no other source and no older sample
# is used. As measurement only, each missed tick's
# rss_miss=<branch>,wait_ms=<n>,interrupted=<n> record is printed on stderr with its
# root's path, and at exit one stderr line names the largest rss_longest_reply_ms
# and rss_longest_tick_ms of the run's roots, with the root of each (none when no
# root recorded a tick). The root is never signalled
# by its pid or by a group taken from input: the watch records its root's exact
# start time before the root executes and signals only that root's group, after
# proving the group's leader unchanged (to end it, or to stop and resume it while
# the growth guard holds it), and acts on every signal result. Three own-child
# signals stay by pid: the gate and the check helper forward TERM to their own
# unreaped child when they are signalled, as on the base; and the watch ends its own
# memory reader with KILL, which this change keeps but narrows (the base killed the
# reader at once when it stopped it; now only a reader still running 2 s after its
# input closed is killed). A counted process that
# still runs after its root has ended, a normal success included, fails the root
# (status 96), stops new admissions, and is named in the roots log's samples column
# as escaped. Each reader reply is bound to the processes it measured: every member
# it names is read again after it, and an identity that differs, cannot be read or
# has ended, or a zombie or exiting root, makes the sample unknown. A member outside the root's
# group and its descendants (one that left and was orphaned) is counted only when
# two libproc reads give exactly its recorded start time, and a child of it only with
# the identity the same census listed it under that member; a replacement, a
# recycled pid, or any identity or memory that cannot be read makes the sample
# unknown, never counted or adopted. Any missed sample while the root runs that is
# followed by a later tick fails that root unless it is rerun alone (below) (status
# 96, reason unmeasured; only a miss on its very last tick, its own exit, is exempt;
# each tick first reaps an exited root, so its exit is not sampled as misses), even
# if it later crosses the cap: 96 comes before 98, so no memory retry follows and no
# success is recorded.
# THE ALONE RERUN (Main 4343, 4351). When that unmeasured interval is the root's
# only failure (its readers stayed up, no reading was over its cap, its owner did
# not signal it, and every process it counted was proven ended: the watch then
# writes rss_rerun_alone=1), the root's result is not used, it does not stop the
# run (the other roots keep being admitted), and it is queued (reason
# rerun-queued). After every other root of the run has ended, each queued root runs
# once more, one at a time with no other root of the run beside it, under the same
# gate, watch, cap and memory retry. It passes only when that rerun is measured all
# through and stays under its cap; a rerun unmeasured again fails (96), one
# measured over its cap fails as over its cap (98, or its narrower retry's own
# result), and no root runs a third time. Every other 96 (three misses in a row, a
# reader given up, a reading over the cap, a survivor, a lost signal, a launch not
# recorded, a queue that cannot be written) still fails its root at once and stops
# the run: no further root starts, queued roots do not run again and fail (96), and
# the run names each root it did not start. Every gate on the host admits a
# new root when the charges fit the budget and no live ledger entry is unreadable;
# it does not wait for a watched root's sample, because a held root is never
# counted below its charge (Main 4065).
# Linux runs are never watched (the accepted no-cap limit; the run's warning says
# admission counts them by charge only), and CI
# runs under FM_LINT_REQUIRE_BOUNDS=1 keep their ulimit envelope.
# ShellCheck started outside this script (an agent or a test running it
# directly) holds no slot and is not bounded by the pool; no admission counts it,
# and it is never the reason a governed root waits or is held (option C above):
# the host memory guard (bin/fm-mem-guard.sh) owns it.
# A cold root takes one pass of the host-wide CPU pool before its host slot
# (bin/fm-cpu-pass.sh; docs/cpu-pass-pool.md owns the protocol), so ShellChecks and
# test scripts together never exceed the pool. The changed-root dependency scan and
# the backend-purity audit take one pass each. A run already inside a pass
# (FM_CPU_PASS_HELD above 0) takes none and runs at most that many workers.
# Waiting roots queue rather than fail; host-slot and CPU-pass queue time
# consume neither the root deadline nor its retry budget.
# A pool that cannot be used (its directory, lock, ticket, slot or queue file)
# never lets a root run unbounded: lint exits 2 before any root starts, or a gate
# exits 2 for its root, naming the path and the fix.
# The private gate's locking and process-lifetime invariants live in bin/fm-lint-cache.pl.
# --partition 1of3/2of3/3of3 splits the entire canonical inventory across
# three CI runners, each with those same concurrency-limited workers.
# Partitions are complete, disjoint, and measured-duration balanced; --list-files
# exposes their actual roots. A root without a measured hint gets 6000 ms,
# rounded above the observed 5352 ms per-root mean; it is never omitted.
# Partition mode starts with full source-aware analysis, never changed-only
# or --fast, and does not accept explicit paths. Each partition also runs
# workflow lint and backend-purity checks, keeping either invocation
# independently useful.
#
# With FM_LINT_REQUIRE_BOUNDS=1, which CI sets, every per-root ShellCheck
# process runs under an enforced envelope: a wall deadline
# (FM_LINT_ROOT_SECONDS, default 1200, which fm-duration.py may only raise to
# a measured p99 x 3 once calibrated), a terminate-then-kill cleanup grace
# (FM_LINT_ROOT_GRACE, default 5), and a per-process address-space limit
# (FM_LINT_ROOT_MEMORY_KIB, default 12582912 = 12 GiB of virtual address
# space per analysis process). The sizing rationale and RSS reduction threshold
# live beside ROOT_MEMORY_KIB below. This is not a resident-memory ceiling;
# check aggregate runner RSS in CI. It does not change the host-wide budget B
# (the sum of the resident sizes of all roots) or the per-root cap
# FM_LINT_ROOT_RSS_KIB (8 GiB, the resident size at which the macOS watch ends
# one root): the address-space limit applies only where ulimit -v works, and the
# admission that holds B applies in every mode. The watchdog uses the shared
# bin/fm-timeout-lib.sh group-kill pattern, so a deadline or an interrupt
# removes the owned process group. Bounds mode proves the watchdog can
# actually bound a probe command and that the host accepts the memory limit
# BEFORE any root starts; when either check fails the run refuses with a
# named error, so a required-bounds run never lints uncapped. Without
# FM_LINT_REQUIRE_BOUNDS (a local developer lint, where hosts like macOS
# cannot apply the address-space limit at all) each root still runs in its
# own ShellCheck process with identical diagnostics, no deadline and no
# address-space limit, under the resident-memory watch above on macOS; the host-wide
# concurrency pool and its memory admission are always on.
#
# If a source-following root exits with a memory failure, including a resident
# bound crossing (status 98, named on stderr), it is retried once
# without --external-sources under the same memory limit and only the time
# left in that root's original deadline; with under a second left, the
# memory failure stands without a retry. A clean retry passes
# with an explicit memory-fallback reason and warning; only the
# cross-file-dependent codes listed above are excluded.
# Other findings and failed retries still fail lint. The retry's diagnostics
# replace the failed attempt's output; peak RSS is the maximum of both attempts.
#
# Root timestamps use Perl's high-resolution clock even on stock macOS Bash.
# Start/end span the queue wait; recorded duration subtracts waits from both
# the initial attempt and any retry.
# Per-root evidence is incremental: workers append begin/end records (root,
# mode, shard, start, end, duration, final exit status, reason, peak RSS when
# measured, whether the final attempt followed sources, calibration eligibility,
# and the 1-minute load at root start and end) to a roots log
# as each root completes, so a mid-run kill still leaves the completed record
# and names the root in flight as begun-but-unfinished. With --telemetry the
# log is retained at
# <telemetry-without-.tsv>.roots.tsv (or <telemetry>.roots.tsv if there is no
# .tsv suffix); otherwise it lives only in the
# run's scratch dir. Reason values are ok, findings, memory-fallback,
# timeout, memory, signal:<sig>, limit-unavailable, not-started (the gate
# refused a waiting root because the run was marked to stop), rerun-queued (its
# first run was only unmeasured, so its result is not used and it runs once more
# alone; the rerun has its own begin and end rows in the alone pass), or error:<rc>.
# The closing meta rows count each root once, by its last row in the log, so a
# rerun root is one begun root, completed when its rerun ended.
# Memory requires process-level evidence (a GHC exhaustion status or runtime
# error on stderr), not an echoed source excerpt or an OOM phrase in a
# filename. In partition mode begin/end
# lines also stream to stderr, and an abnormal root end is always reported
# there.
# Duration observations are appended through fm-duration.py in one batch from
# the roots log when lint exits; partial selection and memory-fallback successes
# are not calibration evidence.
#
# Optional quiet telemetry writes one bounded TSV snapshot of content and source
# graph identity, wall/CPU/RSS, shard load, and competing ShellCheck processes.
# source_followed_directives counts directives only for roots whose final
# attempt followed sources, not roots that passed or failed a no-source retry.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set (see above)
#   fm-lint.sh --fast [path]...       local lint with extended analysis disabled
#   fm-lint.sh <path>...               lint explicit roots with the same config
#   fm-lint.sh --jobs <1|2> [path]...  override concurrent worker count
#   fm-lint.sh --partition <1of3|2of3|3of3> lint one canonical CI partition (see fallback above)
#   fm-lint.sh --telemetry <path> ...  write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --check-version         report whether the ShellCheck/actionlint pins are current
#   fm-lint.sh --strict-version        refuse a local ShellCheck that differs from the pin; exits 2 on every non-macOS host
#   fm-lint.sh --list-files            print the file set that would be linted
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
# Cross-file codes that need --external-sources. No-source checks (the
# memory fallback) cannot judge them.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
# The host-wide admission's two constants, here because every route that starts a
# ShellCheck (the owner and its private worker mode) reads them, and no setting or
# inherited variable replaces them: the host directory belongs to the user, not to
# HOME or XDG_CACHE_HOME, and the budget has one value (see the header). The shell's
# own UID, not the id command: no PATH entry can name another user.
HOST_POOL_ROOT=/var/tmp/firstmate-lint-${UID:-0}
HOST_RSS_KIB=3670016
# The version probe's own lane inside that budget (one probe at a time on the host,
# held to this many KiB); the roots' admission works with the rest.
PROBE_RESERVE_KIB=65536
# The probe's time bound: a probe still running after it, and every run waiting for
# the lane that long, report on stderr that they are blocked and keep waiting
# (nothing is ended; the lane frees only when the probe it records by exact
# identity has provably ended). `shellcheck --version` takes about 0.1 s.
# measured: value=30 date=2026-11-16 host=Mac-Studio.local margin=333x (five `shellcheck --version` runs, slowest 0.09 s wall)
PROBE_BOUND_SECONDS=30
ROOTS_RSS_KIB=$((HOST_RSS_KIB - PROBE_RESERVE_KIB))
# The host ledger: gate entries (entry.*) and each lint run's entry (run.*), which
# carries the values that bound every root the run starts. The private modes read
# those values from the run's entry and from no setting or inherited variable.
HOST_LEDGER_DIR=$HOST_POOL_ROOT/admission.lock.ledger
cd "$ROOT" || exit 1

# The sibling timeout library supplies the shared group-kill watchdog that
# bounds each root when FM_LINT_REQUIRE_BOUNDS=1 requires it; without the
# library a required-bounds run refuses in preflight rather than lint uncapped.
if [ -r "$SELF_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SELF_DIR/fm-timeout-lib.sh"
fi

if [ -r "$SELF_DIR/fm-duration-lib.sh" ]; then
  # shellcheck source=bin/fm-duration-lib.sh
  . "$SELF_DIR/fm-duration-lib.sh"
fi

FM_LINT_WORKER_RUN_PID=
FM_LINT_WORKER_ARGS=()
FM_LINT_LAST_QUEUED=0
FM_LINT_LAST_INTERVAL_ONLY=0
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_RUN_PID" ] || return 0
  kill "$FM_LINT_WORKER_RUN_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_RUN_PID" 2>/dev/null || true
  FM_LINT_WORKER_RUN_PID=
}

fm_lint_now_ms() {
  "${FM_LINT_PERL_BIN:-perl}" -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

# Names are listed only for signal numbers that agree on Linux and macOS; any
# other number reports itself.
fm_lint_signal_name() {  # <signal-number>
  case "$1" in
    1) printf 'HUP\n' ;; 2) printf 'INT\n' ;; 3) printf 'QUIT\n' ;;
    6) printf 'ABRT\n' ;; 8) printf 'FPE\n' ;; 9) printf 'KILL\n' ;;
    11) printf 'SEGV\n' ;; 13) printf 'PIPE\n' ;; 14) printf 'ALRM\n' ;;
    15) printf 'TERM\n' ;; 24) printf 'XCPU\n' ;; 25) printf 'XFSZ\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Peak RSS of a finished root process: GNU time writes max_rss_kib=<KiB> while
# BSD time -l writes "maximum resident set size" in bytes.
fm_lint_root_rss() {  # <rss-file>
  local file=$1 kib
  kib=$(awk '
    /^max_rss_kib=/ { value = substr($0, 13) + 0; found = 1 }
    /maximum resident set size/ { value = int($1 / 1024); found = 1 }
    END { if (found) print value }
  ' "$file" 2>/dev/null)
  printf '%s\n' "${kib:-unavailable}"
}

# The two peak readings a root can carry, kept apart in the roots log:
# /usr/bin/time's maximum resident size of the analysis process (BSD "maximum
# resident set size" in bytes; GNU max_rss_kib on a host without the watch), and
# the macOS watch's own peak of the whole tree, the larger of resident size and
# footprint (watch_peak_kib=). The older rss_kib column is whichever of the two the
# file named last (the watch's, when it ended a root over its bound).
fm_lint_root_time_rss() {  # <rss-file>...
  cat "$@" 2>/dev/null | awk -v darwin="$([ "$(uname)" = Darwin ] && echo 1 || echo 0)" '
    /maximum resident set size/ { v = int($1 / 1024); if (v > best) best = v; found = 1 }
    darwin == 0 && /^max_rss_kib=/ { v = substr($0, 13) + 0; if (v > best) best = v; found = 1 }
    END { if (found) print best; else print "unavailable" }
  '
}
fm_lint_root_watch_peak() {  # <rss-file>...
  cat "$@" 2>/dev/null | awk '
    /^watch_peak_kib=/ { v = substr($0, 16) + 0; if (v > best) best = v; found = 1 }
    END { if (found) print best; else print "unavailable" }
  '
}

# Samples each source gave the macOS resident-memory watch across a root's
# attempts, as libproc:<n>, followed by ,reader-unavailable:<reason>
# for each attempt that gave up its libproc reader, or none when no watch
# sampled the root.
fm_lint_root_rss_samples() {  # <rss-file>...
  cat "$@" 2>/dev/null | awk -F '[=:,]' '
    /^rss_samples=/ { for (i = 2; i < NF; i += 2) count[$i] += $(i + 1); found = 1 }
    /^rss_reader_unavailable=/ { reasons = reasons ",reader-unavailable:" $2 }
    /^rss_escaped=/ { line = $0; sub(/^rss_escaped=/, "", line); gsub(/,/, ";", line); reasons = reasons ",escaped:" line }
    /^rss_unmeasured=1$/ { reasons = reasons ",unmeasured" }
    /^rss_(cont|kill)_failed=1$/ { line = $1; sub(/^rss_/, "", line); gsub(/_/, "-", line); reasons = reasons "," line }
    /^rss_launch_unrecorded=1$/ { reasons = reasons ",launch-unrecorded" }
    END { if (found) printf "libproc:%d%s\n", count["libproc"], reasons; else print "none" }
  '
}

# Measurement only: print each missed tick the macOS watch recorded across a root's
# attempts on stderr, verbatim with the root's path, and append the root's longest
# reply and tick to the run's record, which fm_lint_finish reads before the scratch
# dir (and every rss file) is removed.
fm_lint_report_watch() {  # <path> <run-record> <rss-file>...
  local path=$1 record=$2 line
  shift 2
  grep -h '^rss_miss=' "$@" 2>/dev/null | while IFS= read -r line; do
    printf 'fm-lint: watch miss %s %s\n' "$path" "$line" >&2
  done
  cat "$@" 2>/dev/null | awk -F= -v path="$path" '
    $1 == "rss_longest_reply_ms" { found = 1; if ($2 + 0 > reply) reply = $2 + 0 }
    $1 == "rss_longest_tick_ms" { found = 1; if ($2 + 0 > tick) tick = $2 + 0 }
    END { if (found) printf "%d\t%d\t%s\n", reply, tick, path }
  ' >> "$record"
}

# Measurement only: the one run-level line of the largest longest reply and longest
# tick across the run's roots, naming the root of each.
# shellcheck disable=SC2329 # Invoked by the EXIT trap's fm_lint_finish.
fm_lint_report_watch_run() {  # <run-record>
  { cat "$1" 2>/dev/null || true; } | awk -F '\t' '
    NF >= 3 {
      if (reply_root == "" || $1 + 0 > reply) { reply = $1 + 0; reply_root = $3 }
      if (tick_root == "" || $2 + 0 > tick) { tick = $2 + 0; tick_root = $3 }
    }
    END {
      if (reply_root == "") print "fm-lint: watch run rss_longest_reply_ms=none rss_longest_tick_ms=none (no root recorded a tick)"
      else printf "fm-lint: watch run rss_longest_reply_ms=%d root=%s rss_longest_tick_ms=%d root=%s\n", reply, reply_root, tick, tick_root
    }
  ' >&2
}

fm_lint_max_root_rss() {  # <rss-kib> <rss-kib>
  local first=$1 second=$2
  case "$first" in ''|unavailable|*[!0-9]*) printf '%s\n' "$second"; return ;; esac
  case "$second" in ''|unavailable|*[!0-9]*) printf '%s\n' "$first"; return ;; esac
  if [ "$first" -gt "$second" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
}

# Map a root's exit status onto the reported reason vocabulary without
# pretending every signal or nonzero exit is a memory kill: only process-level
# memory-failure evidence earns the memory reason - GHC's heap-exhaustion
# status 251, the resident-memory watch's own status 98, or a complete runtime
# memory-error line on the root's stderr, including the check helper's Perl
# "Out of memory!" exit 1 - and that
# evidence is checked before a generic findings or signal reason.
# Diagnostics and their echoed source excerpts are on stdout and never count,
# and each stderr form is matched whole to its line end, so a root path that
# merely contains OOM words inside a file error never counts either.
fm_lint_classify_root() {  # <rc> <root-stderr-file>
  local rc=$1 err=$2
  case "$rc" in
    0) printf 'ok\n'; return 0 ;;
    97) printf 'limit-unavailable\n'; return 0 ;;
    96) printf 'unmeasured\n'; return 0 ;;
    251|98) printf 'memory\n'; return 0 ;;
  esac
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] && [ "$rc" = 124 ]; then
    printf 'timeout\n'; return 0
  fi
  if grep -qE '^[^[:space:]:]+: (out of memory \(requested [0-9]+ bytes\)|Heap exhausted;)$|: resource exhausted \((Cannot allocate memory|out of memory)\)$|^Out of memory!$' "$err" 2>/dev/null; then
    printf 'memory\n'; return 0
  fi
  # Status 2 with the gate's stopped-run refusal is a root the run never started
  # (the gate refused it while it waited), not a ShellCheck error.
  if [ "$rc" = 2 ] && grep -q '^fm-lint: this run admits no new root: ' "$err" 2>/dev/null; then
    printf 'not-started\n'; return 0
  fi
  if [ "$rc" = 1 ]; then
    printf 'findings\n'; return 0
  fi
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    case "$rc" in
      137)
        # The perl watchdog exits 124 on its own bound, so a bare 137 is a real
        # SIGKILL of the child; GNU/BSD timeout instead report 137 when their
        # configured kill had to fire at the bound.
        if [ "${FM_LINT_INTERNAL_BOUNDED:-}" = perl ]; then
          printf 'signal:KILL\n'; return 0
        fi
        printf 'timeout\n'; return 0
        ;;
    esac
  fi
  case "$rc" in
    ''|*[!0-9]*) printf 'error\n' ;;
    *)
      if [ "$rc" -gt 128 ]; then
        printf 'signal:%s\n' "$(fm_lint_signal_name "$((rc - 128))")"
      else
        printf 'error:%s\n' "$rc"
      fi
      ;;
  esac
}

# Run one ShellCheck invocation under the given deadline and the per-root
# address-space limit, returning its exit status in FM_LINT_LAST_RC.
fm_lint_exec_root() {  # <path> <stdout-file> <stderr-file> <rss-file> <seconds> <args...>
  local path=$1 root_out=$2 root_err=$3 rss_file=$4 seconds=$5 invocation_rc=0 wait_file waited
  local -a analysis_command gate_command pass_command cold_command check_command
  shift 5
  analysis_command=("$FM_LINT_SHELLCHECK" "$@" -- "$path")
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" = none ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      analysis_command=(/usr/bin/time -lp -o "$rss_file" "${analysis_command[@]}")
    else
      analysis_command=(/usr/bin/time -f 'max_rss_kib=%M' -o "$rss_file" "${analysis_command[@]}")
    fi
  fi
  # Native macOS cannot apply ulimit -v, so without the enforced envelope the
  # resident-memory watch sits outside /usr/bin/time and ends the root's
  # process group when its tree crosses the bound.
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" = none ] && [ -n "${FM_LINT_INTERNAL_RSS_KIB:-}" ] \
    && [ "$(uname)" = Darwin ]; then
    analysis_command=("${FM_LINT_PERL_BIN:-perl}" "$SELF_DIR/fm-lint-cache.pl" rsswatch \
      "$FM_LINT_INTERNAL_RSS_KIB" "$rss_file" -- "${analysis_command[@]}")
  fi
  # The host-wide slot gate sits outside the watchdog and /usr/bin/time, so
  # queue time counts toward neither the root deadline nor its peak RSS.
  gate_command=()
  wait_file="$rss_file.wait"
  rm -f "$wait_file" "$rss_file.cache" "$rss_file.cache.wait" "$rss_file.pass.wait"
  # The budget and the host lock are this script's own constants, not what the
  # caller's environment says (a worker started directly gets the same ones), and a
  # root's worst-case charge is the bound the root is held to, not a value the
  # caller names.
  local -a gate_cap=()
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    gate_cap=("FM_LINT_INTERNAL_ROOT_CAP_KIB=${FM_LINT_INTERNAL_MEMORY_KIB:-8388608}")
  elif [ -n "${FM_LINT_INTERNAL_RSS_KIB:-}" ]; then
    gate_cap=("FM_LINT_INTERNAL_ROOT_CAP_KIB=$FM_LINT_INTERNAL_RSS_KIB")
  fi
  gate_command=(env "FM_LINT_INTERNAL_ROOT_KEY=${FM_LINT_INTERNAL_MODE:-full}:${path#"$ROOT"/}" \
    "FM_LINT_INTERNAL_ROOT_RSS_FILE=$rss_file" \
    "FM_LINT_INTERNAL_HOST_RSS_KIB=$ROOTS_RSS_KIB" "FM_LINT_INTERNAL_HOST_LOCK=$HOST_POOL_ROOT/admission.lock" \
    ${gate_cap[@]+"${gate_cap[@]}"} \
    "${FM_LINT_PERL_BIN:-perl}" "$SELF_DIR/fm-lint-cache.pl" gate \
    "$FM_LINT_INTERNAL_SLOT_DIR" "$FM_LINT_INTERNAL_NCPU" "$FM_LINT_INTERNAL_RUN_ID" "$wait_file" --)
  # A cold ShellCheck is CPU-bound, so before its memory slot it takes one pass of
  # the host-wide CPU pool (docs/cpu-pass-pool.md), also outside the root deadline.
  # The gate stays the direct parent of the watchdog or ShellCheck, so they inherit
  # its slot and see its death. A run already inside a pass takes none; its pass
  # wait leaves the root's recorded time.
  pass_command=()
  if [ -x "$SELF_DIR/fm-cpu-pass.sh" ] && [ -r "$SELF_DIR/fm-cpu-pass.py" ]; then
    pass_command=("$SELF_DIR/fm-cpu-pass.sh" run --label "fm-lint $path" --log-fd 8 \
      --wait-file "$rss_file.pass.wait" --)
  fi
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ]; then
    # The watchdog runs in a process group of its own (the same setpgrp hop the
    # workers use), so the owner's TERM-then-KILL group sweep cannot kill it
    # before it has forwarded the signal to the root's own group. If the worker
    # dies before its trap can signal the watchdog, the watchdog's parent-death
    # check still starts the same terminate-then-kill escalation; the worker
    # names itself as that owner before the launch, so a worker that dies while
    # the watchdog is still starting is detected too.
    cold_command=(${pass_command[@]+"${pass_command[@]}"} ${gate_command[@]+"${gate_command[@]}"} "${FM_LINT_PERL_BIN:-perl}" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        "${BASH:-bash}" "$SELF" --internal-timed \
        "$seconds" "$FM_LINT_INTERNAL_GRACE" \
        "${BASH:-bash}" "$SELF" --internal-root "$rss_file" "$FM_LINT_INTERNAL_MEMORY_KIB" \
        "${analysis_command[@]}")
  else
    cold_command=(${pass_command[@]+"${pass_command[@]}"} ${gate_command[@]+"${gate_command[@]}"} "${analysis_command[@]}")
  fi
  # The analysis enters the gate, with the watchdog inside admission.
  check_command=(env "FM_LINT_CACHE_RESULT_FILE=$rss_file.cache" \
    "${FM_LINT_PERL_BIN:-perl}" "$SELF_DIR/fm-lint-cache.pl" check \
    "$ROOT" "$FM_LINT_SHELLCHECK" \
    "$@" -- "$path" --execute "${cold_command[@]}")
  ( FM_EXEC_TIMED_OWNER_PID=$$ exec "${check_command[@]}" ) > "$root_out" 2> "$root_err" &
  FM_LINT_WORKER_RUN_PID=$!
  wait "$FM_LINT_WORKER_RUN_PID" || invocation_rc=$?
  FM_LINT_WORKER_RUN_PID=
  FM_LINT_LAST_RC=$invocation_rc
  FM_LINT_LAST_WAIT_MS=0
  for wait_file in "$rss_file.wait" "$rss_file.cache.wait" "$rss_file.pass.wait"; do
    if [ -r "$wait_file" ]; then
      waited=$(tr -d '[:space:]' < "$wait_file" 2>/dev/null)
      case "$waited" in
        ''|*[!0-9]*) ;;
        *) FM_LINT_LAST_WAIT_MS=$((FM_LINT_LAST_WAIT_MS + waited)) ;;
      esac
    fi
  done
}

# A root attempt the macOS watch failed (96) only because a missed tick was
# followed by a later tick (the watch wrote rss_rerun_alone=1, which it writes
# for no other failure) gets one rerun alone, in the run's first pass only: in
# the alone pass (FM_LINT_INTERNAL_ALONE=1) the same end is final.
fm_lint_rerun_alone_eligible() {  # <rc> <rss-file>
  [ "$1" = 96 ] && [ "${FM_LINT_INTERNAL_ALONE:-0}" != 1 ] \
    && grep -qx 'rss_rerun_alone=1' "$2" 2>/dev/null
}

# Run one selected root, retry memory failures without source following, record
# its lifecycle in the roots log, and append the final diagnostics.
fm_lint_run_root() {  # <index> <path> <output-dir> <shard-index>
  local index=$1 path=$2 output_dir=$3 shard_index=$4
  local root_out="$output_dir/root.$shard_index.$index.out"
  local root_err="$output_dir/root.$shard_index.$index.err"
  local rss_file="$output_dir/root.$shard_index.$index.rss"
  local fallback_out="$output_dir/root.$shard_index.$index.fallback.out"
  local fallback_err="$output_dir/root.$shard_index.$index.fallback.err"
  local fallback_rss="$output_dir/root.$shard_index.$index.fallback.rss"
  local start_ms end_ms duration_ms invocation_rc=0 reason rss_kib initial_rc initial_reason
  local calibration=0 cache_outcome load_start='' load_end=''
  local fallback_secs queued_ms=0 root_seconds=$FM_LINT_INTERNAL_ROOT_SECS
  if [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] && declare -F fm_duration_limit >/dev/null 2>&1; then
    root_seconds=$(fm_duration_limit "lint-root.${FM_LINT_INTERNAL_MODE:-full}.$path" "$root_seconds" 99) || return $?
  fi
  local final_follow_sources=${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}
  local -a fallback_args
  if declare -F fm_duration_load >/dev/null 2>&1; then
    load_start=$(fm_duration_load)
  fi
  start_ms=$(fm_lint_now_ms)
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    printf 'begin\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" "$start_ms" \
      >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ]; then
    printf 'fm-lint: begin %s (shard %s, %s mode)\n' \
      "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-unknown}" >&2
  fi
  fm_lint_exec_root "$path" "$root_out" "$root_err" "$rss_file" \
    "$root_seconds" "${FM_LINT_WORKER_ARGS[@]}"
  invocation_rc=$FM_LINT_LAST_RC
  queued_ms=$FM_LINT_LAST_WAIT_MS
  reason=$(fm_lint_classify_root "$invocation_rc" "$root_err")
  initial_rc=$invocation_rc
  initial_reason=$reason
  # The retry spends what is left of this root's one deadline rather than a
  # fresh one, so both attempts together still fit the budget CI sized its job
  # timeout around.
  fallback_secs=$(( (start_ms + queued_ms + root_seconds * 1000 - $(fm_lint_now_ms)) / 1000 ))
  FM_LINT_LAST_QUEUED=0
  if fm_lint_rerun_alone_eligible "$invocation_rc" "$rss_file"; then
    # Its only failure is an unmeasured interval: its result is not used (its
    # output is dropped), and it is run once more alone after the run's other
    # roots (fm_lint_worker queues it).
    reason=rerun-queued
    FM_LINT_LAST_QUEUED=1
    rss_kib=$(fm_lint_root_rss "$rss_file")
    printf 'fm-lint: %s ran unmeasured (watch record: %s); its result is not used, and it runs once more alone after the other roots finish\n' \
      "$path" "$(fm_lint_root_rss_samples "$rss_file")" >> "$output_dir/shard.$shard_index.out"
  elif [ "$reason" = memory ] \
    && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ] \
    && [ "${FM_LINT_INTERNAL_BOUNDED:-none}" != none ] \
    && [ "$fallback_secs" -lt 1 ]; then
    printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); no time left in its %ss deadline to retry without it\n' \
      "$path" "$initial_reason" "$initial_rc" "$root_seconds" >> "$output_dir/shard.$shard_index.out"
    rss_kib=$(fm_lint_root_rss "$rss_file")
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  elif [ "$reason" = memory ] \
    && [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
    fallback_args=()
    for arg in "${FM_LINT_WORKER_ARGS[@]}"; do
      [ "$arg" = --external-sources ] || fallback_args+=("$arg")
    done
    [ -z "$LOCAL_NOX_EXCLUDE" ] || fallback_args+=("--exclude=$LOCAL_NOX_EXCLUDE")
    fm_lint_exec_root "$path" "$fallback_out" "$fallback_err" "$fallback_rss" \
      "$fallback_secs" "${fallback_args[@]}"
    final_follow_sources=0
    invocation_rc=$FM_LINT_LAST_RC
    queued_ms=$((queued_ms + FM_LINT_LAST_WAIT_MS))
    reason=$(fm_lint_classify_root "$invocation_rc" "$fallback_err")
    rss_kib=$(fm_lint_max_root_rss \
      "$(fm_lint_root_rss "$rss_file")" "$(fm_lint_root_rss "$fallback_rss")")
    printf 'fm-lint: %s hit the memory ceiling with --external-sources (reason=%s rc=%s); retried without it' \
      "$path" "$initial_reason" "$initial_rc" >> "$output_dir/shard.$shard_index.out"
    if fm_lint_rerun_alone_eligible "$invocation_rc" "$fallback_rss"; then
      # The narrower retry's only failure is an unmeasured interval: the root's
      # result is not used, and the whole root runs once more alone later.
      reason=rerun-queued
      FM_LINT_LAST_QUEUED=1
      printf '; the retry ran unmeasured (watch record: %s); its result is not used, and the root runs once more alone after the other roots finish\n' \
        "$(fm_lint_root_rss_samples "$fallback_rss")" >> "$output_dir/shard.$shard_index.out"
    elif [ "$reason" = ok ]; then
      reason=memory-fallback
      invocation_rc=0
      printf '; fallback passed with cross-file codes excluded (%s)\n' "$LOCAL_NOX_EXCLUDE" \
        >> "$output_dir/shard.$shard_index.out"
    else
      printf '; fallback reason=%s rc=%s\n' "$reason" "$invocation_rc" \
        >> "$output_dir/shard.$shard_index.out"
    fi
    [ "$FM_LINT_LAST_QUEUED" = 1 ] || cat "$fallback_out" "$fallback_err" >> "$output_dir/shard.$shard_index.out"
  else
    rss_kib=$(fm_lint_root_rss "$rss_file")
    cat "$root_out" "$root_err" >> "$output_dir/shard.$shard_index.out"
  fi
  end_ms=$(fm_lint_now_ms)
  if declare -F fm_duration_load >/dev/null 2>&1; then
    load_end=$(fm_duration_load)
  fi
  duration_ms=$((end_ms - start_ms - queued_ms))
  cache_outcome=$(cat "$rss_file.cache" 2>/dev/null || true)
  if [ "$cache_outcome" = analyzed ] && [ "$reason" != memory-fallback ]; then
    calibration=1
  fi
  if [ -n "${FM_LINT_INTERNAL_ROOTS_LOG:-}" ]; then
    # Field 17 of this row, wait_ms, is the root's queue wait in the host-wide gate in
    # milliseconds (0 when it did not wait); duration_ms excludes it, so
    # end_ms - start_ms - duration_ms equals wait_ms.
    # Fields 18 and 19 keep apart the two peak readings field 11 mixes:
    # /usr/bin/time's reading of the analysis process (time_rss_kib) and the
    # macOS watch's own reading of the whole tree (watch_peak_kib).
    printf 'end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$index" "$path" "$shard_index" "${FM_LINT_INTERNAL_MODE:-}" \
      "$start_ms" "$end_ms" "$duration_ms" "$invocation_rc" "$reason" "$rss_kib" "$final_follow_sources" "$calibration" \
      "$load_start" "$load_end" "$(fm_lint_root_rss_samples "$rss_file" "$fallback_rss")" "$queued_ms" \
      "$(fm_lint_root_time_rss "$rss_file" "$fallback_rss")" "$(fm_lint_root_watch_peak "$rss_file" "$fallback_rss")" >> "$FM_LINT_INTERNAL_ROOTS_LOG"
  fi
  fm_lint_report_watch "$path" "$output_dir/watch-longest.tsv" "$rss_file" "$fallback_rss"
  # The watch's own record of a root it failed (status 96): its samples and the
  # reasons it wrote, so the run's stop mark and the end line say what happened.
  FM_LINT_LAST_WATCH=
  if [ "$invocation_rc" = 96 ]; then
    FM_LINT_LAST_WATCH=$(fm_lint_root_rss_samples "$rss_file" "$fallback_rss")
  fi
  # Whether this 96 was only an unmeasured interval of its last attempt (the watch's
  # rss_rerun_alone=1): in the alone pass such a final failure does not stop the
  # run's other reruns, each of which runs alone anyway.
  FM_LINT_LAST_INTERVAL_ONLY=0
  if [ "$invocation_rc" = 96 ]; then
    if [ "$final_follow_sources" = 0 ]; then
      ! grep -qx 'rss_rerun_alone=1' "$fallback_rss" 2>/dev/null || FM_LINT_LAST_INTERVAL_ONLY=1
    else
      ! grep -qx 'rss_rerun_alone=1' "$rss_file" 2>/dev/null || FM_LINT_LAST_INTERVAL_ONLY=1
    fi
  fi
  if [ "${FM_LINT_INTERNAL_PROGRESS:-0}" = 1 ] || { [ "$reason" != ok ] && [ "$reason" != findings ] && [ "$reason" != memory-fallback ]; }; then
    printf 'fm-lint: end %s reason=%s rc=%s duration_ms=%s rss_kib=%s%s\n' \
      "$path" "$reason" "$invocation_rc" "$duration_ms" "$rss_kib" "${FM_LINT_LAST_WATCH:+ watch=$FM_LINT_LAST_WATCH}" >&2
  fi
  return "$invocation_rc"
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab entry index path output invocation_rc rc=0
  local -a root_entries
  root_entries=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    root_entries+=("$index	$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#root_entries[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    FM_LINT_WORKER_ARGS=(--norc --external-sources)
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      FM_LINT_WORKER_ARGS+=(--extended-analysis=false)
    fi
    : > "$output.out"
    for entry in "${root_entries[@]}"; do
      # A gate that refused for an unreadable host process table, or a watch that
      # failed its root (status 96), marked the run: start no further
      # root in either worker, and fail the shard, because a root not started is
      # not analyzed.
      if [ -e "${FM_LINT_INTERNAL_ABORT_FILE:-}" ]; then
        printf 'fm-lint: %s not started: %s\n' "${entry#*"$tab"}" \
          "$(head -n 1 "$FM_LINT_INTERNAL_ABORT_FILE" 2>/dev/null || true)" >> "$output.out"
        [ "$rc" -ne 0 ] || rc=2
        continue
      fi
      index=${entry%%"$tab"*}
      path=${entry#*"$tab"}
      invocation_rc=0
      FM_LINT_LAST_QUEUED=0
      FM_LINT_LAST_INTERVAL_ONLY=0
      fm_lint_run_root "$index" "$path" "$output_dir" "$shard_index" || invocation_rc=$?
      # A root whose only failure was an unmeasured interval neither fails nor
      # marks the run here: it is queued for its one rerun alone. A queue that
      # cannot be written leaves it the failed root it was (status 96 below).
      if [ "$FM_LINT_LAST_QUEUED" = 1 ]; then
        if [ -n "${FM_LINT_INTERNAL_ALONE_QUEUE:-}" ] \
          && printf '%s\t%s\n' "$index" "$path" >> "$FM_LINT_INTERNAL_ALONE_QUEUE" 2>/dev/null; then
          continue
        fi
        printf 'fm-lint: %s could not be queued for its rerun alone (%s); it fails (status 96)\n' \
          "$path" "${FM_LINT_INTERNAL_ALONE_QUEUE:-no queue}" >> "$output.out"
      fi
      if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
        rc=$invocation_rc
      fi
      # A root its watch failed (status 96): mark the run, so neither worker
      # starts another root, even if the watch could not write the mark itself;
      # if this mark cannot be written either, this worker starts no further root.
      # The mark names the root and the watch's recorded samples and reasons.
      # In the alone pass a rerun that was again only unmeasured fails without the
      # mark, so each other queued root still gets its one rerun alone.
      if [ "$invocation_rc" -eq 96 ] && [ -n "${FM_LINT_INTERNAL_ABORT_FILE:-}" ] && [ ! -e "$FM_LINT_INTERNAL_ABORT_FILE" ] \
        && { [ "${FM_LINT_INTERNAL_ALONE:-0}" != 1 ] || [ "$FM_LINT_LAST_INTERVAL_ONLY" != 1 ]; }; then
        if ! printf 'the resident-memory watch failed %s (status 96; watch record: %s)\n' "$path" "${FM_LINT_LAST_WATCH:-none}" >> "$FM_LINT_INTERNAL_ABORT_FILE" 2>/dev/null; then
          printf 'fm-lint: the run could not be marked to stop at %s; this worker starts no further root\n' "$FM_LINT_INTERNAL_ABORT_FILE" >> "$output.out"
          break
        fi
      fi
    done
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# The private modes (--internal-worker, --internal-root, --internal-timed) take
# every value that bounds what they start from the entry of the lint run that
# started them, never from a setting or inherited variable: the perl that checks
# admission, the python that reads memory, the bound mechanism, the per-root
# address-space limit and the per-root resident limit. The entry is
# FM_LINT_INTERNAL_RUN_ENTRY, which must name a run.<pid>.<n> file directly in
# this script's host ledger (HOST_LEDGER_DIR, a constant here), whose flock is held
# (its run is alive), whose pid is an ancestor of this process and runs this lint.
# Anything else exits 2 and starts nothing.
fm_lint_load_run_entry() {  # <mode>
  local mode=$1 entry=${FM_LINT_INTERNAL_RUN_ENTRY:-} name owner perl python bounded memory_kib rss rest
  name=${entry##*/}
  case "$entry" in
    "$HOST_LEDGER_DIR/$name") ;;
    *) entry= ;;
  esac
  case "$name" in
    run.*.*) case "${name#run.}" in *[!0-9.]*|.*|*.|*.*.*) entry= ;; esac ;;
    *) entry= ;;
  esac
  if [ -z "$entry" ] || [ -L "$entry" ] || [ ! -f "$entry" ] \
    || ! IFS=$'\t' read -r owner perl python bounded memory_kib rss rest < "$entry"; then
    printf 'fm-lint.sh: %s starts a command only for a lint run whose entry is in the host ledger %s.\n' "$mode" "$HOST_LEDGER_DIR" >&2
    exit 2
  fi
  case "$owner" in ''|0*|*[!0-9]*) owner= ;; esac
  case "$perl" in /*) [ -x "$perl" ] || owner= ;; *) owner= ;; esac
  case "$python" in /*|python3) ;; *) owner= ;; esac
  case "$bounded" in none|perl) ;; *) owner= ;; esac
  case "$memory_kib" in ''|0*|*[!0-9]*) owner= ;; esac
  case "$rss" in ''|0*|*[!0-9]*) owner= ;; esac
  if [ -z "$owner" ] || [ -n "$rest" ] || [ "${#rss}" -gt 7 ] || [ "$rss" -gt 8388608 ] \
    || ! "$perl" "$SELF_DIR/fm-lint-cache.pl" admitted-run "$HOST_LEDGER_DIR" "$entry"; then
    printf 'fm-lint.sh: %s starts a command only for a live lint run whose entry in %s is valid; %s is not.\n' "$mode" "$HOST_LEDGER_DIR" "$entry" >&2
    exit 2
  fi
  FM_LINT_PERL_BIN=$perl
  FM_LINT_INTERNAL_PYTHON=$python
  FM_LINT_INTERNAL_BOUNDED=$bounded
  FM_LINT_INTERNAL_MEMORY_KIB=$memory_kib
  FM_LINT_INTERNAL_RSS_KIB=$rss
  export FM_LINT_PERL_BIN FM_LINT_INTERNAL_PYTHON FM_LINT_INTERNAL_BOUNDED FM_LINT_INTERNAL_MEMORY_KIB FM_LINT_INTERNAL_RSS_KIB
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  fm_lint_load_run_entry --internal-worker
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

# The private modes that run a command they are handed (--internal-root and
# --internal-timed) run it only inside an admitted root: the gate that admitted
# the root names its ledger entry in FM_LINT_INTERNAL_ADMISSION, and that entry must
# be in this script's host ledger, live, and belong to a gate (a perl running
# fm-lint-cache.pl gate) that is an ancestor of this process. The perl that checks
# it is the run entry's. A caller that sets FM_LINT_INTERNAL=1 itself gets exit 2
# and no command.
fm_lint_require_admission() {  # <mode>
  fm_lint_load_run_entry "$1"
  "$FM_LINT_PERL_BIN" "$SELF_DIR/fm-lint-cache.pl" admitted "$HOST_LEDGER_DIR" "${FM_LINT_INTERNAL_ADMISSION:-}" || {
    printf 'fm-lint.sh: %s starts a command only inside a root the host-wide admission has admitted.\n' "$1" >&2
    exit 2
  }
}

# Private per-root payload mode used only by the bounded runner above: apply
# the per-process address-space limit (a positive KiB count), then exec
# /usr/bin/time for the per-root peak-RSS record when it is available, else the
# tool itself. A limit the host cannot apply exits 97 so the parent reports
# limit-unavailable instead of running uncapped.
if [ "${1:-}" = "--internal-root" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-root is private to the lint owner.\n' >&2
    exit 2
  }
  fm_lint_require_admission --internal-root
  [ "$#" -ge 4 ] || exit 2
  internal_rss_file=$2
  internal_memory_kib=$3
  shift 3
  case "$internal_memory_kib" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: --internal-root memory limit must be a positive KiB count, got %s\n' \
        "$internal_memory_kib" >&2
      exit 2
      ;;
  esac
  # The limit is the run entry's, not what the caller passes.
  [ "$internal_memory_kib" = "$FM_LINT_INTERNAL_MEMORY_KIB" ] || {
    printf 'fm-lint.sh: --internal-root memory limit %s KiB is not the lint run'"'"'s %s KiB\n' \
      "$internal_memory_kib" "$FM_LINT_INTERNAL_MEMORY_KIB" >&2
    exit 2
  }
  ulimit -v "$internal_memory_kib" 2>/dev/null || {
    printf 'fm-lint.sh: per-root memory limit %s KiB is not enforceable on this host\n' \
      "$internal_memory_kib" >&2
    exit 97
  }
  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec /usr/bin/time -l -o "$internal_rss_file" "$@"
    fi
    exec /usr/bin/time -f 'max_rss_kib=%M' -o "$internal_rss_file" "$@"
  fi
  exec "$@"
fi

# Private bounded-run mode used only by the per-root runner above: the caller
# has already moved this process into its own group, so re-enter through SELF
# keeps the watchdog out of the worker's killable group while resolving the
# shared fm_exec_timed implementation through the same source path.
if [ "${1:-}" = "--internal-timed" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-timed is private to the lint owner.\n' >&2
    exit 2
  }
  fm_lint_require_admission --internal-timed
  [ "$#" -ge 4 ] || exit 2
  declare -F fm_exec_timed >/dev/null 2>&1 || {
    printf 'fm-lint.sh: fm-timeout-lib.sh is required for bounded runs.\n' >&2
    exit 127
  }
  fm_exec_timed "$2" "$3" "${@:4}"
fi

# --- version currency -------------------------------------------------------
# The pinned versions are maintained snapshots. --check-version makes an
# upstream release visible before the pin silently diverges from CI; it uses
# only the public release API and never needs a local linter installed.
fm_lint_release_url() {  # <owner/repo>
  printf 'https://api.github.com/repos/%s/releases/latest' "$1"
}

fm_lint_latest_tag() {  # <owner/repo>; prints the tag without a leading v, or returns 2
  local repo=$1 url json tag
  command -v curl >/dev/null 2>&1 || return 2
  url=$(fm_lint_release_url "$repo")
  # measured: value=15 date=2026-10-27 host=Mac-Studio.local margin=36x (three public release API reads, slowest 0.414 s)
  json=$(curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' "$url" 2>/dev/null) || return 2
  if command -v jq >/dev/null 2>&1; then
    tag=$(printf '%s' "$json" | jq -r '.tag_name // empty' 2>/dev/null)
  else
    tag=$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  [ -n "$tag" ] || return 2
  printf '%s\n' "${tag#v}"
}

fm_lint_check_one() {  # <tool> <owner/repo> <pinned> <bump-hint>; 0 current, 1 behind, 2 unknown
  local tool=$1 repo=$2 pinned=$3 hint=$4 latest
  if latest=$(fm_lint_latest_tag "$repo"); then
    if [ "$latest" = "$pinned" ]; then
      printf '%s: pinned %s, latest %s (current)\n' "$tool" "$pinned" "$latest"
      return 0
    fi
    printf '%s: pinned %s, latest %s (BEHIND; bump %s)\n' "$tool" "$pinned" "$latest" "$hint"
    return 1
  fi
  printf '%s: pinned %s, latest UNKNOWN (could not read %s)\n' "$tool" "$pinned" "$(fm_lint_release_url "$repo")"
  return 2
}

fm_lint_check_versions() {
  local behind=0 unknown=0 current=0 rc required_actionlint
  fm_lint_check_one shellcheck koalaman/shellcheck "$REQUIRED_SHELLCHECK" \
    'REQUIRED_SHELLCHECK in bin/fm-lint.sh and the SHA table in bin/fm-install-shellcheck.sh'
  rc=$?
  case "$rc" in
    0) current=$((current + 1)) ;;
    1) behind=$((behind + 1)) ;;
    *) unknown=$((unknown + 1)) ;;
  esac
  required_actionlint=$("$SELF_DIR/fm-lint-workflows.sh" --required-version 2>/dev/null) || required_actionlint=
  if [ -n "$required_actionlint" ]; then
    fm_lint_check_one actionlint rhysd/actionlint "$required_actionlint" \
      'REQUIRED_ACTIONLINT in bin/fm-lint-workflows.sh and the SHA table in bin/fm-install-actionlint.sh'
    rc=$?
    case "$rc" in
      0) current=$((current + 1)) ;;
      1) behind=$((behind + 1)) ;;
      *) unknown=$((unknown + 1)) ;;
    esac
  else
    printf 'actionlint: pinned UNKNOWN (could not read bin/fm-lint-workflows.sh --required-version)\n'
    unknown=$((unknown + 1))
  fi
  printf 'fm-lint.sh: version check: %s behind, %s unknown, %s current\n' "$behind" "$unknown" "$current" >&2
  [ "$behind" -eq 0 ] || return 1
  [ "$unknown" -eq 0 ] || return 2
  return 0
}

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

if [ "${1:-}" = "--check-version" ]; then
  fm_lint_check_versions
  exit $?
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  if [ -r "$SELF_DIR/fm-duration.py" ]; then
    python3 "$SELF_DIR/fm-duration.py" check-literals || return $?
  fi
  local findings path canonical
  local -a purity_roots audit_command
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  # The audit is one CPU-bound awk process over every script under bin/ (measured 2.9 CPU seconds over 3.3), so it takes a pass too.
  audit_command=(awk)
  if [ -x "$SELF_DIR/fm-cpu-pass.sh" ] && [ -r "$SELF_DIR/fm-cpu-pass.py" ]; then
    audit_command=("$SELF_DIR/fm-cpu-pass.sh" run --label "fm-lint backend purity" --log-fd 8 -- awk)
  fi
  # shellcheck disable=SC2016 # The awk program is single-quoted on purpose: awk, not the shell, expands it.
  findings=$(LC_ALL=C "${audit_command[@]}" '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

JOBS=${FM_LINT_JOBS:-2}
TELEMETRY=${FM_LINT_TELEMETRY:-}
FAST=0
ANALYSIS_MODE=full
STRICT_VERSION=0
PARTITION=
PARTITION_REQUESTED=0
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires 1 or 2.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --partition)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --partition requires 1of3, 2of3 or 3of3.\n' >&2; exit 2; }
      PARTITION=$2
      PARTITION_REQUESTED=1
      shift 2
      ;;
    --partition=*)
      PARTITION=${1#*=}
      PARTITION_REQUESTED=1
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --strict-version)
      STRICT_VERSION=1
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS" in
  1|2) ;;
  *) printf 'fm-lint.sh: jobs must be 1 or 2, got %s.\n' "$JOBS" >&2; exit 2 ;;
esac

# Pass notices keep to the real stderr, never a root's captured diagnostics. A run
# inside a pass takes no further one, so it runs at most that many ShellChecks.
exec 8>&2
if [ -n "${FM_CPU_PASS_HELD+x}" ]; then
  case "$FM_CPU_PASS_HELD" in
    ''|*[!0-9]*)
      printf 'fm-lint.sh: FM_CPU_PASS_HELD must be a nonnegative decimal integer.\n' >&2
      exit 125 ;;
  esac
  inherited_passes=$FM_CPU_PASS_HELD
  while [ "${inherited_passes#0}" != "$inherited_passes" ]; do
    inherited_passes=${inherited_passes#0}
  done
  # JOBS is 1 or 2, so a count below it can only be one pass; 0 is degraded work with no limit.
  if [ "$inherited_passes" = 1 ] && [ "$JOBS" -gt 1 ]; then
    printf 'fm-lint.sh: reducing --jobs %s to inherited FM_CPU_PASS_HELD=%s\n' \
      "$JOBS" "$inherited_passes" >&2
    JOBS=1
  fi
fi

case "$PARTITION" in
  '')
    if [ "$PARTITION_REQUESTED" -eq 1 ]; then
      printf 'fm-lint.sh: --partition requires 1of3, 2of3 or 3of3.\n' >&2
      exit 2
    fi
    ;;
  1of3|2of3|3of3)
    if [ "$FAST" -eq 1 ] || [ "$#" -gt 0 ]; then
      printf 'fm-lint.sh: --partition requires full canonical lint; omit --fast and explicit paths.\n' >&2
      exit 2
    fi
    ;;
  *) printf 'fm-lint.sh: --partition must be 1of3, 2of3 or 3of3, got %s.\n' "$PARTITION" >&2; exit 2 ;;
esac

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}


CHANGED_MODE=0
EXPLICIT_PATHS=0
# Until a complete cold run proves otherwise, this invocation is not evidence
# for the canonical cold ceiling (including a zero-target changed selection).
if [ -n "${FM_DURATION_CALIBRATION_FILE:-}" ] && [ "${FM_DURATION_MANAGED_KEY:-}" = "lint.$ANALYSIS_MODE.${PARTITION:-whole}" ]; then
  printf '0\n' > "$FM_DURATION_CALIBRATION_FILE"
fi
if [ "$LIST_FILES" -eq 0 ] && ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for source selection, admission and worker cleanup.\n' >&2
  exit 127
fi
[ -r "$SELF_DIR/fm-lint-cache.pl" ] || {
  printf 'fm-lint.sh: bin/fm-lint-cache.pl is required for source-aware lint.\n' >&2
  exit 2
}
if [ "$#" -gt 0 ]; then
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ -z "$PARTITION" ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    changed_list=$(mktemp "${TMPDIR:-/tmp}/fm-lint-changes.XXXXXX") || exit 1
    selected_list=$(mktemp "${TMPDIR:-/tmp}/fm-lint-selection.XXXXXX") || { rm -f "$changed_list"; exit 1; }
    # The dependency scan is one CPU-bound process (measured 8.9 CPU seconds for one path), so it takes a pass too.
    select_command=(perl "$SELF_DIR/fm-lint-cache.pl" select "$ROOT")
    if [ -x "$SELF_DIR/fm-cpu-pass.sh" ] && [ -r "$SELF_DIR/fm-cpu-pass.py" ]; then
      select_command=("$SELF_DIR/fm-cpu-pass.sh" run --label "fm-lint select" --log-fd 8 -- "${select_command[@]}")
    fi
    if ! git diff --name-only --no-renames -z "$merge_base" -- > "$changed_list" \
      || ! git ls-files --others --exclude-standard -z >> "$changed_list" \
      || ! "${select_command[@]}" < "$changed_list" > "$selected_list"; then
      rm -f "$changed_list" "$selected_list"
      printf 'fm-lint.sh: could not select changed roots and source dependencies.\n' >&2
      exit 2
    fi
    while IFS= read -r -d '' changed_path; do
      ROOTS+=("$changed_path")
    done < "$selected_list"
    rm -f "$changed_list" "$selected_list"
  fi
fi
# Stable largest-first packing uses measured durations across CI runners and
# direct bytes across the two local workers. Neither weight is a skip rule.
TAB=$(printf '\t')
# Slowest successful per-root duration_ms from three Ubuntu main runs.
# docs/fm-test-portable-shards.md owns measurement provenance and refresh.
# Exception: the four tests/fm-pr-merge*.sh hints are apportioned estimates
# sized from the former single-file 3825 ms hint, pending measurement.
# Exception: the tests/fm-lint.test.sh, tests/fm-lint-policy.test.sh,
# tests/fm-lint-slots.test.sh, tests/fm-lint-report.test.sh, and
# tests/fm-lint-helpers.sh hints are approximate sizing estimates from each
# file's line count at the split (tests/fm-lint-report.test.sh is rounded from
# 617 lines), pending measurement; they are not Ubuntu durations.
# Hints affect assignment only, never source analysis or canonical coverage.
fm_lint_partition_weight_hints() {
  cat <<'EOF'
bin/backends/cmux.sh	3524
bin/backends/herdr.sh	15753
bin/backends/orca.sh	3322
bin/backends/tmux.sh	5429
bin/backends/zellij.sh	3623
bin/fm-afk-contract.sh	583
bin/fm-afk-launch.sh	11442
bin/fm-afk-return.sh	22823
bin/fm-afk-start.sh	7882
bin/fm-agent-process-lib.sh	565
bin/fm-agy-trust.sh	216
bin/fm-api-key-guard-lib.sh	165
bin/fm-arm-pretool-check.sh	217
bin/fm-backend-hometag-lib.sh	167
bin/fm-backend.sh	767
bin/fm-backlog-handoff.sh	54793
bin/fm-backlog-receive.sh	7935
bin/fm-backlog-transition-lib.sh	3425
bin/fm-bearings-board.sh	365
bin/fm-bearings-snapshot.sh	618
bin/fm-bootstrap.sh	34845
bin/fm-branch-outcome.sh	16653
bin/fm-branch-prompt.sh	114
bin/fm-branch-report.sh	8034
bin/fm-brief-heading-lib.sh	117
bin/fm-brief.sh	21315
bin/fm-busy-event.sh	918
bin/fm-busy-lib.sh	668
bin/fm-captain-hold.sh	24125
bin/fm-check-lib.sh	217
bin/fm-check-register.sh	2121
bin/fm-check-unregister.sh	2020
bin/fm-classify-lib.sh	7084
bin/fm-claude-launcher-lib.sh	165
bin/fm-claude-memory-lib.sh	167
bin/fm-claude-stop-autoarm.sh	8586
bin/fm-claude-trust.sh	467
bin/fm-compact-adviser-lib.sh	115
bin/fm-composer-lib.sh	2823
bin/fm-config-inherit-lib.sh	1820
bin/fm-config-push.sh	12094
bin/fm-contributions.sh	11089
bin/fm-control-lib.sh	365
bin/fm-control-worktree-lib.sh	417
bin/fm-control.sh	39808
bin/fm-cpu-pass.sh	167
bin/fm-crew-state.sh	30829
bin/fm-cursor-lib.sh	215
bin/fm-decision-hold.sh	315
bin/fm-devin-config.sh	165
bin/fm-dispatch-capacity-lib.sh	2874
bin/fm-dispatch-capacity.sh	3073
bin/fm-dispatch-resolve.sh	4828
bin/fm-doc-audience-check.sh	114
bin/fm-dod-lib.sh	10742
bin/fm-ensure-agents-md.sh	214
bin/fm-env-lib.sh	116
bin/fm-exclude-tools-lib.sh	165
bin/fm-extension.sh	117
bin/fm-ff-lib.sh	867
bin/fm-fleet-ledger.sh	16052
bin/fm-fleet-snapshot.sh	15453
bin/fm-fleet-sync.sh	568
bin/fm-fleet-view.sh	115
bin/fm-forge-detect.sh	116
bin/fm-gate-refuse-lib.sh	167
bin/fm-gemini-lib.sh	165
bin/fm-gh-rest.sh	7983
bin/fm-git-strip-ai-trailers.sh	217
bin/fm-guard.sh	7732
bin/fm-harness.sh	616
bin/fm-herdr-ci-cleanup.sh	168
bin/fm-herdr-lab.sh	570
bin/fm-herdr-session-cleanup.sh	11494
bin/fm-hold-reason-lib.sh	116
bin/fm-home-seed.sh	11088
bin/fm-home-summary-refresh.sh	7933
bin/fm-hook-host-lib.sh	116
bin/fm-host-mirror.sh	7982
bin/fm-idle-reap-lib.sh	20114
bin/fm-idle-session-reap.sh	23416
bin/fm-inactive-reconcile.sh	31391
bin/fm-inbox.sh	9488
bin/fm-install-actionlint.sh	167
bin/fm-install-herdr.sh	166
bin/fm-install-shellcheck.sh	166
bin/fm-install-treehouse.sh	166
bin/fm-jev-guard-hook.sh	116
bin/fm-kimi-turnend-hook.sh	165
bin/fm-lab-home.sh	8234
bin/fm-landed-lib.sh	120
bin/fm-launch-proof-lib.sh	867
bin/fm-lease-lib.sh	518
bin/fm-lease.sh	8133
bin/fm-line-cap-lib.sh	117
bin/fm-lint-workflows.sh	167
bin/fm-lint.sh	1418
bin/fm-live-lab.sh	8934
bin/fm-load-report.sh	114
bin/fm-lock-lib.sh	167
bin/fm-lock.sh	8184
bin/fm-mail-check.sh	2623
bin/fm-mail.sh	18559
bin/fm-marker-lib.sh	417
bin/fm-mem-guard.sh	115
bin/fm-merge-authority-lib.sh	2823
bin/fm-merge-local.sh	15548
bin/fm-merge-outcome-lib.sh	10238
bin/fm-model-catalog-lib.sh	467
bin/fm-model-freshness.sh	617
bin/fm-model-index.sh	717
bin/fm-nm-run-lib.sh	566
bin/fm-on.sh	468
bin/fm-open-loops.sh	114
bin/fm-operational-input.sh	368
bin/fm-parent-channel-lib.sh	316
bin/fm-path-lib.sh	115
bin/fm-peek.sh	868
bin/fm-pending-reply-lib.sh	20007
bin/fm-pipeline-spend.sh	2720
bin/fm-pr-check.sh	23619
bin/fm-pr-lib.sh	1718
bin/fm-pr-merge.sh	32592
bin/fm-pr-poll.sh	216
bin/fm-pr-reviewers.sh	1919
bin/fm-pr-state.sh	1969
bin/fm-primary-scope-lib.sh	166
bin/fm-proc-budget.sh	166
bin/fm-proc-guard.sh	116
bin/fm-procevent-lavish.sh	12645
bin/fm-procevent-lib.sh	1369
bin/fm-procevent-posttool-check.sh	1969
bin/fm-procevent-proc.sh	1670
bin/fm-procevent-quota.sh	11944
bin/fm-procevent-remote-reply.sh	33344
bin/fm-procevent-when.sh	12845
bin/fm-procevent.sh	17508
bin/fm-project-capacity-lib.sh	214
bin/fm-project-mode.sh	165
bin/fm-project-origin-lib.sh	166
bin/fm-promote.sh	47477
bin/fm-public-followup-collect.sh	15951
bin/fm-public-followup-emit.sh	16455
bin/fm-public-followup-lib.sh	14448
bin/fm-public-followup.sh	19310
bin/fm-push-transition-lib.sh	17257
bin/fm-quota-axi-lib.sh	167
bin/fm-quota-choose.sh	3773
bin/fm-reboot-recover.sh	1920
bin/fm-remote-delta-read.sh	315
bin/fm-remote-doctor.sh	4025
bin/fm-remote-entrypoint.sh	2019
bin/fm-remote-file.sh	7735
bin/fm-remote-herdr-guard.sh	265
bin/fm-remote-herdr-owner-lib.sh	218
bin/fm-remote-home-provision.sh	7933
bin/fm-remote-home-seed.sh	8386
bin/fm-remote-inherit-push.sh	2320
bin/fm-remote-inherit.sh	10190
bin/fm-remote-job-lib.sh	1620
bin/fm-remote-job-reap-orphans.sh	1920
bin/fm-remote-job-worker.sh	3425
bin/fm-remote-readiness-lib.sh	114
bin/fm-remote-secondmate-control.sh	27027
bin/fm-remote-secondmate-relaunch.sh	11495
bin/fm-review-diff.sh	265
bin/fm-secondmate-charter-lib.sh	115
bin/fm-secondmate-liveness-lib.sh	12245
bin/fm-secondmate-nudge-lib.sh	164
bin/fm-secondmate-parent-lib.sh	167
bin/fm-secondmate-reconcile.sh	8034
bin/fm-secondmate-registry-lib.sh	317
bin/fm-secondmate-report.sh	21417
bin/fm-secondmate-restart-lib.sh	1218
bin/fm-secondmate-restart.sh	21063
bin/fm-send.sh	44872
bin/fm-session-end-relaunch-lib.sh	22518
bin/fm-session-launch-policy-lib.sh	2171
bin/fm-session-lock-lib.sh	415
bin/fm-session-start.sh	26077
bin/fm-sessionstart-cursor.sh	115
bin/fm-sessionstart-nudge.sh	566
bin/fm-sessionstart-run.sh	668
bin/fm-skill-pick.sh	517
bin/fm-spawn.sh	59208
bin/fm-startup-growth-check.sh	2623
bin/fm-startup-memory-budget-lib.sh	215
bin/fm-startup-memory-budget.sh	268
bin/fm-startup-network.sh	8736
bin/fm-status-decision-lib.sh	1117
bin/fm-status-event-lib.sh	1571
bin/fm-status-io-lib.sh	566
bin/fm-status-record-lib.sh	165
bin/fm-status-wake-lib.sh	3074
bin/fm-stow-cascade.sh	2119
bin/fm-supervise-daemon.sh	26627
bin/fm-supervision-engine-lib.sh	367
bin/fm-supervision-host.sh	10989
bin/fm-supervision-instructions.sh	568
bin/fm-supervision-lib.sh	165
bin/fm-supervisor-target-lib.sh	116
bin/fm-tangle-lib.sh	165
bin/fm-task-copy-lib.sh	867
bin/fm-task-docker-lib.sh	616
bin/fm-task-inbox-lib.sh	467
bin/fm-tasks-axi-lib.sh	215
bin/fm-tasks-axi.sh	13147
bin/fm-teamclaude-launch.sh	317
bin/fm-teardown.sh	85068
bin/fm-test-isolation-proof.sh	415
bin/fm-test-reap-orphans.sh	7735
bin/fm-test-run.sh	1871
bin/fm-timeout-lib.sh	265
bin/fm-timing-lib.sh	171
bin/fm-tmux-lib.sh	3575
bin/fm-tool-update-check.sh	3074
bin/fm-trace-context-lib.sh	217
bin/fm-transition-lib.sh	165
bin/fm-turnend-guard-cursor.sh	9138
bin/fm-turnend-guard-grok.sh	465
bin/fm-turnend-guard.sh	8136
bin/fm-typesafe-health.sh	1500
bin/fm-typesafe-lib.sh	417
bin/fm-update.sh	2520
bin/fm-utc-lib.sh	116
bin/fm-vendor-auth-probe.sh	317
bin/fm-wake-drain.sh	19360
bin/fm-wake-grant.sh	7082
bin/fm-wake-lib.sh	6933
bin/fm-watch-arm.sh	7986
bin/fm-watch-checkpoint.sh	517
bin/fm-watch.sh	53828
bin/fm-watchdog-check.sh	43468
bin/fm-watchdog-install.sh	216
bin/fm-worker-account-lib.sh	417
bin/fm-x-dismiss.sh	5580
bin/fm-x-followup.sh	13198
bin/fm-x-lib.sh	5079
bin/fm-x-link.sh	16304
bin/fm-x-poll.sh	15852
bin/fm-x-reply.sh	6178
tests/cmux-test-safety.sh	166
tests/fixtures.sh	768
tests/fm-afk-contract.test.sh	1370
tests/fm-afk-inject-e2e.test.sh	265
tests/fm-afk-inject-herdr-e2e.test.sh	415
tests/fm-afk-launch.test.sh	19156
tests/fm-afk-pi-herdr-return-e2e.test.sh	1017
tests/fm-afk-return.test.sh	4326
tests/fm-agy-composer-live-e2e.test.sh	916
tests/fm-agy-harness.test.sh	1621
tests/fm-agy-signals-live-e2e.test.sh	866
tests/fm-arm-pretool-check.test.sh	1170
tests/fm-ask-user-authority.test.sh	718
tests/fm-backend-autodetect-smoke.test.sh	267
tests/fm-backend-cmux-smoke.test.sh	266
tests/fm-backend-cmux.test.sh	9639
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh	917
tests/fm-backend-herdr-eventwait-smoke.test.sh	216
tests/fm-backend-herdr-focus-flash-e2e.test.sh	417
tests/fm-backend-herdr-launcher-workspace-e2e.test.sh	568
tests/fm-backend-herdr-presentation-e2e.test.sh	3674
tests/fm-backend-herdr-prune-safety-e2e.test.sh	264
tests/fm-backend-herdr-recovery-lock-e2e.test.sh	14550
tests/fm-backend-herdr-respawn-idem-e2e.test.sh	217
tests/fm-backend-herdr-smoke.test.sh	468
tests/fm-backend-herdr-stale-active-tab-e2e.test.sh	165
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh	365
tests/fm-backend-herdr.test.sh	52691
tests/fm-backend-orca.test.sh	2270
tests/fm-backend-tmux-smoke.test.sh	216
tests/fm-backend-zellij-smoke.test.sh	266
tests/fm-backend-zellij.test.sh	10140
tests/fm-backend.test.sh	1768
tests/fm-backlog-atomicity.test.sh	40860
tests/fm-backlog-handoff.test.sh	1869
tests/fm-backlog-read-bound.test.sh	1067
tests/fm-bearings-board-lavish-live-e2e.test.sh	817
tests/fm-bearings-board-render.test.sh	868
tests/fm-bearings-board.test.sh	1570
tests/fm-bearings-snapshot.test.sh	3926
tests/fm-bootstrap-network-parallel.test.sh	918
tests/fm-bootstrap.test.sh	2319
tests/fm-branch-supervision.test.sh	2472
tests/fm-brief.test.sh	14800
tests/fm-busy-adapter-wiring.test.sh	1519
tests/fm-busy-state.test.sh	1317
tests/fm-calm-claude-mod-live-e2e.test.sh	1117
tests/fm-calm-claude-mod-plugin.test.sh	716
tests/fm-calm-claude-mod.test.sh	969
tests/fm-calm-pi-extension.test.sh	3072
tests/fm-calm-pi-queue-retention-live-e2e.test.sh	718
tests/fm-captain-hold-archive.test.sh	1324
tests/fm-captain-hold-cleanup.test.sh	2765
tests/fm-captain-hold-keyed-answers.test.sh	1806
tests/fm-captain-hold-lifecycle-helpers.sh	438
tests/fm-captain-hold-lifecycle.test.sh	2388
tests/fm-captain-hold-reconcile.test.sh	2543
tests/fm-captain-hold-sweep.test.sh	1481
tests/fm-check-unregister.test.sh	868
tests/fm-ci-workflow.test.sh	867
tests/fm-classify-corr-token.test.sh	10038
tests/fm-classify-decision-key.test.sh	9639
tests/fm-claude-nested-home-live-e2e.test.sh	1670
tests/fm-claude-stop-autoarm-live-e2e.test.sh	967
tests/fm-claude-stop-autoarm.test.sh	3021
tests/fm-claude-titled-composer-live-e2e.test.sh	1268
tests/fm-claude-trust.test.sh	1718
tests/fm-cmux-claude-composer-live-e2e.test.sh	1671
tests/fm-codex-continuity-live-e2e.test.sh	718
tests/fm-codex-hook-layer-live-e2e.test.sh	919
tests/fm-composer-codex-idle-live-e2e.test.sh	818
tests/fm-composer-ghost.test.sh	1220
tests/fm-composer-lib.test.sh	3625
tests/fm-composer-matrix-live-e2e.test.sh	967
tests/fm-composer-native-band.test.sh	1370
tests/fm-composer-native-continuation.test.sh	1067
tests/fm-composer-native-idle-hint.test.sh	4024
tests/fm-contributions-read-saved.test.sh	768
tests/fm-contributions.test.sh	2221
tests/fm-control-herdr-smoke.test.sh	1069
tests/fm-control-reassociate.test.sh	3073
tests/fm-control-relaunch-backends.test.sh	2997
tests/fm-control-relaunch-helpers.sh	1839
tests/fm-control-relaunch-recovery.test.sh	2724
tests/fm-control-relaunch.test.sh	2922
tests/fm-control.test.sh	9788
tests/fm-cpu-pass.test.sh	1370
tests/fm-crew-state.test.sh	6482
tests/fm-cursor-harness.test.sh	7933
tests/fm-cursor-primary-live-e2e.test.sh	866
tests/fm-cursor-primary.test.sh	1518
tests/fm-daemon.test.sh	41764
tests/fm-devin-harness.test.sh	6330
tests/fm-devin-signals-live-e2e.test.sh	7082
tests/fm-dispatch-capacity.test.sh	4427
tests/fm-dispatch-resolve.test.sh	2923
tests/fm-documentation-audiences.test.sh	767
tests/fm-dod-lib.test.sh	13247
tests/fm-ensure-agents-md.test.sh	1069
tests/fm-extension-binding.test.sh	6682
tests/fm-fleet-ledger.test.sh	13697
tests/fm-fleet-snapshot-contribution-cleanup.test.sh	767
tests/fm-fleet-snapshot-fleet-cost.test.sh	769
tests/fm-fleet-snapshot-rolling-window.test.sh	766
tests/fm-fleet-snapshot-tmp-leak.test.sh	766
tests/fm-fleet-snapshot-view.test.sh	9835
tests/fm-fleet-sync.test.sh	1318
tests/fm-forge-detect.test.sh	768
tests/fm-fork-free-helpers.test.sh	817
tests/fm-gate-refuse.test.sh	1419
tests/fm-gemini-harness.test.sh	1119
tests/fm-gh-rest.test.sh	1267
tests/fm-git-strip-ai-trailers.test.sh	3174
tests/fm-gitignore-config.test.sh	167
tests/fm-gotmp.test.sh	217
tests/fm-grok-continuity-live-e2e.test.sh	816
tests/fm-grok-harness.test.sh	968
tests/fm-grok-stop-live-e2e.test.sh	967
tests/fm-guard-stale-banner.test.sh	1568
tests/fm-harness-adapter-instructions-live-e2e.test.sh	917
tests/fm-harness-adapter-references.test.sh	668
tests/fm-harness-liveness-drift-live-e2e.test.sh	868
tests/fm-harness-precedence.test.sh	1270
tests/fm-herdr-attached-viewer-live-e2e.test.sh	917
tests/fm-herdr-lab.test.sh	1418
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh	869
tests/fm-herdr-session-cleanup-e2e.test.sh	215
tests/fm-herdr-session-cleanup.test.sh	1068
tests/fm-herdr-submit-confirm-live-e2e.test.sh	1470
tests/fm-herdr-version-floor-live-e2e.test.sh	819
tests/fm-home-summary-refresh-ownership.test.sh	668
tests/fm-home-summary-refresh.test.sh	2672
tests/fm-host-mirror-live-e2e.test.sh	5979
tests/fm-host-mirror.test.sh	1069
tests/fm-idle-session-reap.test.sh	34944
tests/fm-inactive-reconcile.test.sh	1771
tests/fm-inbox.test.sh	1420
tests/fm-jev-guard.test.sh	1018
tests/fm-keep-ai-trailers-home-local.test.sh	1620
tests/fm-kimi-harness.test.sh	1819
tests/fm-launch-prompt-signals-live-e2e.test.sh	56051
tests/fm-launch-proof.test.sh	15948
tests/fm-lint-workflows.test.sh	1069
tests/fm-lint-report.test.sh	600
tests/fm-lint-policy.test.sh	452
tests/fm-lint-slots.test.sh	1437
tests/fm-lint.test.sh	1083
tests/fm-lint-helpers.sh	552
tests/fm-live-gate.test.sh	1119
tests/fm-live-lab-up-mate.test.sh	967
tests/fm-live-lab.test.sh	2070
tests/fm-load-report.test.sh	968
tests/fm-mail-check.test.sh	1118
tests/fm-mail.test.sh	2473
tests/fm-mem-guard.test.sh	117
tests/fm-model-freshness.test.sh	1318
tests/fm-model-index-live-e2e.test.sh	1217
tests/fm-model-index.test.sh	5728
tests/fm-model-picker.test.sh	900
tests/fm-muse-harness.test.sh	4074
tests/fm-muse-signals-live-e2e.test.sh	6831
tests/fm-nm-test-contract.test.sh	667
tests/fm-no-mistakes-required.test.sh	719
tests/fm-omp-composer-box-live-e2e.test.sh	2019
tests/fm-omp-fallback-chain-live-e2e.test.sh	1067
tests/fm-omp-harness.test.sh	11440
tests/fm-omp-primary-live-e2e.test.sh	969
tests/fm-omp-reboot-live-e2e.test.sh	2924
tests/fm-omp-stale-wake-live-e2e.test.sh	766
tests/fm-omp-task-session-live-e2e.test.sh	668
tests/fm-omp-wake-restore-live-e2e.test.sh	2671
tests/fm-omp-wake-turns.test.sh	114
tests/fm-on.test.sh	3322
tests/fm-open-loops.test.sh	818
tests/fm-opencode-primary-live-e2e.test.sh	1019
tests/fm-operational-input.test.sh	916
tests/fm-orphan-safety.test.sh	868
tests/fm-parent-channel-scan-exclusion.test.sh	968
tests/fm-peek-remote.test.sh	719
tests/fm-pending-reply.test.sh	43161
tests/fm-pi-branch-extension.test.sh	1921
tests/fm-pi-branch-live-e2e.test.sh	867
tests/fm-pi-branch-responsiveness-live-e2e.test.sh	867
tests/fm-pi-codex-native.test.sh	716
tests/fm-pi-primary-live-e2e.test.sh	1069
tests/fm-pi-primary-types.test.sh	165
tests/fm-pi-seeded-home-trust-live-e2e.test.sh	818
tests/fm-pi-watch-extension.test.sh	2420
tests/fm-pi-watch-loader-live.test.sh	717
tests/fm-pi-windows-shell-invocation.test.sh	716
tests/fm-pipeline-spend.test.sh	968
tests/fm-pr-check-security.test.sh	13798
tests/fm-pr-merge-checks.test.sh	1280
tests/fm-pr-merge-forges.test.sh	1250
tests/fm-pr-merge-helpers.sh	240
tests/fm-pr-merge.test.sh	1250
tests/fm-pr-reviewers.test.sh	767
tests/fm-pr-state-live-e2e.test.sh	716
tests/fm-pr-state.test.sh	869
tests/fm-proc-budget.test.sh	1067
tests/fm-proc-guard.test.sh	1018
tests/fm-procevent-proc.test.sh	969
tests/fm-procevent-quota.test.sh	416
tests/fm-procevent-runner-backlog.test.sh	1067
tests/fm-procevent-runner-custody.test.sh	969
tests/fm-procevent-when.test.sh	3472
tests/fm-procevent.test.sh	58841
tests/fm-project-capacity.test.sh	1318
tests/fm-project-origin.test.sh	816
tests/fm-public-followup.test.sh	22319
tests/fm-quota-array-dispatch-live-e2e.test.sh	768
tests/fm-quota-choose.test.sh	515
tests/fm-remote-backlog-handoff.test.sh	1518
tests/fm-remote-delta-read.test.sh	916
tests/fm-remote-doctor.test.sh	1819
tests/fm-remote-entrypoint.test.sh	767
tests/fm-remote-herdr-guard.test.sh	1370
tests/fm-remote-job-claim-reap.test.sh	4826
tests/fm-remote-job-claim-retention.test.sh	2620
tests/fm-remote-job-launchagent.test.sh	3123
tests/fm-remote-job-orphan-reap.test.sh	869
tests/fm-remote-job.test.sh	11845
tests/fm-remote-reply.test.sh	36703
tests/fm-remote-secondmate-lifecycle-e2e.test.sh	5327
tests/fm-remote-secondmate-parent-binding.test.sh	3073
tests/fm-remote-secondmate-relaunch.test.sh	3673
tests/fm-remote-secondmate-trace-context.test.sh	968
tests/fm-remote-transport-lanes.test.sh	3472
tests/fm-review-diff.test.sh	869
tests/fm-rovo-harness.test.sh	9038
tests/fm-rovo-signals-live-e2e.test.sh	1520
tests/fm-secondmate-harness.test.sh	3473
tests/fm-secondmate-lifecycle-e2e.test.sh	1068
tests/fm-secondmate-liveness.test.sh	1568
tests/fm-secondmate-reconcile.test.sh	1819
tests/fm-secondmate-restart.test.sh	2420
tests/fm-secondmate-safety.test.sh	13245
tests/fm-secondmate-sync.test.sh	3024
tests/fm-send-agy-confirm.test.sh	768
tests/fm-send-inbox-doorbell-live-e2e.test.sh	917
tests/fm-send-inbox.test.sh	1217
tests/fm-send-popup-settle.test.sh	766
tests/fm-send-remote-delivery.test.sh	24769
tests/fm-send-resolve-key.test.sh	1670
tests/fm-send-secondmate-marker-herdr-e2e.test.sh	818
tests/fm-send-secondmate-marker.test.sh	919
tests/fm-send-settle.test.sh	817
tests/fm-send-strict.test.sh	917
tests/fm-session-end-relaunch.test.sh	2070
tests/fm-session-launch-policy-inherit.test.sh	3073
tests/fm-session-launch-policy-receipt.test.sh	11692
tests/fm-session-launch-policy.test.sh	2471
tests/fm-session-lock-ancestry.test.sh	1468
tests/fm-session-start.test.sh	4278
tests/fm-sessionstart-hook-live-e2e.test.sh	1119
tests/fm-sessionstart-instruction-refresh-live-e2e.test.sh	869
tests/fm-sessionstart-nudge.test.sh	1270
tests/fm-shared-captain-inheritance.test.sh	1269
tests/fm-skill-pick.test.sh	2724
tests/fm-spawn-acquisition-cleanup.test.sh	71683
tests/fm-spawn-acquisition-herdr-e2e.test.sh	114
tests/fm-spawn-batch.test.sh	818
tests/fm-spawn-claude-api-key-guard.test.sh	1370
tests/fm-spawn-claude-start-confirm.test.sh	1067
tests/fm-spawn-compact-adviser-disable-remote.test.sh	917
tests/fm-spawn-compact-adviser-disable.test.sh	1571
tests/fm-spawn-dispatch-profile.test.sh	3923
tests/fm-spawn-herdr-launch-shell.test.sh	1068
tests/fm-spawn-orca-worktree.test.sh	969
tests/fm-spawn-pool-base-freshen.test.sh	1818
tests/fm-spawn-retained-copy.test.sh	17409
tests/fm-spawn-worktree-settle.test.sh	1017
tests/fm-startup-growth-check.test.sh	3375
tests/fm-startup-memory-budget.test.sh	969
tests/fm-startup-network.test.sh	1720
tests/fm-stat-shadowing.test.sh	68234
tests/fm-stow-cascade.test.sh	1019
tests/fm-supervision-events.test.sh	1217
tests/fm-supervision-fork-budget.test.sh	867
tests/fm-supervision-host-attended-live-e2e.test.sh	6430
tests/fm-supervision-host-helpers.sh	1068
tests/fm-supervision-host-hook.test.sh	1720
tests/fm-supervision-host-live-e2e.test.sh	867
tests/fm-supervision-host.test.sh	3825
tests/fm-supervision-instructions.test.sh	1067
tests/fm-tangle-guard.test.sh	1118
tests/fm-task-delivery.test.sh	2372
tests/fm-task-docker-live-e2e.test.sh	1570
tests/fm-task-inbox.test.sh	2322
tests/fm-tasks-axi.test.sh	2121
tests/fm-teamclaude-launch-live-e2e.test.sh	718
tests/fm-teamclaude-launch.test.sh	1119
tests/fm-teardown-cleanup.test.sh	4219
tests/fm-teardown-endpoint-safety.test.sh	2321
tests/fm-teardown-helpers.sh	2194
tests/fm-teardown-pool.test.sh	2043
tests/fm-teardown.test.sh	1830
tests/fm-test-fixture-cleanup.test.sh	819
tests/fm-test-fixtures.test.sh	1270
tests/fm-test-isolation-proof.test.sh	917
tests/fm-test-reap-orphans.test.sh	1569
tests/fm-test-run.test.sh	3424
tests/fm-timeout-lib.test.sh	4425
tests/fm-tmux-agent-liveness.test.sh	6178
tests/fm-tmux-submit-busy.test.sh	9088
tests/fm-tool-update-check.test.sh	1669
tests/fm-trace-context-lib.test.sh	916
tests/fm-trace-context-spawn.test.sh	1270
tests/fm-transition-lib.test.sh	716
tests/fm-turnend-foreign-owner-arm-fix.test.sh	116
tests/fm-turnend-guard.test.sh	3224
tests/fm-typesafe-health.test.sh	1500
tests/fm-typesafe-key-source.test.sh	1068
tests/fm-update.test.sh	1119
tests/fm-vendor-auth-probe.test.sh	967
tests/fm-voice-relay.test.sh	1820
tests/fm-wake-daemon-lifecycle-e2e.test.sh	1019
tests/fm-wake-drain-open-decisions-cursor.test.sh	1620
tests/fm-wake-drain-open-decisions.test.sh	1019
tests/fm-wake-drain-outcome-backstop.test.sh	1369
tests/fm-wake-drain-unread-status.test.sh	19612
tests/fm-wake-queue.test.sh	5478
tests/fm-watch-arm.test.sh	2822
tests/fm-watch-checkpoint.test.sh	1017
tests/fm-watch-idle-reap.test.sh	1269
tests/fm-watch-open-loops.test.sh	1969
tests/fm-watch-recovery-loop.test.sh	1067
tests/fm-watch-triage.test.sh	11895
tests/fm-watch-typesafe-health.test.sh	1200
tests/fm-watchdog-check.test.sh	1217
tests/fm-watcher-lock.test.sh	2773
tests/fm-worker-account-live-e2e.test.sh	1220
tests/fm-worker-account.test.sh	1668
tests/fm-x-mode.test.sh	4825
tests/git-config-helpers.sh	117
tests/herdr-client-pair-fixture.sh	114
tests/herdr-test-safety.sh	116
tests/lib.sh	618
tests/remote-herdr-fixture.sh	114
tests/secondmate-helpers.sh	716
tests/wake-helpers.sh	817
tests/zellij-test-safety.sh	113
EOF
}

fm_lint_root_weights() {
  local index=1 path weight
  for path in "${ROOTS[@]}"; do
    case "$path" in
      *"$TAB"*|*$'\n'*)
        printf 'fm-lint.sh: paths containing tabs or newlines are not supported: %s\n' "$path" >&2
        return 2
        ;;
    esac
    weight=1
    if [ -f "$path" ]; then
      weight=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$weight" in ''|*[!0-9]*) weight=1 ;; esac
    printf '%s\t%s\t%s\n' "$weight" "$index" "$path"
    index=$((index + 1))
  done
}

if [ -n "$PARTITION" ]; then
  PARTITION_ROOTS=()
  partition_weights=$(set -o pipefail; fm_lint_root_weights | awk -F '\t' '
    NR == FNR { hint[$1]=$2; next }
    { printf "%s\t%s\t%s\n", (($3 in hint) ? hint[$3] : 6000), $2, $3 }
  ' <(fm_lint_partition_weight_hints) -) || exit $?
  while IFS="$TAB" read -r index path; do
    PARTITION_ROOTS+=("$path")
  done < <(printf '%s\n' "$partition_weights" | LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n | awk -F '\t' -v want="${PARTITION%%of*}" '
    {
      shard=1
      for (candidate=2; candidate<=3; candidate++)
        if (load[candidate] < load[shard]) shard=candidate
      load[shard]+=$1
      if (shard == want) print $2 "\t" $3
    }
  ' | LC_ALL=C sort -t "$TAB" -k1,1n)
  ROOTS=("${PARTITION_ROOTS[@]}")
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

# Per-root bounded-execution envelope. Under FM_LINT_REQUIRE_BOUNDS=1 the
# watchdog is probed and the host's acceptance of ulimit -v is checked before
# any root starts; failed checks refuse with a named error. A required-bounds run
# never lints uncapped. Without it each root still runs alone in its own
# ShellCheck process, unbounded, for local developer lint.
ROOT_SECONDS=${FM_LINT_ROOT_SECONDS:-1200}
ROOT_GRACE=${FM_LINT_ROOT_GRACE:-5}
# 12 GiB of virtual address space per analysis process. ulimit -v caps
# address space, not resident memory; ShellCheck's GHC runtime reserves about
# a third of that space, leaving ~8 GiB usable heap per root. Measured x86_64
# demand for the heaviest roots is near 5.5-6 GiB: the 8 GiB address-space
# cap's ~5.33 GiB wall caught bin/fm-spawn.sh, bin/fm-teardown.sh,
# tests/fm-pending-reply.test.sh, and
# tests/fm-launch-prompt-signals-live-e2e.test.sh. CI runs one root per
# lint job, so worst-case resident demand is ~8 GiB plus runner overhead,
# inside the 16 GiB runner. Local lint defaults to two workers; two such
# caps allow ~16 GiB resident plus host overhead, so use FM_LINT_JOBS=1 on
# smaller local machines. A root that exceeds its cap fails by name.
# Never drop diagnostic rules or leave a source owner unchecked to fit a root
# under its cap. The roots sidecar records peak RSS even without bounds; roots
# peaking above about 3 GiB resident remain source-graph reduction candidates.
ROOT_MEMORY_KIB=${FM_LINT_ROOT_MEMORY_KIB:-12582912}
# 8 GiB of memory (resident size or footprint) per analysis tree on native macOS without the enforced envelope.
# Native macOS has no ulimit -v, so a source-following root there could grow
# without bound (tests/fm-spawn-acquisition-cleanup.test.sh reached 65 GB);
# the resident-memory watch ends such a root and takes the memory retry.
# The bound equals the ~8 GiB usable heap the 12 GiB address-space cap above
# leaves a root, so it admits every root the enforced envelope admits.
ROOT_RSS_KIB=${FM_LINT_ROOT_RSS_KIB:-8388608}
for bound_pair in \
  "FM_LINT_ROOT_SECONDS=$ROOT_SECONDS" \
  "FM_LINT_ROOT_GRACE=$ROOT_GRACE" \
  "FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB" \
  "FM_LINT_ROOT_RSS_KIB=$ROOT_RSS_KIB"; do
  case "${bound_pair#*=}" in
    ''|0*|*[!0-9]*)
      printf 'fm-lint.sh: %s must be a positive integer, got %s.\n' \
        "${bound_pair%%=*}" "${bound_pair#*=}" >&2
      exit 2
      ;;
  esac
done
# A request above the default would let one root enlarge the host total past the
# per-root cap, so it runs at the default and both values are logged. The digit
# count is compared first so that a very long number never reaches shell arithmetic.
ROOT_RSS_DEFAULT_KIB=8388608
ROOT_RSS_REQUESTED_KIB=''
if [ "${#ROOT_RSS_KIB}" -gt 7 ] || { [ "${#ROOT_RSS_KIB}" -eq 7 ] && [ "$ROOT_RSS_KIB" -gt "$ROOT_RSS_DEFAULT_KIB" ]; }; then
  ROOT_RSS_REQUESTED_KIB=$ROOT_RSS_KIB
  ROOT_RSS_KIB=$ROOT_RSS_DEFAULT_KIB
  printf 'fm-lint.sh: FM_LINT_ROOT_RSS_KIB=%s is above the %s KiB per-root cap; the lint runs at %s KiB.\n' \
    "$ROOT_RSS_REQUESTED_KIB" "$ROOT_RSS_DEFAULT_KIB" "$ROOT_RSS_KIB" >&2
fi

BOUND_MECH=none
if [ "${FM_LINT_REQUIRE_BOUNDS:-0}" = 1 ]; then
  bounds_problems=()
  if declare -F fm_exec_timed >/dev/null 2>&1; then
    # perl is mandatory above, so fm_exec_timed always takes its perl watchdog.
    BOUND_MECH=perl
  else
    bounds_problems+=('bin/fm-timeout-lib.sh is missing beside fm-lint.sh, so no watchdog is available')
  fi
  if [ "$BOUND_MECH" != none ]; then
    # Exercise the real bound end to end before any root starts: a clean probe
    # must exit 0 and an over-deadline probe must come back as a timeout, so a
    # watchdog that cannot actually bound a command (a perl without
    # Time::HiRes, say) refuses the run here instead of failing every root at
    # run time.
    probe_rc=0
    ( fm_exec_timed 30 1 true ) >/dev/null 2>&1 || probe_rc=$?
    if [ "$probe_rc" -ne 0 ]; then
      bounds_problems+=("the timeout watchdog could not run a probe command (rc=$probe_rc)")
    else
      probe_rc=0
      ( fm_exec_timed 2 1 sleep 30 ) >/dev/null 2>&1 || probe_rc=$?
      case "$probe_rc" in
        124|137) : ;;
        *) bounds_problems+=("the timeout watchdog did not bound an over-deadline probe (rc=$probe_rc)") ;;
      esac
    fi
  fi
  ( ulimit -v "$ROOT_MEMORY_KIB" ) 2>/dev/null \
    || bounds_problems+=("per-root memory limit FM_LINT_ROOT_MEMORY_KIB=$ROOT_MEMORY_KIB KiB is not enforceable on this host (ulimit -v)")
  if [ "${#bounds_problems[@]}" -gt 0 ]; then
    for problem in "${bounds_problems[@]}"; do
      printf 'fm-lint.sh: bounds required but %s.\n' "$problem" >&2
    done
    printf 'fm-lint.sh: refusing to lint uncapped under FM_LINT_REQUIRE_BOUNDS=1.\n' >&2
    exit 2
  fi
fi

# The resident-memory watch starts each libproc reader with the real python3
# interpreter, resolved once per lint, so no shim (pyenv's, say) starts between
# it and each reader; plain python3 is used only when resolution fails.
WATCH_PYTHON=python3
if [ "$BOUND_MECH" = none ] && [ "$(uname)" = Darwin ]; then
  resolved_python=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null) || resolved_python=
  if [ "${resolved_python#/}" != "$resolved_python" ] && [ -x "$resolved_python" ]; then
    WATCH_PYTHON=$resolved_python
  fi
fi

# Host-wide pool configuration; the header owns its public controls.
# The default directory belongs to the user, not to HOME or XDG_CACHE_HOME, so
# runs from different homes and sandboxes meet in one pool.
HOST_POOL_DIR=$HOST_POOL_ROOT/lint-slots
SLOT_DIR=$HOST_POOL_DIR
if [ -n "${FM_LINT_SLOT_DIR:-}" ]; then
  if [ "$FM_LINT_SLOT_DIR" = off ]; then
    printf 'fm-lint.sh: FM_LINT_SLOT_DIR=off is not supported: no setting turns the host-wide ShellCheck memory bound off. Unset FM_LINT_SLOT_DIR to use the host pool %s.\n' \
      "$HOST_POOL_DIR" >&2
    exit 2
  fi
  SLOT_DIR=$FM_LINT_SLOT_DIR
fi
# The host-wide ShellCheck memory budget (HOST_RSS_KIB, set at the top of this
# script) has one value, the default documented in the header; no environment
# variable or flag sets it.
if [ -n "${FM_LINT_HOST_RSS_KIB:-}" ]; then
  printf 'fm-lint.sh: FM_LINT_HOST_RSS_KIB is not supported: the host-wide ShellCheck memory bound is fixed at %s KiB and no setting changes it. Unset FM_LINT_HOST_RSS_KIB.\n' \
    "$HOST_RSS_KIB" >&2
  exit 2
fi
case "${FM_LINT_HOST_SLOTS:-1}" in
  ''|0*|*[!0-9]*)
    printf 'fm-lint.sh: FM_LINT_HOST_SLOTS must be a positive integer, got %s.\n' \
      "${FM_LINT_HOST_SLOTS:-}" >&2
    exit 2
    ;;
esac
NCPU=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null) || NCPU=
case "$NCPU" in ''|0*|*[!0-9]*) NCPU=1 ;; esac

PROGRESS=0
if [ -n "$PARTITION" ]; then
  PROGRESS=1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_stop_workers() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  ACTIVE_PIDS=()
}
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  fm_lint_stop_workers
  rm -rf "$TMP_ROOT"
  [ -z "${RUN_ENTRY:-}" ] || rm -f "$RUN_ENTRY"
}
FM_LINT_DURATION_LOAD=
if declare -F fm_duration_load >/dev/null 2>&1; then
  FM_LINT_DURATION_LOAD=$(fm_duration_load)
fi
FM_LINT_DURATION_START=$(fm_lint_now_ms)
# shellcheck disable=SC2329 # Invoked by EXIT trap.
fm_lint_finish() {
  local result=$? calibration=0
  fm_lint_stop_workers
  if [ "${FM_LINT_WATCH_RUN:-0}" = 1 ]; then
    fm_lint_report_watch_run "${OUTPUT_DIR:-}/watch-longest.tsv"
  fi
  if [ "$EXPLICIT_PATHS" -eq 0 ] && [ "$CHANGED_MODE" -eq 0 ] && [ -s "${ROOTS_LOG:-}" ]; then
    calibration=$(awk -F '\t' '$1 == "end" { count++; if ($13 != 1) ineligible++ } END { print (count > 0 && !ineligible) ? 1 : 0 }' "$ROOTS_LOG")
  fi
  if [ -n "${FM_DURATION_CALIBRATION_FILE:-}" ] && [ "${FM_DURATION_MANAGED_KEY:-}" = "lint.$ANALYSIS_MODE.${PARTITION:-whole}" ]; then
    printf '%s\n' "$calibration" > "$FM_DURATION_CALIBRATION_FILE"
  fi
  if declare -F fm_duration_record_batch >/dev/null 2>&1; then
    {
      if [ -s "${ROOTS_LOG:-}" ]; then
        awk -F '\t' -v OFS='\t' '$1 == "end" { print "lint-root." ($5 == "" ? "full" : $5) "." $3, $8, $9, $13, $14, $15, ($10 == "timeout" ? 1 : 0) }' "$ROOTS_LOG"
      fi
      printf 'lint.%s.%s\t%s\t%s\t%s\t%s\t%s\t0\n' "$ANALYSIS_MODE" "${PARTITION:-whole}" \
        "$(( $(fm_lint_now_ms) - FM_LINT_DURATION_START ))" "$result" "$calibration" \
        "$FM_LINT_DURATION_LOAD" "$(fm_duration_load)"
    } | fm_duration_record_batch
  fi
  fm_lint_cleanup
}
trap fm_lint_finish EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"

# A pool that cannot be used must stop the run before any root starts: the
# host-wide memory bound would otherwise be lost silently. Each gate repeats the
# check for its own files and refuses the same way (bin/fm-lint-cache.pl).
pool_problem=
if [ -L "$HOST_POOL_ROOT" ]; then
  pool_problem="$HOST_POOL_ROOT is a symbolic link"
else
  ( umask 077; mkdir -p "$HOST_POOL_ROOT" ) 2>/dev/null
  if [ ! -d "$HOST_POOL_ROOT" ]; then
    pool_problem="$HOST_POOL_ROOT cannot be created"
  elif [ ! -O "$HOST_POOL_ROOT" ]; then
    pool_problem="$HOST_POOL_ROOT is owned by another user"
  fi
fi
if [ -z "$pool_problem" ]; then
  ( umask 077; mkdir -p "$SLOT_DIR" ) 2>/dev/null
  if ! { [ -d "$SLOT_DIR" ] && [ -w "$SLOT_DIR" ]; }; then
    pool_problem="$SLOT_DIR is not a writable directory"
    [ "$SLOT_DIR" = "$HOST_POOL_DIR" ] || pool_problem="FM_LINT_SLOT_DIR: $pool_problem"
  fi
fi
if [ -n "$pool_problem" ]; then
  printf 'fm-lint.sh: host slot pool unusable (%s); the host-wide ShellCheck memory bound cannot be enforced, so no root was started. Make that path writable or remove it if it is damaged.\n' \
    "$pool_problem" >&2
  exit 2
fi

# This run's entry in the host ledger: the values that bound every root it starts
# (the perl and python it resolved, the bound mechanism, the per-root address-space
# and resident limits). The run holds the entry's flock on descriptor 9 for its
# whole life (its workers inherit it), so the entry is live exactly while the run
# is. The private modes read their bounds from this entry and from nothing else.
# The same step removes the entries of runs that have ended.
( umask 077; mkdir -p "$HOST_LEDGER_DIR" ) 2>/dev/null
RUN_ENTRY=$HOST_LEDGER_DIR/run.$$.$(date +%s)
# shellcheck disable=SC2016  # $fh, $old and $other are Perl variables in the -e program.
# The entry is locked before it is filled, and only an entry whose lock is free and
# that is more than a minute old is removed, so no run removes another run's entry
# in the instant between its creation and its lock.
if ! { [ -d "$HOST_LEDGER_DIR" ] && [ ! -L "$HOST_LEDGER_DIR" ] \
  && ( umask 077; : >> "$RUN_ENTRY" ) 2>/dev/null \
  && exec 9>>"$RUN_ENTRY" \
  && "$PERL_BIN" -MFcntl=:flock -e 'open(my $fh, ">>&=", 9) or exit 1; flock($fh, LOCK_EX | LOCK_NB) or exit 1; for my $old (glob "$ARGV[0]/run.*") { next if $old eq $ARGV[1] || time() - ((stat $old)[9] // time()) < 60; open(my $other, ">>", $old) or next; unlink $old if flock($other, LOCK_EX | LOCK_NB); }' "$HOST_LEDGER_DIR" "$RUN_ENTRY" \
  && printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$$" "$PERL_BIN" "$WATCH_PYTHON" "$BOUND_MECH" "$ROOT_MEMORY_KIB" "$ROOT_RSS_KIB" > "$RUN_ENTRY"; }; then
  printf 'fm-lint.sh: host ledger unusable (%s cannot hold this run'"'"'s entry); the host-wide ShellCheck memory bound cannot be enforced, so no root was started. Make that path writable or remove it if it is damaged.\n' \
    "$HOST_LEDGER_DIR" >&2
  exit 2
fi

# The gate admits no root without a readable host process table, so read it once
# here, before any root starts: a host that cannot give it fails this run in
# about 5 s, not 5 s for every root, and holds no place in the shared queue.
if ! census_problem=$(FM_LINT_INTERNAL_HOST_RSS_KIB="$ROOTS_RSS_KIB" \
    FM_LINT_INTERNAL_PYTHON="$WATCH_PYTHON" "$PERL_BIN" "$SELF_DIR/fm-lint-cache.pl" census \
    "$SLOT_DIR" "$NCPU" "$$" "$TMP_ROOT/census.wait" -- true 2>&1); then
  printf '%s\n' "$census_problem" >&2
  exit 2
fi

# The version pin is enforced, as before, when this run passes --strict-version, in
# CI (GITHUB_ACTIONS or CI set to true), or when FM_LINT_STRICT_VERSION=1 is
# inherited from the environment (Main 1806 restored that last case). The
# off-macOS memory-cap refusal below keys only on this run's own --strict-version
# (Main 1801). Outside macOS the per-root resident cap (FM_LINT_ROOT_RSS_KIB) and
# the 64 MiB version-probe lane are not enforced: without FM_LINT_REQUIRE_BOUNDS=1
# nothing holds them, and with it only the per-process address-space limit
# (FM_LINT_ROOT_MEMORY_KIB) applies, which is not a resident-memory cap. So on CI
# and every other non-macOS run no memory cap is claimed or enforced: CI does not
# pass --strict-version, keeps its version pin and lints as before, and the
# host-wide admission still counts every root it starts. A run's own
# --strict-version refuses off macOS, whatever the bound mechanism, before any
# ShellCheck starts; any other run there says so on stderr.
if [ "$STRICT_VERSION" -eq 1 ] || [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ] || [ "${FM_LINT_STRICT_VERSION:-0}" = 1 ]; then
  FM_LINT_STRICT_VERSION=1
else
  FM_LINT_STRICT_VERSION=0
fi
export FM_LINT_STRICT_VERSION
if [ "$(uname)" != Darwin ]; then
  if [ "$STRICT_VERSION" -eq 1 ]; then
    printf 'fm-lint.sh: strict mode refuses on %s: the per-root resident cap (FM_LINT_ROOT_RSS_KIB) and the 64 MiB version-probe lane cannot be enforced on this host (the resident watch runs on macOS only; FM_LINT_REQUIRE_BOUNDS=1 applies only an address-space limit). Run strict lints on macOS.\n' "$(uname)" >&2
    exit 2
  fi
  if [ "$BOUND_MECH" = none ]; then
    printf 'fm-lint.sh: WARNING: on %s without FM_LINT_REQUIRE_BOUNDS=1 the per-root resident cap and the 64 MiB version-probe lane are not enforced; the host-wide admission still counts every root, by its charge only, because no resident watch measures roots here.\n' "$(uname)" >&2
  else
    printf 'fm-lint.sh: WARNING: on %s no memory cap is enforced: the per-root resident cap and the 64 MiB version-probe lane do not apply, and the %s KiB per-process address-space limit is not a resident-memory cap; the host-wide admission still counts every root, by its charge only, because no resident watch measures roots here.\n' "$(uname)" "$ROOT_MEMORY_KIB" >&2
  fi
fi

# The version probe is a ShellCheck start like any other: every run probes its own
# ShellCheck, in every mode except --list-files (which starts no ShellCheck), and
# the version policy applies to what that probe printed. No version is remembered
# or shared across runs: nothing proves which ShellCheck a launcher (a script, or a
# compiled program) runs for a given HOME and environment. The probe has its own lane
# in the host-wide budget (PROBE_RESERVE_KIB, one probe at a time on the host, held
# to that many KiB by the resident watch on native macOS, to the per-root
# address-space limit under the enforced envelope, and by nothing on another host
# without it), and the roots' admission works with the rest (ROOTS_RSS_KIB), so a
# run with no root to analyse waits only for another probe, never behind
# roots holding the budget, and reserves nothing in the roots' budget. The lane is a
# record naming the probe by its exact identity; it frees only when that probe has
# provably ended, never because its run or a descriptor died. A probe past
# PROBE_BOUND_SECONDS keeps the lane; it and every run waiting that long report
# "blocked" on stderr and wait, and nothing ends it.
probe_rc=0
resolved=
probe_command=("$SHELLCHECK_BIN" --version)
if [ "$BOUND_MECH" != none ]; then
  # shellcheck disable=SC2016  # $1 is the inner shell's argument.
  probe_command=("${BASH:-bash}" -c 'ulimit -v "$1" 2>/dev/null || exit 97; shift; exec "$@"' fm-lint-probe "$ROOT_MEMORY_KIB" "${probe_command[@]}")
elif [ "$(uname)" = Darwin ]; then
  probe_command=("$PERL_BIN" "$SELF_DIR/fm-lint-cache.pl" rsswatch "$PROBE_RESERVE_KIB" "$TMP_ROOT/probe.rss" -- "${probe_command[@]}")
fi
FM_LINT_INTERNAL_PYTHON="$WATCH_PYTHON" FM_LINT_INTERNAL_ABORT_FILE="$TMP_ROOT/census.abort" \
  "$PERL_BIN" "$SELF_DIR/fm-lint-cache.pl" probe "$HOST_POOL_ROOT/admission.lock" "$TMP_ROOT/probe.wait" \
  "$PROBE_BOUND_SECONDS" -- "${probe_command[@]}" > "$TMP_ROOT/probe.out" || probe_rc=$?
resolved=$(awk '/^version:/ {print $2; exit}' "$TMP_ROOT/probe.out")
# The probe's stderr (a refusal, or a blocked report while the lane is held past its
# bound) reaches this run's stderr as it is written.
if [ "$probe_rc" -ne 0 ] && [ "$probe_rc" -ne 127 ]; then
  # A probe ended by a signal (one past its address-space limit) prints nothing
  # itself, so the run names the probe, its status and the limit it ran under.
  probe_limit=
  [ "$BOUND_MECH" = none ] || probe_limit=" under the $ROOT_MEMORY_KIB KiB address-space limit"
  printf 'fm-lint.sh: the ShellCheck version probe exited with status %s%s; no root was started.\n' "$probe_rc" "$probe_limit" >&2
  exit 2
fi
# The probe's wait for its lane, in milliseconds, for the roots log.
probe_wait_ms=$(tr -d '[:space:]' < "$TMP_ROOT/probe.wait" 2>/dev/null) || probe_wait_ms=
case "$probe_wait_ms" in ''|*[!0-9]*) probe_wait_ms=unavailable ;; esac
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  if [ "$FM_LINT_STRICT_VERSION" = 1 ]; then
    printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
      "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
    exit 1
  fi
  printf 'fm-lint.sh: WARNING: ShellCheck %s differs from the CI pin %s; local findings may differ. Install %s with bin/fm-install-shellcheck.sh <destination-directory>, or pass --strict-version to make this an error.\n' \
    "$resolved" "$REQUIRED_SHELLCHECK" "$REQUIRED_SHELLCHECK" >&2
fi

# Nothing changed to lint: the version probe above still ran (and was admitted),
# but there is no root, no timing to record and no temporary state to keep.
if [ "$CHANGED_MODE" -eq 1 ] && [ "$ROOT_COUNT" -eq 0 ]; then
  trap - EXIT
  rm -rf "$TMP_ROOT"
  rm -f "$RUN_ENTRY"
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

# The roots log is the retained per-root lifecycle sidecar; beside --telemetry
# it survives as ${TELEMETRY%.tsv}.roots.tsv even when a run is killed
# mid-flight.
if [ -n "$TELEMETRY" ]; then
  ROOTS_LOG=${TELEMETRY%.tsv}.roots.tsv
else
  ROOTS_LOG=$TMP_ROOT/roots.tsv
fi
: > "$ROOTS_LOG"
if [ "$BOUND_MECH" != none ]; then
  bounds_applied=1
  root_deadline_meta=$ROOT_SECONDS
  root_grace_meta=$ROOT_GRACE
  root_memory_meta=$ROOT_MEMORY_KIB
else
  bounds_applied=0
  root_deadline_meta=unbounded
  root_grace_meta=unbounded
  root_memory_meta=unbounded
fi
{
  printf 'format\t%s\n' 'fm-lint-roots-v1'
  printf 'meta\t%s\t%s\n' 'shellcheck_version' "$resolved"
  printf 'meta\t%s\t%s\n' 'probe_wait_ms' "$probe_wait_ms"
  printf 'meta\t%s\t%s\n' 'platform' "$(uname -s) $(uname -m)"
  printf 'meta\t%s\t%s\n' 'image_os' "${ImageOS:-unknown}"
  printf 'meta\t%s\t%s\n' 'image_version' "${ImageVersion:-unknown}"
  printf 'meta\t%s\t%s\n' 'mode' "$ANALYSIS_MODE"
  printf 'meta\t%s\t%s\n' 'partition' "${PARTITION:-all}"
  printf 'meta\t%s\t%s\n' 'jobs' "$JOBS"
  printf 'meta\t%s\t%s\n' 'bounds_enforced' "$bounds_applied"
  printf 'meta\t%s\t%s\n' 'root_deadline_seconds' "$root_deadline_meta"
  printf 'meta\t%s\t%s\n' 'root_kill_grace_seconds' "$root_grace_meta"
  printf 'meta\t%s\t%s\n' 'root_memory_limit_kib' "$root_memory_meta"
  printf 'meta\t%s\t%s\n' 'host_memory_budget_kib' "$HOST_RSS_KIB"
  printf 'meta\t%s\t%s\n' 'root_rss_limit_kib' "$ROOT_RSS_KIB"
  if [ -n "$ROOT_RSS_REQUESTED_KIB" ]; then
    printf 'meta\t%s\t%s\n' 'root_rss_requested_kib' "$ROOT_RSS_REQUESTED_KIB"
  fi
  printf 'meta\t%s\t%s\n' 'timing_mechanism' "$BOUND_MECH"
} >> "$ROOTS_LOG"

SHARD_COUNT=2
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  : > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_root_weights > "$WEIGHTS" || exit $?

# Largest-first deterministic greedy assignment balances the two worker
# queues without affecting replay order. Direct bytes are a stable portable
# proxy after the expensive dynamic adapter source fan-out is cut.
WORKER_LOADS=(0 0)
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
while IFS="$TAB" read -r weight index path; do
  worker=0
  if [ "${WORKER_LOADS[1]}" -lt "${WORKER_LOADS[0]}" ]; then
    worker=1
  fi
  printf '%s\t%s\n' "$index" "$path" >> "$TMP_ROOT/manifest.$worker"
  WORKER_LOADS[worker]=$((WORKER_LOADS[worker] + weight))
done < "$WEIGHTS.sorted"
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  LC_ALL=C sort -t "$TAB" -k1,1n "$TMP_ROOT/manifest.$worker" > "$TMP_ROOT/manifest.$worker.sorted"
  mv "$TMP_ROOT/manifest.$worker.sorted" "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  local sample
  sample=$(ps -A -o %cpu= 2>/dev/null) || { printf 'unavailable'; return 0; }
  printf '%s\n' "$sample" | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  local -a worker_env
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  worker_env=(
    FM_LINT_INTERNAL=1
    FM_LINT_INTERNAL_FAST="$FAST"
    FM_LINT_INTERNAL_BOUNDED="$BOUND_MECH"
    FM_LINT_INTERNAL_MEMORY_KIB="$ROOT_MEMORY_KIB"
    FM_LINT_INTERNAL_RSS_KIB="$ROOT_RSS_KIB"
    FM_LINT_INTERNAL_PYTHON="$WATCH_PYTHON"
    FM_LINT_INTERNAL_ROOT_SECS="$ROOT_SECONDS"
    FM_LINT_INTERNAL_GRACE="$ROOT_GRACE"
    FM_LINT_INTERNAL_ROOTS_LOG="$ROOTS_LOG"
    FM_LINT_INTERNAL_MODE="$ANALYSIS_MODE"
    FM_LINT_INTERNAL_PROGRESS="$PROGRESS"
    FM_LINT_SHELLCHECK="$SHELLCHECK_BIN"
    FM_LINT_PERL_BIN="$PERL_BIN"
  )
  worker_env+=(FM_LINT_INTERNAL_SLOT_DIR="$SLOT_DIR" FM_LINT_INTERNAL_NCPU="$NCPU")
  worker_env+=(FM_LINT_INTERNAL_HOST_LOCK="$HOST_POOL_ROOT/admission.lock" FM_LINT_INTERNAL_HOST_RSS_KIB="$ROOTS_RSS_KIB"
    FM_LINT_INTERNAL_ABORT_FILE="$TMP_ROOT/census.abort" FM_LINT_INTERNAL_RUN_ENTRY="$RUN_ENTRY")
  worker_env+=(FM_LINT_INTERNAL_RUN_ID="$$")
  # The first pass queues a root whose only failure was an unmeasured interval;
  # the alone pass (after the first-pass workers end, below) reruns each once with
  # this set to 1.
  worker_env+=(FM_LINT_INTERNAL_ALONE_QUEUE="$TMP_ROOT/alone.queue" FM_LINT_INTERNAL_ALONE="$ALONE_PASS")
  # The most one root can hold: its address-space limit under the enforced
  # envelope, else the resident watch bound. The gate charges it for a root
  # without a record measured on its current input.
  if [ "$BOUND_MECH" != none ]; then
    worker_env+=(FM_LINT_INTERNAL_ROOT_CAP_KIB="$ROOT_MEMORY_KIB")
  else
    worker_env+=(FM_LINT_INTERNAL_ROOT_CAP_KIB="$ROOT_RSS_KIB")
  fi
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env "${worker_env[@]}" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env "${worker_env[@]}" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

# The macOS resident-memory watch wraps every root of this run (fm_lint_exec_root),
# so the exit trap prints the run's watch line.
if [ "$BOUND_MECH" = none ] && [ "$(uname)" = Darwin ]; then
  FM_LINT_WATCH_RUN=1
fi
ALONE_PASS=0
rm -f "$TMP_ROOT/alone.queue"
if [ "$JOBS" -eq 1 ]; then
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    fm_lint_wait_workers
    worker=$((worker + 1))
  done
else
  worker=0
  while [ "$worker" -lt "$SHARD_COUNT" ]; do
    fm_lint_start_worker "$worker"
    worker=$((worker + 1))
  done
  fm_lint_wait_workers
fi

# The alone pass (Main 4343). A root whose only failure in the first pass was an
# unmeasured interval (fm_lint_rerun_alone_eligible) was queued instead of failing
# or stopping the run. After every first-pass worker has ended, each queued root
# runs once more, one at a time, with no other root of this run beside it, under
# the same gate, watch, cap and memory retry. It passes only when that rerun is
# measured all through and under its cap; a rerun that is unmeasured again fails
# (96) and one measured over its cap fails as over its cap (98, or its narrower
# retry's own result). No root runs a third time. If the run was marked to stop
# (any other watch failure, or an unreadable host process table), no queued root
# runs again, and each one fails (96), named; so does each one if the alone pass
# manifest cannot be written whole.
REPLAY_COUNT=$SHARD_COUNT
if [ -s "$TMP_ROOT/alone.queue" ]; then
  REPLAY_COUNT=$((SHARD_COUNT + 1))
  alone_why=
  if [ -e "$TMP_ROOT/census.abort" ]; then
    alone_why=$(head -n 1 "$TMP_ROOT/census.abort" 2>/dev/null || true)
    [ -n "$alone_why" ] || alone_why="the run was marked to stop"
  elif ! cp "$TMP_ROOT/alone.queue" "$TMP_ROOT/manifest.$SHARD_COUNT" 2>/dev/null \
    || ! cmp -s "$TMP_ROOT/alone.queue" "$TMP_ROOT/manifest.$SHARD_COUNT"; then
    alone_why="its alone pass manifest could not be written"
  fi
  if [ -n "$alone_why" ]; then
    while IFS=$'\t' read -r _ alone_path; do
      printf 'fm-lint: %s not run again alone: %s\n' "$alone_path" "$alone_why"
    done < "$TMP_ROOT/alone.queue" > "$OUTPUT_DIR/shard.$SHARD_COUNT.out"
    printf '96\n' > "$OUTPUT_DIR/shard.$SHARD_COUNT.rc"
  else
    ALONE_PASS=1
    fm_lint_start_worker "$SHARD_COUNT"
    fm_lint_wait_workers
    ALONE_PASS=0
  fi
fi

# Replay both stable shards (and the alone pass, if any) in deterministic order and
# select the first nonzero shard status. ShellCheck processes every root in a shard
# after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$REPLAY_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

# Close the roots log with completion counts so a mid-run kill leaves
# begun-but-unfinished roots attributable by name. result_exit is appended
# after the purity and workflow checks so it records the run's final status.
if [ -s "$ROOTS_LOG" ]; then
  read -r roots_completed roots_unfinished roots_begun <<EOF
$(awk -F '\t' '
  $1 == "begin" { begun[$2 FS $3] = 1 }
  $1 == "begin" || $1 == "end" { last[$2 FS $3] = $1 }
  END { total = 0; done_count = 0; unfinished = 0
        for (key in begun) total++
        for (key in last) if (last[key] == "end") done_count++; else unfinished++
        printf "%d %d %d\n", done_count, unfinished, total }
' "$ROOTS_LOG")
EOF
  {
    printf 'meta\t%s\t%s\n' 'roots_begun' "$roots_begun"
    printf 'meta\t%s\t%s\n' 'roots_completed' "$roots_completed"
    printf 'meta\t%s\t%s\n' 'roots_unfinished' "$roots_unfinished"
  } >> "$ROOTS_LOG"
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  source_followed=0
  awk -F '\t' '$1 == "end" { nosource[$2] = ($12 == 0) } END { for (i in nosource) if (nosource[i]) print i }' \
    "$ROOTS_LOG" > "$TMP_ROOT/no-source-indices"
  root_index=0
  for path in "${ROOTS[@]}"; do
    root_index=$((root_index + 1))
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" > "$TMP_ROOT/root-source-targets"
      cat "$TMP_ROOT/root-source-targets" >> "$TMP_ROOT/source-targets"
      if ! grep -qx "$root_index" "$TMP_ROOT/no-source-indices"; then
        followed_here=$(grep -cv '^/dev/null$' "$TMP_ROOT/root-source-targets" || true)
        source_followed=$((source_followed + followed_here))
      fi
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'partition\t%s\n' "${PARTITION:-all}"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_bounds_enforced\t%s\n' "$bounds_applied"
    printf 'root_deadline_seconds\t%s\n' "$root_deadline_meta"
    printf 'root_kill_grace_seconds\t%s\n' "$root_grace_meta"
    printf 'root_memory_limit_kib\t%s\n' "$root_memory_meta"
    printf 'host_memory_budget_kib\t%s\n' "$HOST_RSS_KIB"
    printf 'root_timing_mechanism\t%s\n' "$BOUND_MECH"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'shard_1_weight_bytes\t%s\n' "${WORKER_LOADS[0]}"
    printf 'shard_2_weight_bytes\t%s\n' "${WORKER_LOADS[1]:-0}"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

if [ -s "$ROOTS_LOG" ]; then
  printf 'meta\t%s\t%s\n' 'result_exit' "$overall_rc" >> "$ROOTS_LOG"
fi

exit "$overall_rc"
