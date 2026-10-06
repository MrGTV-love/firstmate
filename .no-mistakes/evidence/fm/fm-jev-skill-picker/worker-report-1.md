# Integer-limit helper review

## Scope and workflow
Read-only review of the disposable fixture's `helper.py` and `README.md`; no source edits, permanent tests, memory/configuration changes, pipeline calls, or Herdr operations. Read the live Jev suggestion `diagnostic-reasoning` as relevant optional advice. Independently inspected the complete code-root `.agents/skills` directory index and added `operational-home-layout` for the named report/home paths and the explicitly required `captain-hold-lifecycle` completion policy. Supervisor, shipping, visual-review, and Herdr workflows do not apply to this worker's text-only diagnostic task. The steering inbox was absent when checked.

## Findings
1. **Off-by-one collection bound:** `helper.py:2` promises nonnegative bounds cap the count; `helper.py:5` slices at `int(limit) - 1`, returning one fewer item than the conventional requested count for positive bounds within the collection length. In particular, limit 1 returns nothing. Zero uses slice endpoint -1 and returns every item except the last, violating the zero cap.
2. **Negative bounds do not raise:** `helper.py:2` explicitly promises `ValueError`; `helper.py:5` instead accepts negative integers and trims `abs(limit) + 1` items from the end, saturating to an empty list.
3. **Operator documentation contradicts both the helper contract and execution:** `README.md:1` says zero returns all items, but zero drops the final item on a nonempty list. Its negative-trimming statement conflicts with the docstring's required exception. Negative values do trim, but the README does not explain that -1 removes two items rather than one.
4. The missing-bound path is correct against its explicit contract: `helper.py:3-4` returns all items for `None`.

## Executed evidence
Command (Python bytecode writes disabled):

```sh
python3 -B -c 'from helper import select_items; items=[10,20,30,40]; print("items=",items); [(print("limit=%r -> %r" % (n,select_items(items,n)))) for n in (None,0,1,2,4,5,-1,-2,-4)]; print("empty, zero ->",select_items([],0)); print("singleton, zero ->",select_items([10],0)); print("generator, two ->",select_items(iter(items),2)); print("counterfactual slice two ->",list(items)[:2])'
```

Observed output:

```text
items= [10, 20, 30, 40]
limit=None -> [10, 20, 30, 40]
limit=0 -> [10, 20, 30]
limit=1 -> []
limit=2 -> [10]
limit=4 -> [10, 20, 30]
limit=5 -> [10, 20, 30, 40]
limit=-1 -> [10, 20]
limit=-2 -> [10]
limit=-4 -> []
empty, zero -> []
singleton, zero -> []
generator, two -> [10]
counterfactual slice two -> [10, 20]
```

The direct function call is the fixture's available consumer surface; no operator CLI is provided. Positive-bound consumer regression examples are `select_items([10,20,30,40], 1)` expecting `[10]` and limit 2 expecting `[10,20]`; zero should expect `[]` under the helper's stated cap contract; negative integers should expect `ValueError` under its explicit docstring. Expected semantics here are grounded in the docstring, not a newly chosen product policy.

## Causal analysis and limitations
Trigger: supplying a finite integer bound. Earliest divergence: the unconditional subtraction in the slice endpoint at `helper.py:5`, plus absence of the promised negative check. Visible symptom: incorrect returned elements or a missing exception. Masking conditions: `None` bypasses the faulty branch; empty input makes zero look correct; a bound strictly greater than the input length can return all items despite the subtraction. The singleton-zero and limit-5 examples demonstrate these boundaries rather than treating the proven `None` path as universal success. Generator input reproduces the positive-bound issue, disconfirming a list-only explanation. A source-unmodified counterfactual `list(items)[:2]` gives the intended two items, supporting the endpoint diagnosis; it does not by itself repair negative handling. Repository history was not needed to establish the arithmetic and documentation contradiction in this intentionally defective disposable fixture. Noninteger coercion policy and infinite iterables were not assessed.

## Recommendation and completion inventory
If promoted to authorized implementation, align the helper with its explicit docstring: preserve missing-bound behavior, reject negative integer bounds, and use the nonnegative bound itself as the slice endpoint; update the README to the same zero/negative semantics. Preserve the concrete zero, one, two, and negative regression examples. Do not modify this intentional fixture as part of this read-only assignment.

No unresolved author/product decision exists: the defects are intentional test data and the deliverable is diagnostic evidence, not implementation approval. The completion inventory is therefore `--none`; execute the required isolated-home completion gate before declaring done.
