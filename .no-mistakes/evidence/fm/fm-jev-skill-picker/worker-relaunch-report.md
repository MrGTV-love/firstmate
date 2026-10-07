# Read-only operational assessment

## Scope and advice provenance

Fresh replacement assessment: re-read the newly delivered advice and all bodies listed below using ordinary `read` tools, independently added necessary workflows, and replaced this report. Advice source: **live**; model: **jev-1.13.0**. Suggestions: secondmate-provisioning (fit 0.91, uncertain false), operational-home-layout (0.69, uncertain true), stuck-crewmate-recovery (0.86, uncertain false); each stated evidence `opening-instruction recheck`.

All three suggestions are suitable. Layout remains necessary despite the advisory uncertainty. Advice is additive, not authority to execute lifecycle operations. No provisioning, launch, migration, recovery, configuration, package installation, git mutation, external service call, or validation pipeline was performed. The exact instruction inbox was checked with `glob`; it reported the directory absent, so there were no messages to acknowledge.

## Exact bodies read and short quotations

Paths below are relative to `/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2/`. Every listed skill/reference body was read in full in this replacement session.

| Body | Selection and evidence |
|---|---|
| `.agents/skills/secondmate-provisioning/SKILL.md` | Suggested and required for this plan. Lines 157–158: “Seeding is transactional.” Lines 178–179: “Never inherit a plan backlog blind.” |
| `.agents/skills/operational-home-layout/SKILL.md` | Suggested; needed to distinguish code root and private home. Line 59: “append-only wake events, not current-state truth”. |
| `.agents/skills/stuck-crewmate-recovery/SKILL.md` | Suggested; recovery owner. Line 42: “Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.” |
| `.agents/skills/harness-adapters/SKILL.md` | Independently added: migration/recovery and profile selection require this router. Line 35: “Deliver lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt\|exit\|relaunch`.” |
| `.agents/skills/harness-adapters/references/common/dispatch.md` | Router-selected dispatch/replacement-profile reference. Line 20: “Apply every existing mandatory explicit/named and safety trigger before considering optional advice.” |
| `.agents/skills/harness-adapters/references/common/model-and-effort.md` | Router-selected profile-axis reference. Line 27: “Harness identity is independent of model provider.” |
| `.agents/skills/harness-adapters/references/common/control-and-recovery.md` | Router-selected recovery reference. Line 42: “Deterministic relaunch instead trusts instructions on disk, not a private session, and never needs a session id printed at exit.” |
| `.agents/skills/harness-adapters/references/harness/omp.md` | Selected target adapter. Line 24: “use deterministic relaunch.” Line 23: “No project-trust gate at all”. |
| `.agents/skills/quota-array-dispatch/SKILL.md` | Independently added for multi-candidate dispatch design. Line 95: “Malformed configuration is an actionable error, not a candidate to rank around.” Line 114: “Among candidates that pass all three gates, pick the highest known `spendPriority`.” |
| `.agents/skills/captain-hold-lifecycle/SKILL.md` | Explicitly required report completion owner. Line 48: “Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.” |

Additional owner evidence read: `docs/configuration.md:1081–1217` (dispatch schema and typed resolver intake); `bin/fm-captain-hold.sh:1–100,125–165` (completion command and attestation). A literal `grep` located dispatch headings before reading their ranges. No previous report was used as fresh evidence.

## Practical operational plan (proposed, not executed)

### 1. Provision a secondmate home

- Resolve the intended home explicitly via `FM_HOME`, separate tracked code from private `data/`, `state/`, `config/`, and `projects/`, and select a concise responsibility scope. Route by scope rather than exclusive project ownership; keep local-only work in the main home.
- Scaffold a charter through `fm-brief.sh --secondmate`, supply actual charter text, and deliberately choose project names or `--no-projects`. Do not convert a populated project-bearing home to project-less by removing content. Preserve idle-by-default and parent-return-channel instructions.
- Once actual provisioning is authorized, use the transactional seed owner (`fm-home-seed.sh`, or the remote seed owner for an explicitly chosen remote placement), not manual directory copies or registry edits. A leased home remains reserved across restarts; retirement, not routine recovery, releases it.
- For an existing/inherited domain, reconcile each inherited plan with fetched `origin/main` plus live deployment before importing open work. Record remaining uncertainty; do not treat old backlog prose as delivery evidence. Hand off only genuinely open, queued, dependency-closed scope-matching work with the handoff helper.
- Validate registry integrity using the seed owner's validation path; resolve secondmate launch pins separately from crew profiles. Before any later launch, read the router's secondmate common-reference branch and verify the selected tool and backend. The omp reference explicitly refuses remote secondmate use until host verification; do not assume local verification authorizes remote placement.

Evidence: provisioning body 44–98, 154–182, 184–212; layout 23–30, 48–59; omp 55. This assessment needs no placement choice because it is not authorizing a real home.

### 2. Migrate an ordinary worker to omp

- Identify the owning home and exact recorded task, current harness, endpoint, branch, preserved changes, instructions, and any authoritative active validation run. Changing `config/crew-harness` only affects future selection; it does not itself migrate a running agent.
- Check omp binary availability and the current omp model catalog on omp's own discovery surface when execution is authorized. Use an explicit provider/model and suitable supported effort; no provider or authentication inference from the harness name. Extension-provided models omitted from `omp models` are disclosed discovery limits, not automatically unsupported.
- Perform an admitted, deterministic same-task relaunch through `fm-control.sh <id> relaunch --harness omp` with explicit model/effort where intended and a concise progress note. Read the recorded source adapter reference before controlling its existing agent; its identity is not supplied by this hypothetical task. Never launch a second generic worker in a new copy or type exit/interrupt instructions through `fm-send`.
- Preserve commits, uncommitted changes, the same isolated copy, durable inbox, and task identity. Admission precedes stopping the current agent. Verify replacement processing of its instructions, current recorded identity, and native busy/idle evidence, rather than counting a successful send as readiness. Use deterministic relaunch, not omp's unverified native pane-resume path. Missing binary, unusable selected credentials, or unsupported backend requires a concrete blocker, not silent fallback.

Evidence: adapter router 25–37; recovery 34–48, 73–80; common recovery 31–45; omp 11–24, 43–45. This does not authorize changing a worker account pin.

### 3. Diagnose and recover a stuck worker

- Inspect targeted current state and endpoint, unread steering messages, instructions, and relevant active validation state before concluding it is stuck. A status tail or stale presence report is not current truth. Finished, already-landed work needs ordinary cleanup, not recovery.
- Answer an instruction-covered question through the durable text plane. For confusion or looping, use verified interrupt followed by one corrective steer. Only genuinely wedged work advances to admitted same-copy relaunch; a low context reading is not wedging.
- For a missing endpoint, prove ownership absence with the control plane's reclaim policy. Preserve work and records on refusal; do not allocate another copy or kill matching names in another home. If another admitted replacement also fails, report the failure and preserved work.
- If a live worker claims its validation pipeline died, later authorized diagnosis must distinguish socket refusal/absence from a drive-call timeout using authoritative daemon and run state. Never restart shared infrastructure on a worker's claim. Those commands were deliberately not run in this read-only assessment.
- Handle secondmates through their dedicated provisioning/recovery owner, not ordinary-worker reconstruction. Unreachable remote transport means unknown state, not a dead agent and not permission for a local replacement.

Evidence: recovery 15–48, 50–81; provisioning 214–239. No actual stuck endpoint was inspected or recovered.

### 4. Configure dispatch rules safely

- Plan one local `config/crew-dispatch.json` with clear natural-language `when` rules, required `use` profiles, and an optional deliberate default. Each profile needs a verified `harness`; model/effort are optional. A single profile object is sufficient unless genuine alternatives are needed. Keep secondmate launch pins in `config/secondmate-harness`, not in crew rules.
- At later authorized intake, use precedence: explicit per-task instruction, best-fitting rule, configured default, static crew selection. Pass concrete resolved axes to spawn; the presence of this file requires an explicit crew/scout harness. Report malformed configurations rather than selecting around them. Validate schema with the existing owner, not a new routing wrapper.
- For arrays, independently establish every candidate's own catalog/provider and applicable account/authentication evidence. At actual selection load the `quota-axi` skill, capture its default TOON once, apply eligibility, reasoning-class, and completion-runway gates, then rank comparable known `spendPriority`. Use only the permitted TOON-to-JSON fallback for genuine ambiguity. Disclose unknown data; do not pretend it is zero or healthy. Report genuine ties and preserve the required reasoning class. No quota snapshot or route was selected here.
- Typed resolution is opt-in via the TypeSafe key. An omp typed profile must declare its provider explicitly. Approval/confidence/floor/horizon declarations have typed-only enforcement semantics; without opt-in they are hints, not automated protection. At a real intake invoke the resolver directly on the written instructions without preflight. A `clear` profile is consumed unless a reasoned override is stated; off/ambiguous/escalate/error return to the normal intake and never silently authorize fallback.
- Inherited crew config affects secondmate worker defaults and needs the existing guarded propagation and live reread procedure after changes. It does not migrate already-live workers. Account pins are not inherited and must not be changed to bypass a refusal.

Evidence: configuration 1081–1192, 1194–1214; quota workflow 39–54, 64–134; provisioning 114–119, 133–151.

## Assessment and completion inventory

The supplied optional advice correctly covers home provisioning and stuck-worker recovery but is incomplete for migration to omp and dispatch-rule design. The independently added adapter router, its selected common/omp references, and quota-array workflow close those gaps. Mandatory triggers remain authoritative.

Recommendation: use the existing transactional seed, verified control plane, targeted recovery, and canonical dispatch schema; do not introduce wrappers or speculative automation. Apply this plan only under a separately authorized operational task. Current binary readiness, authentication, selected models, quota headroom, endpoints, home placement, and deployment state were intentionally not assessed; this report makes no readiness claim.

Completion inventory: this assessment exposes no unresolved human choice that gates the requested read-only deliverable. Future placement/model/rule details are prerequisites of a separately authorized execution request, not decisions this report requires to finish. No code change or infrastructure action is proposed for shipment by this task. The shared completion command and its observed outcome are recorded in the final execution note below.

Execution note: ran `FM_HOME=<lab-home> <code-root>/bin/fm-captain-hold.sh complete jev-live-worker --none` after reviewing the complete report. Exit 0; observed output: `complete: jev-live-worker captain-call inventory reviewed`. This explicitly required completion attestation was the only operational bookkeeping command; no lifecycle was exercised.
