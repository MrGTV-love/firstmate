### Contract validation

Validate at the layer where the contract is defined: a check must survive changes that preserve the contract and fail when the contract is violated.
Before writing or changing a hook, guard, or automated test, record these three fields for each changed contract in the existing change or test record:

1. **Invariant:** State what must remain true, including the closest legitimate behavior that must still work.
2. **Authority:** Cite the specific requirement, approved policy, specification, or independent registry that defines the expected result.
3. **Boundary:** Name the entry point, downstream consumer, or enforcement point where the result can be checked.

Derive expectations from the authority, never from the implementation under test.
Source-analysis rows and examples apply to linters and guards whose checked input is source; automated tests still exercise behavior and never assert implementation-source bytes, as the [repo style rules](#repo-style-rules) require.
Use `hook-design` for harness lifecycle proof, `guard-design` for protection proof, and `hook-audit` when assessing an existing control's operational value.
- **Observe the boundary:** Assert the promised effect through the real public entry point or installed hook runner and downstream consumer where applicable; a handler call or its log alone proves neither wiring nor protection.
- **Exercise failure paths:** Drive malformed input, missing policy data, and timeouts through the real runner where applicable.
  A blocking guard fails closed if it cannot establish permission; an advisory hook may proceed only as an explicit, observable choice.
- **Bound cost:** Scope the matcher, set deadlines, cap retries and output, and check that execution and late effects stay within the declared bounds.
- **Check diagnostics:** Require a stable reason code and actionable context, with file and line when attributable, and no secret payloads.

In the same record, account for every applicable preflight item and every case required by the owning proof procedure, reusing its evidence format where one exists.
For each case, identify the contract and record **Case | Expected | Observed | Evidence | Verdict**, with a reproducible command or a link to the run that shows the observation on the current change.
Use `pass` when the observation matches the expected result, `fail` when it contradicts it, and `unverified` when evidence is missing.
Record `not applicable` with a reason when a preflight item genuinely cannot affect the contract.
**Exit:** Preflight is complete only when every required case passes and every omitted item has a reason it does not apply.

### Harness-dependent checks
