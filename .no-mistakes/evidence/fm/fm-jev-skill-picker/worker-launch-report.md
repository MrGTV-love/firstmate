# Read-only operational workflow assessment

## Provenance and scope

Advice source: **live**. Advice model: **jev-1.13.0**. This launch's delivered advice suggested secondmate-provisioning (fit 0.91, uncertain=false), operational-home-layout (0.7, uncertain=true), and stuck-crewmate-recovery (0.84, uncertain=true), each with evidence `opening-instruction recheck`. All three were independently judged relevant and read in full from their exact delivered paths, not from summaries. Optional advice is additive; it neither authorizes lifecycle actions nor displaces mandatory safety triggers.

This assessment used ordinary read/grep tools only for research. No provisioning, migration, recovery, dispatch configuration, external request, package installation, project edit, git mutation, or infrastructure lifecycle was performed. No real worker, account, quota, or host readiness is established by this report. The named task inbox was absent when read; no instruction required acknowledgement.

## Exact bodies read and quotations

Let `R` be `/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4A076ZYT1X4K1Z65KBR0AY2`. Every path below is relative to that exact root. Line references came from ordinary read output.

| Body read | Reason | Exact short quotation |
| --- | --- | --- |
| `.agents/skills/secondmate-provisioning/SKILL.md` (complete) | Suggested; home provisioning and secondmate-specific recovery | L157: “Seeding is transactional.” |
| `.agents/skills/operational-home-layout/SKILL.md` (complete) | Suggested; distinguish private homes/configuration from tracked code | L59: “append-only wake events, not current-state truth” |
| `.agents/skills/stuck-crewmate-recovery/SKILL.md` (complete) | Suggested; diagnose without losing recorded work | L42: “Before relaunch, prove that no live agent still owns the recorded task and that the existing worktree remains available.” |
| `.agents/skills/harness-adapters/SKILL.md` (complete) | Independently added mandatory adapter router for migration/recovery | L27: “Never dispatch a crewmate or secondmate on an unverified adapter.” |
| `.agents/skills/harness-adapters/references/common/dispatch.md` (complete) | Router-selected dispatch/replacement-profile resource | L20: “Apply every existing mandatory explicit/named and safety trigger before considering optional advice.” |
| `.agents/skills/harness-adapters/references/common/control-and-recovery.md` (complete) | Router-selected control/recovery resource | L11: “Let the control plane verify postconditions.” |
| `.agents/skills/harness-adapters/references/common/model-and-effort.md` (complete) | Router-selected model/effort resource | L27: “Harness identity is independent of model provider.” |
| `.agents/skills/harness-adapters/references/harness/omp.md` (complete) | Router-selected target adapter resource | L24: “use deterministic relaunch.” |
| `.agents/skills/quota-array-dispatch/SKILL.md` (complete) | Independently added to assess optional multi-candidate dispatch rules | L45: “`spendPriority` is THE quota-perspective ranker.” |
| `.agents/skills/captain-hold-lifecycle/SKILL.md` (complete) | Explicitly required shared report completion policy | L48: “Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.” |

Additional authoritative sections read: `docs/configuration.md:1081-1217` (reader also displayed through L1220), including L1188: “malformed configuration must be reported and corrected rather than selected around”; and `bin/fm-captain-hold.sh:1-150` (reader displayed through L153), including L134-135: “`--none` is an explicit semantic attestation that the just-reviewed surface has no unresolved captain call”. These are supporting documentation/header sections, not additional skill bodies.

The extra adapter router and its four resources were necessary because the suggested list alone does not describe omp migration or profile precedence. The quota-array workflow is conditional on actually configuring/selecting an array; it was read proactively for this assessment, not used to select a live candidate. No quota check was performed, so no provider or model is represented as quota-validated. A future actual quota intake must load quota-axi before using its CLI. A reported product bug would additionally trigger diagnostic-reasoning; this hypothetical operational assessment reports no such bug.

## Practical operational plan — future authorized execution only

### 1. Provision a secondmate home

Resolve natural-language responsibility and placement first. Route by `scope`, not exclusive project ownership; retain local-only projects in the main home. Distinguish greenfield from inherited domains: inherited plans must be reconciled against fetched `origin/main` plus live deployment before importing open work, never copied blindly (provisioning L164-182).

Fill the generated charter using `fm-brief.sh <id> --secondmate` with explicit projects or `--no-projects`, preserve idle-by-default behavior, then seed through `fm-home-seed.sh`, validate registry integrity, and hand off only reconciled scope-matching queued work through the designated handoff helper. Let transactional seeding own rollback; do not raw-copy a home or hand-author identity bindings. Preserve a leased home's lease across recovery and restarts (L81-87, L152-162, L184-212).

For remote placement use the remote seed/doctor path with explicit host, code root, home, and verified origins; do not create substitute local clones. Remote transport failure means unknown completion, not permission to launch locally. The omp reference specifically refuses remotely placed omp secondmates until remote verification exists (omp L55); therefore local omp verification is not proof of remote support.

Inherited crew dispatch/backend defaults concern future launches, not migration of live workers. The primary's secondmate pin and account-pin files are not inherited; do not edit an account pin to bypass a login refusal (provisioning L114-119). For actual provisioning, load project-management if adding/initializing clones and consult current script headers/help before execution. None of those actions is authorized here.

### 2. Migrate an ordinary worker to omp

Use the owning home's recorded worker identity and preserve the existing isolated copy, commits, uncommitted work, instructions, and progress. Establish source adapter from recorded `harness`, not model name, and load its own adapter reference at execution time; the source runtime is unspecified here. Read the target omp catalog through its own discovery surface, prove the binary exists, validate the explicit provider/model and supported effort, and retain the chosen runtime backend unless that exact task separately authorizes a change.

The future operation is guarded `fm-control.sh <id> relaunch --harness omp` with explicit model/effort when selected and a concise progress note, not raw exit keys, a fresh generic spawn, or a chat request to quit. Admission must succeed before stopping the old owner. A refusal is not a failed replacement launch and does not authorize killing the preserved owner. Then observe the replacement actually processing its instructions; successful delivery alone is insufficient (recovery L20-24, L73-80; adapter router L33-37).

omp has no project-trust dialog, uses `OMP_SKIP_SETUP=1` to suppress its setup wizard, accepts `--model <provider>/<id>` and `--thinking`, and should use deterministic relaunch rather than unverified native pane resume. Its model catalog omits extension-registered providers, so missing bridge entries require disclosed uncertainty rather than a fabricated unsupported verdict (omp L17-24). Respect the one-positional-instruction and extension loading contracts (L26, L43-45).

If “worker” instead means a persistent secondmate, use the separate primary-owned secondmate pin and local/remote relaunch procedures from provisioning L229-232; ordinary worker migration does not silently modify that pin.

### 3. Diagnose and recover a stuck worker

Reconcile targeted current state first; an old status line, timeout, quiet pane, or low context is not proof of death. Already-landed work goes to ordinary completion, not replacement. An authoritative matching validation run may still account for a dead endpoint; avoid a duplicate worker (recovery L15-16, L34-48).

For a live endpoint, inspect the pane and unread inbox, answer instruction-covered questions via the durable text plane, then interrupt and give one corrective steer if looping. Only a genuinely wedged worker after redirection advances to guarded relaunch in the same copy. For a missing endpoint, prove absence/ownership through the documented reclaim policy and only recorded backend inventory. Never sweep another home's namespace, allocate a competing copy, discard unlanded work, or improvise endpoint surgery. If ownership is uncertain, preserve all evidence and report the blocker.

A validation timeout is not daemon death. In future actual diagnosis, inspect daemon socket and authoritative run state; socket refusal/absence or a failed run naming a daemon error warrants escalation, whereas an active run warrants reattachment. Never restart the shared daemon on a worker's claim (L50-67). Those no-mistakes commands were deliberately not executed in this assessment. A second failed admitted replacement warrants a plain failure report with preserved work, not endless retries (L81).

### 4. Configure dispatch rules

Keep private configuration in the correct explicit `FM_HOME`. Prefer the simplest single concrete profile unless alternatives are genuinely needed. `config/crew-dispatch.json` supports `rules` with required `when`/`use`, a required profile `harness`, optional model/effort, and optional object-or-nonempty-array `default`. Natural-language best-fit selection is firstmate judgment; scripts consume concrete axes (configuration L1081-1127).

Precedence is explicit task override, best-fit rule, configured default, then static crew runtime. Secondmate agent launches are exempt from the crew dispatch file and use their separate pin. With the file present, crew/scout spawn requires explicit resolved runtime; malformed or unsupported configuration must be corrected, not bypassed. The file is inherited by secondmate homes (L1087-1091, L1174-1192).

For an array, capture one default quota-axi TOON snapshot, establish every candidate's model/provider/auth surface from its own authoritative evidence, apply eligibility, reasoning-class, and runway-versus-task-horizon gates, then rank comparable known `spendPriority`. Unknown quota is disclosed uncertainty, not zero or proof of unusable credentials. Do not downgrade reasoning class or break true ties by array order. Show evidence for every candidate, including rejected ones (quota-array L39-54, L64-134).

If typed resolution is enabled, omp requires explicit profile `provider`; approval/confidence/floor/horizon declarations are code-enforced only on that opted-in path. Invoke the resolver directly on the written brief at actual intake; only `clear` supplies a concrete resolved profile. Non-clear/off outcomes return to authoritative ordinary intake, not silent fallback. This assessment did not invoke it or send intent to an external service (configuration L1129-1159, L1194-1217; quota-array L36-37).

## Recommendation and completion inventory

Proceed with this owner-aware, preserve-work plan only under a separately authorized operational task. Use existing helpers rather than new wrappers. All three optional suggestions are useful, but incomplete without the adapter router/omp resources and conditional quota-array workflow. No implementation defect or authorized code change was discovered.

This report leaves **no unresolved human choice gating the requested read-only deliverable**. Unspecified home, source runtime, model/account, remote host, and actual dispatch rules are future execution inputs, not decisions needed to finish this assessment. No visual review or held decision was created. The shared completion inventory is therefore `--none`; its actual command result is recorded below after execution.

Completion evidence: ran `FM_HOME=R/.live-validation/gate-skill-picker/lab R/bin/fm-captain-hold.sh complete jev-live-worker --none` with both `R` occurrences expanded to the absolute root above. Exit 0; exact stdout: `complete: jev-live-worker captain-call inventory reviewed`. This was the brief-required completion attestation, not an infrastructure lifecycle operation. Read back the report's recommendation/inventory before publishing completion.
