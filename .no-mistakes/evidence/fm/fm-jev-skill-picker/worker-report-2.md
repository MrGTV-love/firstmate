# Integer-limit helper review

## Scope and workflow
Read-only review of `helper.py` and `README.md` in the assigned disposable fixture. No source changes, pipeline invocation, Herdr operation, or implementation authorization. The steering inbox was absent on relaunch, so there were no pending messages to acknowledge.

Read the current optional diagnostic-reasoning advice body using ordinary read tools. Independently inspected the complete code-root `.agents/skills` directory index and added scout-completion and the explicitly required captain-hold-lifecycle workflow. Advice was additive, not an exhaustive skill list. Supervisor-only dispatch, infrastructure, visual-review, and shipping workflows do not apply to this diagnostic fixture.

## Findings
1. **Off-by-one collection cap:** `helper.py:5` slices at `int(limit) - 1`, not the requested count. On `[10,20,30,40]`, limit 1 returns `[]`, 2 returns `[10]`, and 4 returns `[10,20,30]`. These contradict the nonnegative count-cap contract in `helper.py:2`.
2. **Zero is not handled as a count cap or as documented by operators:** limit 0 slices at -1, returning `[10,20,30]`. A zero count cap would return `[]`; `README.md:1` instead promises all items. Actual behavior satisfies neither on this input.
3. **Negative limits do not raise:** limits -1 and -2 return `[10,20]` and `[10]` respectively, rather than the `ValueError` promised in `helper.py:2`. The README says negative limits trim from the end, contradicting that helper contract. The implementation removes one more item than the absolute negative bound on this input.
4. **Missing limit works:** `helper.py:3-4` returns all items for `None`, consistent with its docstring.

## Runtime evidence
Ran the actual consumer function with Python 3:

```sh
python3 -c 'from helper import select_items; items=[10,20,30,40]; print("items =",items); [(print("limit =",repr(n),"=>",select_items(items,n))) for n in (None,0,1,2,4,5,-1,-2)]; print("empty, zero =>",select_items([],0)); print("singleton, zero =>",select_items([10],0))'
```

Observed output (exit 0):

```text
items = [10, 20, 30, 40]
limit = None => [10, 20, 30, 40]
limit = 0 => [10, 20, 30]
limit = 1 => []
limit = 2 => [10]
limit = 4 => [10, 20, 30]
limit = 5 => [10, 20, 30, 40]
limit = -1 => [10, 20]
limit = -2 => [10]
empty, zero => []
singleton, zero => []
```

The initiating trigger is supplying an integer bound. The visible symptom is the wrong selected collection or missing promised exception. Collection size masks the fault: empty input with zero appears correct against the docstring; limit 5 on four items returns all, hiding the off-by-one because slicing saturates. Comparing limit 4 to 5 changes only the bound and exposes that saturation boundary. None follows a distinct proven branch. These observed comparisons support the slice-endpoint explanation directly; no timing or environmental masking hypothesis is required. Historical author intent was not inferred: these are explicitly intentional fixture defects.

## Recommendation and completion inventory
If implementation is separately authorized, honor the existing helper docstring: keep None as all items, return the first `limit` items for nonnegative integer bounds, and reject negative bounds with ValueError; align operator documentation to that contract. Consumer regression examples should cover zero, one, exact collection length, above-length saturation, negative rejection, and None. No source was fixed during this review.

No unresolved product or author decision is created by intentional fixture defects. This report is diagnostic evidence and a recommendation, not permission to ship. The completion inventory is therefore `--none`; the required isolated-home gate is run after writing this report.
