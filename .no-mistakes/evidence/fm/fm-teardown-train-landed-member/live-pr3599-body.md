## Intent

Owner words, 2026-10-31 (relayed by Main 1993, corr=0bae791ecf9f64bc): "We will never finish if you are limiting Vernant work to only one at a time" / "I want work to land, so we need to land and build. We need to make landing more efficient. That is why you have the trains. The trains must never stop. They must always be running." / "I still need you to build the Vernant product".

Context the ask refers to. A merge train lands several ready PRs at once: one branch from current origin/main that merges each ready PR head unchanged, one pipeline run and one CI run on the combined tree, then one merge of the train PR. Each component below already has an independent PASS review at its exact head. Train B components, in this order (Main 2478 admit, corr 40468cd5aba94c57):
1. https://github.com/MrGTV-love/vernant/pull/3577 at da397d45e80ad0a0206b0ca1dfefb6e541d4a9df - test(vernant_engine): keep offline client tests off the ambient proxy environment.
2. https://github.com/MrGTV-love/vernant/pull/3568 at 3d827a78bac9a60ecb96fade4aedbe2d640990ca - fix(vernant_operator): require an exact signer interpreter name match.
3. https://github.com/MrGTV-love/vernant/pull/3569 at 2b27d50d062c1e5d42de89fa373a4afc764bf4b7 - docs(oxlint): correct the upstream package pin pairing.
4. https://github.com/MrGTV-love/vernant/pull/3570 at 1417c8e229f4149f4592eb0d6c3092e793896bb0 - feat(vernant_engine): carry a named synthesized conclusion as the C7 key finding.
5. https://github.com/MrGTV-love/vernant/pull/3571 at f53f6b8da945be102f194ee8f8d280c879ebe52c - test(vernant-web): harden public pricing guard and drop dead pricing formatters.
6. https://github.com/MrGTV-love/vernant/pull/3572 at 1a3c9ed9019005a5f0d2cc962f477479aa89c7d6 - fix(rigor): let judgement-waiting gates reach AWAITING_JUDGEMENT.
7. https://github.com/MrGTV-love/vernant/pull/3573 at 54de486c4aa405f340d5c77e226ba3bc86a82d14 - docs: keep definition set history in the dated registers, not CHANGELOG.md.
8. https://github.com/MrGTV-love/vernant/pull/3574 at 2e755481bbbd8ba4e3f0a34da0ef20e1a1f803e9 - feat(vernant_engine): add optional record_id to CellProvenance.
9. https://github.com/MrGTV-love/vernant/pull/3575 at 7cdffb4848793fbf0d98ac22dcce6ac88bc8209b - fix(hooks): stop the dispatcher pre-loading optional third-party modules.
10. https://github.com/MrGTV-love/vernant/pull/3576 at f04e084be95b30de77685c76e9f32ae6545f5385 - fix(vernant_engine): read padded CSV delimiters and pipe-comment preambles instead of misreading them.
11. https://github.com/MrGTV-love/vernant/pull/3586 at 259526803a9ea44a39852a7d76bb54a66b6c2bf5 - docs(custody): frame, review, and dispatch the citation rendering operational solution.
12. https://github.com/MrGTV-love/vernant/pull/3589 at 4509cc3374d6772400f1f476ea7fe57c665a25f2 - test(rigor): pin citation-rendering custody case at DISPATCH_READY.
13. https://github.com/MrGTV-love/vernant/pull/3528 at 0b2e8a9f116efe9b9bbfc22b4df108e5a7be88e3 - feat(organization-context): add per-organization context profile with gate-1 confirmation.
14. https://github.com/MrGTV-love/vernant/pull/3579 at 91555cdff0ac7ff8048d8af6a2c445bc6a6b0525 - test(engine): pin the sync first-emit guard of the parser child timeout capture.
15. https://github.com/MrGTV-love/vernant/pull/3580 at 3d2bd7ea49bdd643cb5d2aa5decfa98ed4a03e7d - test(vernant_engine): fail when the account export drops a Case's per-source set ids.
16. https://github.com/MrGTV-love/vernant/pull/3581 at f4de719298508e7f824d300ee7c2e5f9902cf3eb - fix(vernant_engine): give seeded C7 criteria a truthful reason when the model is not called.
17. https://github.com/MrGTV-love/vernant/pull/3583 at 947e211b2fa330fb2762933449fec194c892b1f1 - feat(vernant_engine): resolve synthesis output ids in the Proof Explorer key-finding header.
18. https://github.com/MrGTV-love/vernant/pull/3587 at 05140f174a242e3fdbebdccf1e6b7b172190d005 - fix(vernant_engine): enforce the 4 MiB admission RPC response ceiling.
19. https://github.com/MrGTV-love/vernant/pull/3588 at 75ffd4256fc96c4d88878ae50102cb8c6c9290c6 - fix(vernant_engine): estimate text upload memory once per request.
20. https://github.com/MrGTV-love/vernant/pull/3582 at 4478f0ca86e26bf921b8e99ef3cc2ea8b7af07a1 - fix(git-stability): retire proven-stale slot manifests in the provisioner.
21. https://github.com/MrGTV-love/vernant/pull/3595 at f06c75b14e5504eb40eb9bd98b58e5760f9a2532 - fix(web): generate drop-zone size bound from engine upload limits.
A component that is refused (head moved, conflict, failed proof, red only because of that component) is dropped from the train and reported; it never blocks the others.

Main 2478 coupling rules: (1) PRs 3586 and 3589 land together or not at all - each is red alone by design (custody_corpus_test fails 3 tests on either alone) and green only together; if either drops, drop both. (2) PR 3595 and PR 3528 both edit .github/workflows/ci.yml, and 3595 adds an intake-limits drift check that PR 3588 engine changes could trip; read the combined Test and CI for them. (3) Linear rule (Main 2467): Vernant main has required_linear_history, so the train PR lands by squash; a pipeline rebase that flattens the component merges is accepted when every file is byte-equal to its component reviewed head, proven per file. (4) A conflicted or red component drops out and is reported.

Left out of train B on purpose: PR https://github.com/MrGTV-love/vernant/pull/3472 (stale test not updated; Main 2282), PR https://github.com/MrGTV-love/vernant/pull/3593 (couples with 3582; after the train, Main 2411), the PR 3513 successor (no new PR yet), and the case-analytics-graph pin (waits for d3 G3).

Merge form: the git guard (P-MERGE) denies `git merge --no-ff -m`; the form it allows is a plain `git merge` of the verified remote-tracking ref (after `git fetch origin pull/<N>/head:refs/remotes/origin/pr-<N>`, run `git merge refs/remotes/origin/pr-<N>`). The default merge message is accepted; the PR body carries each component URL and head.

## What Changed

- **Product and engine:** adds the B5 Organization Context profile: migration, engine service and routes, shared schemas, and the Case web page with its assertion editor. The running app does not build the service yet, so these routes answer 503 until the lifespan hookup lands. Synthesis can now carry a named settled conclusion as the C7 key finding, and seeded C7 criteria state why the model was not called. CSV reading handles padded delimiters and pipe-comment preambles, and refuses ambiguous headers. Admission RPC responses have an enforced ceiling, text uploads are estimated once per request, and `CellProvenance` gains an optional `record_id`.
- **Tooling, tests and docs:** the web drop-zone bound is generated from engine limits, with a CI drift check. CI also runs the B5 persistence suite. The slot provisioner retires proven-stale manifests. The rigor gate check reports `AWAITING_JUDGEMENT` when each open gate holds an unresolved judgement task. The hook dispatcher stops pre-loading optional third-party modules, and the canary signer needs an exact interpreter name. Dead pricing formatters are removed and the public pricing guards are stronger. The citation-rendering custody case is added and pinned at `DISPATCH_READY`, with test isolation and doc corrections.
- **Train contents:** 20 of the 21 admitted components are in this branch. PR https://github.com/MrGTV-love/vernant/pull/3583 (`947e211b2fa330fb2762933449fec194c892b1f1`) is **not included**: `render_template.py` is unchanged, so the Proof Explorer still resolves a named key-finding id only against package findings. The branch history is flattened, so the component heads are not ancestors of this branch. Included components:
  - https://github.com/MrGTV-love/vernant/pull/3577 at `da397d45e80ad0a0206b0ca1dfefb6e541d4a9df`
  - https://github.com/MrGTV-love/vernant/pull/3568 at `3d827a78bac9a60ecb96fade4aedbe2d640990ca`
  - https://github.com/MrGTV-love/vernant/pull/3569 at `2b27d50d062c1e5d42de89fa373a4afc764bf4b7`
  - https://github.com/MrGTV-love/vernant/pull/3570 at `1417c8e229f4149f4592eb0d6c3092e793896bb0`
  - https://github.com/MrGTV-love/vernant/pull/3571 at `f53f6b8da945be102f194ee8f8d280c879ebe52c`
  - https://github.com/MrGTV-love/vernant/pull/3572 at `1a3c9ed9019005a5f0d2cc962f477479aa89c7d6`
  - https://github.com/MrGTV-love/vernant/pull/3573 at `54de486c4aa405f340d5c77e226ba3bc86a82d14`
  - https://github.com/MrGTV-love/vernant/pull/3574 at `2e755481bbbd8ba4e3f0a34da0ef20e1a1f803e9`
  - https://github.com/MrGTV-love/vernant/pull/3575 at `7cdffb4848793fbf0d98ac22dcce6ac88bc8209b`
  - https://github.com/MrGTV-love/vernant/pull/3576 at `f04e084be95b30de77685c76e9f32ae6545f5385`
  - https://github.com/MrGTV-love/vernant/pull/3586 at `259526803a9ea44a39852a7d76bb54a66b6c2bf5`
  - https://github.com/MrGTV-love/vernant/pull/3589 at `4509cc3374d6772400f1f476ea7fe57c665a25f2`
  - https://github.com/MrGTV-love/vernant/pull/3528 at `0b2e8a9f116efe9b9bbfc22b4df108e5a7be88e3`
  - https://github.com/MrGTV-love/vernant/pull/3579 at `91555cdff0ac7ff8048d8af6a2c445bc6a6b0525`
  - https://github.com/MrGTV-love/vernant/pull/3580 at `3d2bd7ea49bdd643cb5d2aa5decfa98ed4a03e7d`
  - https://github.com/MrGTV-love/vernant/pull/3581 at `f4de719298508e7f824d300ee7c2e5f9902cf3eb`
  - https://github.com/MrGTV-love/vernant/pull/3587 at `05140f174a242e3fdbebdccf1e6b7b172190d005`
  - https://github.com/MrGTV-love/vernant/pull/3588 at `75ffd4256fc96c4d88878ae50102cb8c6c9290c6`
  - https://github.com/MrGTV-love/vernant/pull/3582 at `4478f0ca86e26bf921b8e99ef3cc2ea8b7af07a1`
  - https://github.com/MrGTV-love/vernant/pull/3595 at `f06c75b14e5504eb40eb9bd98b58e5760f9a2532`

## Risk Assessment

⚠️ Medium: The 20 merged components match their reviewed heads apart from three doc files changed by the newer train A base, and those three carry an owner-decision item with content preserved, while the largest new surface (B5 Organization Context) is ownership-checked in SQL and unwired in the shipped app.

## Testing

The baseline shard_map local command had already passed. I then drove the train at eab72358a on disposable stacks and tore them all down. The B5 persistence suite passed 14 of 14 on a really migrated database, running first as the new ci.yml order requires. The full CI database command exited 1 locally with 596 passed and 2 failed, and the real assert step says FAIL. One failure was my port: the test allows only 54322 and 58322, and it passed through a 58322 forwarder. The other was Postgres killed by signal 9 at about 4.4 GiB in the shared 8 GB Docker VM while my second stack ran; it passed alone with that stack down. So the floors assert has not passed on a real report, and CI remains the proof for the whole lane. Setup differences: the engine ran with `uvicorn --factory`, a disposable environment and VERNANT_DEBUG=true, not `run_start.py`, because that reads the operator's real `~/.config/vernant/r1.env`. It used a throwaway share secret, Temporal and Redis. A fresh stack denied service_role SELECT on public.revoked_tokens, so I ran GRANT on the portal database only, after the database test runs on it. The train's REVOKE lines touch B5 objects only, so that gap did not come from this train. Portal screenshots show the 530 MB drop-zone note and the Organization Context error state. The engine routes returned 503 because the service is deliberately unwired, so the real save and confirm screens could not be rendered; only the persistence suite drives the real service. CSV admission was called directly, because `dispatch_parse` sends these CSVs to passthrough and I found no non-test caller of `admit_csv` or `reanchor_csv`. The per-file proof re-recorded at the final head is PASS, with the 3 base-changed files SAME. `vernant-web/.next` (323 MB, gitignored) stays in the worktree because the rm guard blocks its removal; `git status` is clean.

- Live validation: ✅ go - 9 of 14 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| B5 persistence first in the CI order: run the new ci.yml command on a freshly migrated database and see all 14 B5 tests pass before any historical replay | ✅ pass | live | db-integration.log (B5 tests at lines 13 onward, 14 PASSED, 0 not passed) |
| Whole CI database lane on the combined tree: run the full command and the fail-closed assert with all floors, and see exit 0 | ⏸️ untested | no | I ran the whole command once and it exited 1, so no local run shows a green lane. I did not rerun all 598 tests in one clean pass. Failure 1: test_portal_session_create_idempotency allows only ports 5… |
| Drift check catches a stale drop-zone bound: the check passes at head and exits 1 when the artifact is stale, the engine limit changes, or the artifact is missing (PR 3595 with PR 3588) | ✅ pass | live | s-intake-limits.txt (head exit 0 at 559939584; each of the three adversarial cases exit 1 with DRIFT or missing; restored exit 0) |
| User opens New case in the real portal and sees the generated bound: PDF, Word and PowerPoint files up to 530 MB | ✅ pass | live | cases-new-before-dropzone.png, s-portal.txt |
| Signed-in user calls Organization Context on the real engine: fields answer 200 no-store, service routes answer the 503 envelope, no token answers 401 | ✅ pass | live | s-org-context-engine.txt |
| User opens the Organization Context page while the service is unwired: the page shows a red could-not-be-loaded message after retries and does not stay on loading | ✅ pass | live | organization-context-page.png, s-portal-org.txt |
| User saves and confirms an organization profile through the portal screens | ⏸️ untested | no | The shipped engine leaves the Organization Context service unbuilt by design (D7-owned lifespan hookup), so these routes answer 503 and the form cannot render against the real product. I drove the rea… |
| Custody pair lands together: the custody CLI reports citation-rendering at DISPATCH_READY and the corpus gate is green with PRs 3586 and 3589 both present | ✅ pass | live | s-custody-status.txt (DISPATCH_READY, exit 0), s-custody.txt (14 passed) |
| Slot provisioner retires only a proven-finished owner: finished owner retired with a receipt; unfinished, zero-commit and deleted-branch owners refused with exit 2 and records preserved | ✅ pass | live | s-slot-provisioner.txt (throwaway repo with a stub gh; stale_manifest_owner_unfinished, stale_manifest_proof_unreadable, ancestry receipt) |
| CSV reading: padded delimiters are read without stray spaces, pipe-comment preambles are kept, and ambiguous files are refused as csv_malformed, compared with base | ⏸️ untested | no | The prior payload did not establish a live result. I called the `admit_csv` entry point directly on throwaway files. `dispatch_parse` sent these CSVs to passthrough, and a grep found no non-test calle… |
| Hook dispatcher does not preload optional modules, and a needed parser that fails still fails closed; signer interpreter name must match exactly | ⏸️ untested | no | The prior payload did not establish a live result. Only existing tests covered this. The dispatcher tests spawn real subprocesses, but I did not run a live hook session or a signer host. |
| Admission RPC ceiling, text estimate once per request, C7 key finding and truthful reason, account export set ids, parser timeout capture | ⏸️ untested | no | The prior payload did not establish a live result. Only targeted tests covered this, apart from the stage-2b read through the ceiling on real Postgres. C7 is off by default and needs model calls, so i… |
| Public pricing page still renders after dead formatters are removed | ✅ pass | live | pricing.png, s-portal.txt, targeted-web-tests.txt (213 passed) |
| Train content equals the reviewed component heads: per-file proof at the final head with base f9e41a9f, 3583 dropped, no extra file | ✅ pass | live | per-file-proof-final-head.txt (RESULT: PASS, failures=0, components=20; the 3 base-changed files are SAME per the recorded owner-relayed decision) |

![New case page: drop-zone note reads PDF, Word and PowerPoint files up to 530 MB, from the generated engine limit](https://github.com/user-attachments/assets/b2cd3f7d-ae1f-4779-8c9f-fbcc5ef5f259)
![Organization Context page: visible error state when the unwired service answers 503](https://github.com/user-attachments/assets/b4694b50-0a80-48dc-b508-55d53c9be278)
![Public pricing page after the pricing formatter removal](https://github.com/user-attachments/assets/e166c7e1-ee56-481c-8c89-24e2e840666a)
<details>
<summary>Evidence: Real engine route answers: 200 no-store, 503, 401</summary>

```text
## Real engine process (uvicorn create_app) against disposable stack
## Setup note: fresh stack denied service_role SELECT on public.revoked_tokens (42501); GRANT applied on the disposable DB only.

$ GET /api/v1/organization-context/fields  (signed in)
[{"key":"legal_name","question":"What is its legal name?","group":"Identity","kinds":["text"],"required":true},{"key":"other_names","question":"Which other names does it use?","group":"Identity","kinds":["text"],"required":true},{"key":"registered_address","question":"What registered address does th
HTTP 200  cache-control=private, no-store

$ GET /api/v1/organization-context  (signed in)
{"error":{"code":"service_unavailable","message":"Organization Context is unavailable."}}
HTTP 503  cache-control=

$ GET /api/v1/cases/6f1b7c0e-3d2a-4b8e-9c41-0a5d2e7f8b13/organization-context  (signed in)
{"error":{"code":"service_unavailable","message":"Organization Context is unavailable."}}
HTTP 503  cache-control=

$ GET /api/v1/organization-context  (no token: adversarial)
{"error":{"code":"token_missing","message":"Authorization header missing or invalid"}}
HTTP 401

$ POST /api/v1/organization-context  (signed in, empty body)
{"error":{"code":"service_unavailable","message":"Organization Context is unavailable."}}
HTTP 503
```
</details>
<details>
<summary>Evidence: Portal network timeline and page state over 60 seconds</summary>

```text
1.7s GET 200 /_next/static/chunks/0-p3_src_app_(authenticated)_cases_%5Bid%5D_organization-context_page_tsx_0i6khph._.js
1.8s GET 503 /api/v1/organization-context
1.8s GET 200 /api/v1/organization-context/fields
1.8s GET 503 /api/v1/cases/6f1b7c0e-3d2a-4b8e-9c41-0a5d2e7f8b13/organization-context
2.9s GET 503 /api/v1/cases/6f1b7c0e-3d2a-4b8e-9c41-0a5d2e7f8b13/organization-context
2.9s GET 503 /api/v1/organization-context
5.0s GET 503 /api/v1/organization-context
5.0s GET 503 /api/v1/cases/6f1b7c0e-3d2a-4b8e-9c41-0a5d2e7f8b13/organization-context
9.0s GET 503 /api/v1/organization-context
9.0s GET 503 /api/v1/cases/6f1b7c0e-3d2a-4b8e-9c41-0a5d2e7f8b13/organization-context
T+10s MAIN: Organization Context The company this Case is about. Choose the organization, then answer or explain each core line; every line keeps its own source, as-of date, fact/inference/opinion label and privacy mark. Vernant does not look anything up on this screen. Organization Context could not be loaded. Reload this page before you save or confirm anything.
T+30s MAIN: Organization Context The company this Case is about. Choose the organization, then answer or explain each core line; every line keeps its own source, as-of date, fact/inference/opinion label and privacy mark. Vernant does not look anything up on this screen. Organization Context could not be loaded. Reload this page before you save or confirm anything.
T+60s MAIN: Organization Context The company this Case is about. Choose the organization, then answer or explain each core line; every line keeps its own source, as-of date, fact/inference/opinion label and privacy mark. Vernant does not look anything up on this screen. Organization Context could not be loaded. Reload this page before you save or confirm anything.
```
</details>
Moved to the first comment on this PR (body size limit): Evidence for the CI database command full log (596 passed, 2 failed) and the real CI assert output (FAIL, 2 failures). Both failing tests were rerun by the pipeline and passed (see the next two Evidence blocks).
<details>
<summary>Evidence: Idempotency test rerun through the allowed port (1 passed)</summary>

```text
.                                                                        [100%]
=============================== warnings summary ===============================
<frozen importlib._bootstrap>:488
<frozen importlib._bootstrap>:488
  <frozen importlib._bootstrap>:488: DeprecationWarning: builtin type SwigPyPacked has no __module__ attribute

<frozen importlib._bootstrap>:488
<frozen importlib._bootstrap>:488
  <frozen importlib._bootstrap>:488: DeprecationWarning: builtin type SwigPyObject has no __module__ attribute

<frozen importlib._bootstrap>:488
  <frozen importlib._bootstrap>:488: DeprecationWarning: builtin type swigvarlink has no __module__ attribute

-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
1 passed, 13 deselected, 5 warnings in 0.47s
```
</details>
<details>
<summary>Evidence: Stage-2b read rerun with my other stacks down (1 passed)</summary>

```text
.                                                                        [100%]
=============================== warnings summary ===============================
<frozen importlib._bootstrap>:488
<frozen importlib._bootstrap>:488
  <frozen importlib._bootstrap>:488: DeprecationWarning: builtin type SwigPyPacked has no __module__ attribute

<frozen importlib._bootstrap>:488
<frozen importlib._bootstrap>:488
  <frozen importlib._bootstrap>:488: DeprecationWarning: builtin type SwigPyObject has no __module__ attribute

<frozen importlib._bootstrap>:488
  <frozen importlib._bootstrap>:488: DeprecationWarning: builtin type swigvarlink has no __module__ attribute

-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html
1 passed, 5 warnings in 141.28s (0:02:21)
```
</details>
<details>
<summary>Evidence: Database memory samples before the signal 9 kill</summary>

```text
supabase_db_nmtrainbportal 176.8MiB / 7.746GiB
supabase_db_nmtrainbportal 177.3MiB / 7.746GiB
supabase_db_nmtrainbportal 178.2MiB / 7.746GiB
supabase_db_nmtrainbportal 403.2MiB / 7.746GiB
supabase_db_nmtrainbportal 3.288GiB / 7.746GiB
supabase_db_nmtrainbportal 4.326GiB / 7.746GiB
supabase_db_nmtrainbportal 133.9MiB / 7.746GiB
supabase_db_nmtrainbportal 187.6MiB / 7.746GiB
supabase_db_nmtrainbportal 186.2MiB / 7.746GiB
supabase_db_nmtrainbportal 186.5MiB / 7.746GiB
supabase_db_nmtrainbportal 187.2MiB / 7.746GiB
supabase_db_nmtrainbportal 187.8MiB / 7.746GiB
supabase_db_nmtrainbportal 187.5MiB / 7.746GiB
supabase_db_nmtrainbportal 186.9MiB / 7.746GiB
supabase_db_nmtrainbportal 186.4MiB / 7.746GiB
supabase_db_nmtrainbportal 186.3MiB / 7.746GiB
supabase_db_nmtrainbportal 188.3MiB / 7.746GiB
supabase_db_nmtrainbportal 187.8MiB / 7.746GiB
supabase_db_nmtrainbportal 187.5MiB / 7.746GiB
supabase_db_nmtrainbportal 186.3MiB / 7.746GiB
supabase_db_nmtrainbportal 186.3MiB / 7.746GiB
supabase_db_nmtrainbportal 188.1MiB / 7.746GiB
supabase_db_nmtrainbportal 187.8MiB / 7.746GiB
supabase_db_nmtrainbportal 187.8MiB / 7.746GiB
supabase_db_nmtrainbportal 186.3MiB / 7.746GiB
```
</details>
<details>
<summary>Evidence: Intake-limits drift check with adversarial inputs</summary>

```text
$ generate_intake_limits.py --check (at head)
Intake-limits codegen artifact is in sync with the engine upload limits.
exit=0

--- committed artifact
/* Auto-generated from vernant_engine/services/corpus_parsers/confinement.py
 * (UPLOAD_PARSE_LIMITS.max_input_bytes). Do not edit manually.
 * Regenerate with: uv run python scripts/generate_intake_limits.py */

export const ENGINE_MAX_CONFINED_FILE_BYTES = 559939584;

--- engine limit now
559939584

--- web consumer
4:import { ENGINE_MAX_CONFINED_FILE_BYTES } from './generated/intake-limits';
61:export const MAX_CONFINED_FILE_BYTES = ENGINE_MAX_CONFINED_FILE_BYTES;

--- ADVERSARIAL: stale artifact (artifact value +1)
DRIFT: vernant-web/src/lib/generated/intake-limits.ts is out of sync with the engine upload limits.
--- vernant-web/src/lib/generated/intake-limits.ts (tracked)
+++ vernant-web/src/lib/generated/intake-limits.ts (regenerated)
@@ -2,4 +2,4 @@
  * (UPLOAD_PARSE_LIMITS.max_input_bytes). Do not edit manually.
  * Regenerate with: uv run python scripts/generate_intake_limits.py */
 
-export const ENGINE_MAX_CONFINED_FILE_BYTES = 559939585;
+export const ENGINE_MAX_CONFINED_FILE_BYTES = 559939584;

exit=1

--- ADVERSARIAL: engine limit changes, artifact not regenerated (real generator, patched limit)
Traceback (most recent call last):
  File "<stdin>", line 3, in <module>
  File "~/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/lib/python3.12/dataclasses.py", line 1588, in replace
    return obj.__class__(**changes)
           ^^^^^^^^^^^^^^^^^^^^^^^^
TypeError: ConfinedParseLimits.__init__() got an unexpected keyword argument 'max_input_bytes'

--- ADVERSARIAL: artifact missing
DRIFT: vernant-web/src/lib/generated/intake-limits.ts is missing
exit=1

--- restored
Intake-limits codegen artifact is in sync with the engine upload limits.
exit=0
status_lines_end

--- ADVERSARIAL: engine memory limit doubled, artifact not regenerated (real generator)
DRIFT: vernant-web/src/lib/generated/intake-limits.ts is out of sync with the engine upload limits.
--- vernant-web/src/lib/generated/intake-limits.ts (tracked)
+++ vernant-web/src/lib/generated/intake-limits.ts (regenerated)
@@ -2,4 +2,4 @@
  * (UPLOAD_PARSE_LIMITS.max_input_bytes). Do not edit manually.
  * Regenerate with: uv run python scripts/generate_intake_limits.py */
 
-export const ENGINE_MAX_CONFINED_FILE_BYTES = 559939584;
+export const ENGINE_MAX_CONFINED_FILE_BYTES = 1365245952;

patched max_input_bytes = 1365245952
exit= 1
```
</details>
<details>
<summary>Evidence: CSV admission before and after the train</summary>

```text
##### HEAD eab72358a
== nonuniform-padding.csv 'Group,  Category\nWest , Retail\n'
   rejection code=<AdmissionRejectionCode.CSV_MALFORMED: 'csv_malformed'> detail='CSV is malformed: inconsistent delimiter padding has ambiguous text values; export consistent CSV' cell_ref=None formula=None
   prose []
   numbers []
   kinds []
== padded-quoted.csv 'Group, Category\nWest, "Retail,local"\n'
   rejection None
   prose ['Group', 'Category', 'West', 'Retail,local']
   numbers []
   kinds ['prose_chunk']
== padded.csv 'Group, Category, Amount\nWest, Retail, 12\nEast, Public, 15\n'
   rejection None
   prose ['Group', 'Category', 'Amount', 'West', 'Retail', 'East', 'Public']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
== pipe-preamble.csv '| validation export\n| prepared by synthetic\n\nRegion,Amount\nW'
   rejection None
   prose ['| validation export', '| prepared by synthetic', 'Region', 'Amount', 'West', 'East']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
== plain.csv 'Region,Amount\nWest,12\nEast,15\n'
   rejection None
   prose ['Region', 'Amount', 'West', 'East']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
== prose-preamble.csv 'Export prepared for reconciliation\nRegion,Amount\nWest,12\nEas'
   rejection code=<AdmissionRejectionCode.CSV_MALFORMED: 'csv_malformed'> detail='CSV is malformed: ambiguous leading record: not a single marked comment before a consistent table' cell_ref=None formula=None
   prose []
   numbers []
   kinds []
exit=0

##### BASE f9e41a9f9 (before train)
== nonuniform-padding.csv 'Group,  Category\nWest , Retail\n'
   rejection None
   prose ['Group', '  Category', 'West ', ' Retail']
   numbers []
   kinds ['prose_chunk']
== padded-quoted.csv 'Group, Category\nWest, "Retail,local"\n'
   rejection None
   prose ['Group', ' Category', 'West', ' "Retail', 'local"']
   numbers []
   kinds ['prose_chunk']
== padded.csv 'Group, Category, Amount\nWest, Retail, 12\nEast, Public, 15\n'
   rejection None
   prose ['Group', ' Category', ' Amount', 'West', ' Retail', 'East', ' Public']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
== pipe-preamble.csv '| validation export\n| prepared by synthetic\n\nRegion,Amount\nW'
   rejection None
   prose ['| validation export', '| prepared by synthetic', 'Region', 'Amount', 'West', 'East']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
== plain.csv 'Region,Amount\nWest,12\nEast,15\n'
   rejection None
   prose ['Region', 'Amount', 'West', 'East']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
== prose-preamble.csv 'Export prepared for reconciliation\nRegion,Amount\nWest,12\nEas'
   rejection None
   prose ['Export prepared for reconciliation', 'Region', 'Amount', 'West', 'East']
   numbers ['12', '15']
   kinds ['observation', 'prose_chunk']
exit=0
```
</details>
<details>
<summary>Evidence: Slot provisioner CLI transcript with adversarial owners</summary>

```text
1. Owner A provisions a clean slot and commits work
  exit=0 {"state": "PASS", "owner_id": "task-a", "branch": "fm/owner-a"}
   manifests: 1
2. ADVERSARIAL: next owner arrives while A's work is NOT on main -> must refuse, record stays
  exit=2 {"state": "BLOCKED", "reason": "stale_manifest_owner_unfinished", "detail": "no MERGED pull request found for this branch \u2014 landing cannot be proven by content. If this branch was rebuilt under another name and its work landed under THAT branch's PR, name it with --anchor-pr <N>: the same per-line proof then runs against that merge commit. If the branch genuinely has no PR, it is unmerged work: preserve it befor
   manifest unchanged: True
3. Happy path: A's commit lands on main; next owner -> stale manifest retired with receipt
  exit=0 {"state": "PASS", "owner_id": "task-b", "branch": "fm/owner-b", "retired_manifest_path": "\u2026/retired/188aa742a99a72eb/704576178662635e56f8c7a78d0cfb2025e71ebc95fd8b59a5ecd6ca154eed86.json"}
   receipt owner_finished: {"method": "ancestry", "branch": "fm/owner-a"} previous owner: task-a tenant: clear
4. ADVERSARIAL: zero-commit previous owner -> refuse
  exit=2 {"state": "BLOCKED", "reason": "stale_manifest_proof_unreadable", "detail": "previous owner's branch has no commits past its recorded base; nothing proves it finished", "next_step": "Request repository-owner manual lifecycle-manifest retirement, then retry provisioning."}
   (B has zero commits past its base, so C must be refused)
5. ADVERSARIAL: previous owner's branch deleted -> refuse, manual retirement
  exit=2 {"state": "BLOCKED", "reason": "stale_manifest_proof_unreadable", "detail": "previous owner's branch is missing; branch-keyed receipts cannot prove this task finished", "next_step": "Request repository-owner manual lifecycle-manifest retirement, then retry provisioning."}
END
```
</details>
<details>
<summary>Evidence: Custody status: citation-rendering at DISPATCH_READY</summary>

```text
$ operational_solution.py status <plan> custody/citation-rendering
note: execution in progress; open tasks: T-citation-rendering-affordance-table, T-citation-rendering-downgrade-enforcement, T-citation-rendering-guest-scoping, T-citation-rendering-payload-schema, T-citation-rendering-projection-flow, T-citation-rendering-revocation-flow, T-citation-rendering-verification
DISPATCH_READY
exit=0
```
</details>
<details>
<summary>Evidence: Custody corpus test and judgement tests</summary>

```text
$ operational_solution.py status custody/citation-rendering
usage: operational_solution.py status [-h] plan case
operational_solution.py status: error: the following arguments are required: case
exit=2

$ pytest scripts/rigor/operational_solution/custody_corpus_test.py
..............                                                           [100%]
14 passed in 82.14s (0:01:22)
exit=0

$ pytest operational_solution_test -k judgement
....                                                                     [100%]
4 passed, 177 deselected in 7.82s
exit=0
```
</details>

- Evidence: Per-file proof at final head (PASS, 20 components, 3583 dropped) (local file: <code>~/.no-mistakes/evidence/01M6CHQRZFYSVRDW9BZAB6WF3H/per-file-proof-final-head.txt</code>)

## Train notes

- **Base commits:** the train was built from `origin/main` at `8e4c2ee094cbc6b3691c2efd07148a1ca6fdcea5` (local head `9edcd1a2a98b1594c40e131ffeb3b158b8354f54`, 20 merge commits, one per component). The pipeline rebase step then moved it onto train A's squash commit `f9e41a9f9cc019e589266937b34e18a4ce4d93f0` and flattened the merges (linear-history rule); this head is `eab72358aa890ddd709c22abd571f777bad5d5a6` with 0 merge commits.
- **Merged components (20):** each is listed with its reviewed head under "Included components" in What Changed above. Each head was fetched from `refs/pull/<N>/head` and matched its listed SHA before merging. PRs 3586 and 3589 are both merged.
- **Dropped component (1):** https://github.com/MrGTV-love/vernant/pull/3583 at `947e211b2fa330fb2762933449fec194c892b1f1`. `git merge origin/pr-3583` stopped on a content conflict in `docs/architecture/c7-option-set-assessment-producer-runtime.md`, which merged PRs 3570 and 3581 also change. The unfinished merge was undone and nothing else changed.
- **Proof at this head, base `f9e41a9f9` (`per_file_proof_v2.py`, RESULT: PASS, failures=0, 20 components):**
  - 156 files with one owner are byte-equal to their component head (`git diff --quiet <component head> <final head> -- <file>`).
  - 3 files were changed by train A after the components forked. Component change and train change are the same, line for line: `docs/product-definition/definition/00-front-and-decisions.md` (PR 3573, 1+/1-), `docs/product-definition/CHANGELOG.md` (PR 3528, 1+/0-), `docs/product-definition/definition/06-plan-and-build-sequence.md` (PR 3528, 1+/1-). Review finding `T2-three-docs-not-byte-equal` was approved on Firstmate ruling d7 under Main 2040.
  - 2 files are changed by two components and recorded with both: `.github/workflows/ci.yml` (PRs 3528 and 3595) and the C7 doc above (PRs 3570 and 3581). Every added line of each owner is present.
  - `git diff --name-only f9e41a9f9 eab72358a` lists 161 files, the same set as the union of the component files. No extra file.
  - Earlier proof at the local build head `9edcd1a2a` on base `8e4c2ee09`: all 20 heads are ancestors, RESULT: PASS.
- **Follow-up (not in this train):** the Document step found that the Status line of the definition files, `START-HERE.md:23` and the `CHANGELOG.md` header still point to `CHANGELOG.md` for history, against the new rule 3 from PR 3573. Firstmate ruled it a no-op follow-up: `vernant-definition-history-pointers-rule3`.

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"eab72358aa890ddd709c22abd571f777bad5d5a6","steps":[{"step":"intent","status":"completed"},{"step":"rebase","status":"completed"},{"step":"gate.rebase.push-checks-start","status":"completed"},{"step":"review","status":"completed"},{"step":"gate.review.push-checks-review","status":"completed"},{"step":"gate.review.retain-review","status":"completed"},{"step":"test","status":"completed"},{"step":"gate.test.push-checks-test","status":"completed"},{"step":"document","status":"completed"},{"step":"gate.document.retain-document","status":"completed"},{"step":"lint","status":"completed"},{"step":"push","status":"completed"},{"step":"pr","status":"running"},{"step":"ci","status":"pending"}],"live_validation":{"verdict":"go","live":9,"total":14}} -->

<details>
<summary>✅ **intent** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Rebase** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **gate.rebase.push-checks-start** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>⚠️ **Review** - 4 issues (2 warnings, 2 infos)</summary>

- ⚠️ `docs/product-definition/definition/00-front-and-decisions.md:437` - Intent rule (3) says a flattening rebase is accepted &#34;when every file is byte-equal to its component reviewed head, proven per file&#34;. At eab72358a three files are not byte-equal to their single owner head: docs/product-definition/definition/00-front-and-decisions.md:437 (PR 3573), docs/product-definition/CHANGELOG.md:55 (PR 3528), docs/product-definition/definition/06-plan-and-build-sequence.md:254 (PR 3528). Cause: the review base f9e41a9f is train A (#3597), and train A changed these same files after the components forked at 5b0a1a54. DoD T2 excepts only files shared by two components, and train A is not a component. No content defect found: the 3573 rule-3 line has the same text, the 06 B5 row has the same sha (1d9921ec), and the 3528 CHANGELOG row is the only added line. All other component files are byte-equal to their heads, and no extra file exists. The two two-component files (.github/workflows/ci.yml, c7 doc) were outside train A&#39;s changes. The recorded proof.txt and per-file-content-proof.local-head.txt were taken at 9edcd1a2a on base 8e4c2ee09, so they do not cover this head. Decision needed: the owner accepts these three files as component change plus newer base, and the proof is re-recorded at the final head with base f9e41a9f. Editing the files would break the no-component-edit gate.
- ⚠️ `vernant_engine/activities/phases/synthesis.py:108` - Dropping PR 3583 (conflict) leaves PR 3570 without its renderer. On a C7-enabled fresh Case, the prompt (synthesis.py:206) now invites a synthesized conclusion id, _settle_key_finding keeps it (synthesis.py:108), named_key_finding can pass it to the package (option_assessment.py:352; test_option_assessment_composer pins keyFindingId == synthesis_a), and render_template.py:1147 resolves findings only. The page then prints the raw id with &#34;(finding not in this package)&#34; where it printed &#34;Key finding unavailable&#34; before. Reachable only with option_assessment_enabled, which defaults off (pipeline.py:620); no non-test code sets it true in my grep. The c7 doc line 42 discloses this state, and the intent allows a drop. Follow-up: a 3583 successor must resolve its doc conflict, because its text &#34;no producer emits a synthesis id yet&#34; is false after 3570. Do not enable the flag for customers before that lands.
- ℹ️ `vernant_engine/models/shared/admission_store.py:27` - The docstring says direct header reads use the default RPC ceiling, and the a8 contract status says revision 6 enforces it in header readers. _read_admission_header (admission_store.py:158) has no ceiling parameter; only read_admission_result caps it (min at the header call). Its only other callers are two test modules, so no runtime read exceeds the ceiling. Wording only; leave for a follow-up because the component bytes must stay unchanged.
- ℹ️ `docs/product-definition/CHANGELOG.md:55` - PR 3573 changes rule 3 (00-front-and-decisions.md:437) so a change no longer gets a CHANGELOG.md line, and history goes in the dated registers. PR 3528 in the same train adds a new CHANGELOG.md row. Each PR is correct alone; the combined tree has one row written against the new rule. No behavior impact and no gate reads it in my review. Follow-up only.
</details>

<details>
<summary>✅ **gate.review.push-checks-review** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **gate.review.retain-review** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>✅ **Test** - passed</summary>

✅ No issues found.
- Live validation: ✅ go - 9 of 14 scenarios driven live against the product

| Scenario | Result | Live | Evidence |
| --- | --- | --- | --- |
| B5 persistence first in the CI order: run the new ci.yml command on a freshly migrated database and see all 14 B5 tests pass before any historical replay | ✅ pass | live | db-integration.log (B5 tests at lines 13 onward, 14 PASSED, 0 not passed) |
| Whole CI database lane on the combined tree: run the full command and the fail-closed assert with all floors, and see exit 0 | ⏸️ untested | no | I ran the whole command once and it exited 1, so no local run shows a green lane. I did not rerun all 598 tests in one clean pass. Failure 1: test_portal_session_create_idempotency allows only ports 5… |
| Drift check catches a stale drop-zone bound: the check passes at head and exits 1 when the artifact is stale, the engine limit changes, or the artifact is missing (PR 3595 with PR 3588) | ✅ pass | live | s-intake-limits.txt (head exit 0 at 559939584; each of the three adversarial cases exit 1 with DRIFT or missing; restored exit 0) |
| User opens New case in the real portal and sees the generated bound: PDF, Word and PowerPoint files up to 530 MB | ✅ pass | live | cases-new-before-dropzone.png, s-portal.txt |
| Signed-in user calls Organization Context on the real engine: fields answer 200 no-store, service routes answer the 503 envelope, no token answers 401 | ✅ pass | live | s-org-context-engine.txt |
| User opens the Organization Context page while the service is unwired: the page shows a red could-not-be-loaded message after retries and does not stay on loading | ✅ pass | live | organization-context-page.png, s-portal-org.txt |
| User saves and confirms an organization profile through the portal screens | ⏸️ untested | no | The shipped engine leaves the Organization Context service unbuilt by design (D7-owned lifespan hookup), so these routes answer 503 and the form cannot render against the real product. I drove the rea… |
| Custody pair lands together: the custody CLI reports citation-rendering at DISPATCH_READY and the corpus gate is green with PRs 3586 and 3589 both present | ✅ pass | live | s-custody-status.txt (DISPATCH_READY, exit 0), s-custody.txt (14 passed) |
| Slot provisioner retires only a proven-finished owner: finished owner retired with a receipt; unfinished, zero-commit and deleted-branch owners refused with exit 2 and records preserved | ✅ pass | live | s-slot-provisioner.txt (throwaway repo with a stub gh; stale_manifest_owner_unfinished, stale_manifest_proof_unreadable, ancestry receipt) |
| CSV reading: padded delimiters are read without stray spaces, pipe-comment preambles are kept, and ambiguous files are refused as csv_malformed, compared with base | ⏸️ untested | no | The prior payload did not establish a live result. I called the `admit_csv` entry point directly on throwaway files. `dispatch_parse` sent these CSVs to passthrough, and a grep found no non-test calle… |
| Hook dispatcher does not preload optional modules, and a needed parser that fails still fails closed; signer interpreter name must match exactly | ⏸️ untested | no | The prior payload did not establish a live result. Only existing tests covered this. The dispatcher tests spawn real subprocesses, but I did not run a live hook session or a signer host. |
| Admission RPC ceiling, text estimate once per request, C7 key finding and truthful reason, account export set ids, parser timeout capture | ⏸️ untested | no | The prior payload did not establish a live result. Only targeted tests covered this, apart from the stage-2b read through the ceiling on real Postgres. C7 is off by default and needs model calls, so i… |
| Public pricing page still renders after dead formatters are removed | ✅ pass | live | pricing.png, s-portal.txt, targeted-web-tests.txt (213 passed) |
| Train content equals the reviewed component heads: per-file proof at the final head with base f9e41a9f, 3583 dropped, no extra file | ✅ pass | live | per-file-proof-final-head.txt (RESULT: PASS, failures=0, components=20; the 3 base-changed files are SAME per the recorded owner-relayed decision) |

- `env VERNANT_TEMPORAL_START_CAPTURE=1 VERNANT_PARSER_CHILD_TIMEOUT_CAPTURE=1 uv run python scripts/ci/shard_map.py local`
- <code>Baseline (already run by the pipeline): `env VERNANT_TEMPORAL_START_CAPTURE=1 VERNANT_PARSER_CHILD_TIMEOUT_CAPTURE=1 uv run python scripts/ci/shard_map.py local`</code>
- <code>`supabase db start --workdir &lt;tmp&gt;` with a unique project id and ports, then `python -m vernant_operator.tools.account_erasure_release --local-disposable-reset --supabase-workdir &lt;tmp&gt;`</code>
- <code>CI command: `pytest vernant_engine/tests/integration/test_organization_context_persistence.py vernant_engine/tests/unit/db/ -m &#34;integration and not expensive&#34; --junitxml` (exit 1: 596 passed, 2 failed, 14 of 14 B5 tests passed first)</code>
- <code>`python scripts/ci/assert_integration_ran.py integration-report.xml` with all CI floors (real result FAIL, because of the 2 failures)</code>
- <code>Rerun alone: `pytest vernant_engine/tests/unit/db/test_portal_session_create_idempotency.py` through a 58322 port forwarder (1 passed)</code>
- <code>Rerun alone with my other stacks down: `pytest vernant_engine/tests/unit/db/test_stage2b_live_full_read.py` (1 passed)</code>
- <code>`uv run python scripts/generate_intake_limits.py --check` at head, with a stale artifact, with a doubled engine limit, and with the artifact missing</code>
- <code>`uvicorn --factory vernant_engine.app:create_app` against a disposable stack: curl of the organization-context routes signed in and with no token</code>
- <code>`next dev` portal with Playwright and Chrome: `/login` as a synthetic user, `/cases/new`, `/cases/&lt;uuid&gt;/organization-context`, `/pricing`</code>
- `scripts/rigor/operational_solution/operational_solution.py status <plan-003> custody/citation-rendering`
- <code>`pytest scripts/rigor/operational_solution/custody_corpus_test.py` and `operational_solution_test.py -k &#34;judgement or AWAITING&#34;`</code>
- <code>`scripts/git-stability/provision_existing_slot.py` CLI against a throwaway git repo with a stub `gh` that answers no PR</code>
- <code>`admit_csv` called directly on 6 throwaway CSV files, at head and at base f9e41a9f9</code>
- `per_file_proof_v2.py <worktree> f9e41a9f9 eab72358a components.txt 3583 <evidence>`
- `pytest scripts/hooks/hook_dispatcher_lazy_import_test.py vernant_engine/tests/unit/tools/test_prospective_canary_host_operator.py -k "lazy or unused or needed or h1 or interpreter or signer"`
- <code>`pytest` targeted: test_admission_store, test_text_estimate, test_dispatch, test_parser_child_timeout_capture, test_option_assessment, test_synthesis, test_option_assessment_composer, test_export_case_origin, test_organization_context_unwired, test_organization_context_routes, provision_existing_slot_test</code>
- <code>`vitest run` for corpus-operations, FileDropZone, pricing-surface-agreement, organization-context lib and page tests</code>
</details>

<details>
<summary>✅ **gate.test.push-checks-test** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>⚠️ **Document** - 1 warning</summary>

- ⚠️ `docs/product-definition/definition/00-front-and-decisions.md:3` - PR 3573 changed rule 3 (00-front-and-decisions.md:437), so set history now lives in the dated registers, not CHANGELOG.md. Other always-read text still says the opposite: the Status line of all 8 definition/00 to 07 files says &#34;history is in `CHANGELOG.md` and `archive/`&#34;, START-HERE.md:23 routes &#34;What changed&#34; to CHANGELOG.md, and the CHANGELOG.md header says &#34;One line per change that matters&#34;. This differs from the declined changelog-row-vs-new-rule item, which concerned only the PR 3528 row. I did not edit these files: 00 and 06 and CHANGELOG.md are component files that intent rule 3 holds byte-equal, the other files would add a file from no component, and the project rule bars planning-doc edits unless asked. Follow-up: a separate PR after the train should change these pointers to match rule 3.
</details>

<details>
<summary>✅ **gate.document.retain-document** - passed</summary>

✅ No issues found.
</details>

<details>
<summary>⚠️ **Lint** - 1 info</summary>

- ℹ️ `schemas/organization-context/contract.ts` - I could not check schemas/organization-context/contract.ts for drift against contract.schema.json. The json2ts tool named in schemas/organization-context/generate.py is not at node_modules/.bin/json2ts after npm ci. The JSON schema check `generate.py --check` passed (exit 0), so only the TypeScript derivation is unverified. All other checks passed: ruff check, ruff format, actionlint, lint-imports, mypy on changed engine source, eslint, the anti-slop ratchet (0 added against the base commit) and generate_intake_limits.py --check.
</details>

<details>
<summary>✅ **Push** - passed</summary>

✅ No issues found.
</details>


