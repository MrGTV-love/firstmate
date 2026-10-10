# Dispatch and start

Load this with the selected tool reference for dispatch, start, or adapter verification; add `references/common/model-and-effort.md` for either profile axis.

## Resolution

Use the router's detection and safety sections for static crew and secondmate harness resolution and all explicit overrides.
`config/crew-dispatch.json` can override that static default for one crewmate or scout with a profile under the [dispatch configuration contract](../../../docs/configuration.md#crew-dispatch-profiles-configcrew-dispatchjson).
For a profile array, load `quota-array-dispatch` after establishing harness and provider facts here.
When the opt-in `bin/fm-dispatch-resolve.sh` is on, its `clear` answer already names the concrete axes; `docs/configuration.md` "Typed dispatch resolution" owns that contract.

[`secondmate-provisioning`](../secondmate-provisioning/SKILL.md) owns inherited harness defaults and routing configuration.

## Skill selection at launch

Apply every existing mandatory explicit/named and safety trigger before the launch's skill selection.
Follow [Worker skill selection](../../../docs/configuration.md#worker-skill-selection) for ship and scout launches; it owns input, brief transport, privacy, provider policy, and recorded outcomes.


## Owners

`../../../bin/fm-spawn.sh` owns launch, autonomy, concrete flags, task-kind compatibility, and worker turn-end wiring.
Natural-language rules stay with firstmate; model references follow the [fleet model-index contract](../../../docs/configuration.md#fleet-model-index-configmodel-indexjson).

`../../../bin/fm-busy-lib.sh` owns semantic busy trust.
Composer shapes, glyphs, placeholders, popups, rendered delivery signals, and the verdict contract belong only to [`bin/fm-composer-lib.sh`](../../../bin/fm-composer-lib.sh).
Tool references record empirical knowledge for those executable owners.

## Adapter verification

For an approved new adapter check, use the spawn owner's raw-launch escape hatch only for a trivial supervised task when the [session launch policy](../../../docs/configuration.md#session-launch-policy-configsession-launch-policy) admits that launch.
Verify detection in `../../../bin/fm-harness.sh`, launch in `../../../bin/fm-spawn.sh`, busy state in `../../../bin/fm-busy-lib.sh`, shared composer behavior in `../../../bin/fm-composer-lib.sh`, lifecycle in `../../../bin/fm-control-lib.sh`, and tmux liveness in `../../../bin/backends/tmux.sh` when secondmate use is supported.
Also verify primary integration through `references/common/primary-hooks.md`, model discovery through `references/common/model-and-effort.md`, and one tool record.
A value remains unreachable until its executable owner, portable regression, applicable credentialed live guard, and verification record land together.
`../firstmate-coding-guidelines/SKILL.md` owns harness-dependent proof.
