---
name: dispatch-profile-intake
description: Load at every crewmate or scout intake before resolving dispatch profiles.
user-invocable: false
metadata:
  internal: true
---

# Dispatch profile intake

Resolve repository-relative paths and links below from the Firstmate repository root.

When dispatch profiles exist, consult them at every crewmate or scout intake and pass the selected profile under the [fleet model-index contract](../../../docs/configuration.md#fleet-model-index-configmodel-indexjson) to `fm-spawn`.
Routing precedence is an explicit per-task captain override, then the best-fit configured rule, then the configured default, then the static crewmate harness.
Account for every candidate with the catalog evidence, provider relationship, applicable quota and authentication facts, remaining uncertainty, fit and reasoning class, and the spendPriority and runway evidence used in selection; never omit a candidate, guess, fall back silently, or call the result quota-informed without them.
Preserve malformed profile configuration as an actionable error rather than selecting around it.
When every candidate is tight, preserve the captain's strongest-reasoning class rather than silently downgrading it solely to conserve quota; stop and report the tight choice if that class cannot proceed.
Break genuine evidence ties without array-order or harness bias.
Load `quota-array-dispatch` before choosing among a matched profile array; that skill is the single owner of the TOON-first spendPriority selection procedure.
Run `bin/fm-dispatch-resolve.sh <brief>` directly on the scaffolded brief in the same turn with no preflight (its typed clone-path binding owns project identity), and on `clear` pass its `profile:` line to `fm-spawn` unless you state a reason to override; `ambiguous`, `escalate`, `error`, and off all mean the intake above, unchanged (contract: `docs/configuration.md` "Typed dispatch resolution").
