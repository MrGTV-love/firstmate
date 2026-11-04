# Test-phase evidence, fm/fm-completion-cleanup-invariant

Head: 5bda55beb59c2b74974e78ceef999eae84576c75 (see head-sha.txt). Base: 9c5874baa.

| File | What it shows |
|---|---|
| merge-prune-xlane-v5.txt | V3 cross-lane merge (two no-poll variants), V3 open/closed PR, V7 same lane, late teardown failures (C3), V7 protections, kept refusal on row, V5 five-task table. XL_BOUND=900. rc=0. |
| teardown-v2.txt | V2: detached copy judged through record branch; unlanded work still refused; named branch as before. rc=0. |
| teardown-v2-under-proc-budget-setup-failure.txt | First V2 attempt under fm-proc-budget: case temp dir vanished mid-run ("not a git repository"). Re-run plain and later re-run under the budget both passed. Environment, not product. |
| pr-check-security-new.txt | Named-head gate skips only an exact forge head; bare-URL done with copy gone needs a merge proof. rc=0 each. |
| fm-dod-lib-suite.txt | Whole DoD-lib suite incl. V1 parser rows and F3 reason split. rc=0. |
| fm-pr-ready-reconcile-suite.txt | Whole reconcile suite incl. bare-URL registration and lost-poll re-arm. rc=0. |
| fm-open-loops-suite.txt | Whole open-loops suite incl. V4 rows and F3 ledger cases. |
| f3-live-chain.sh | Driver: lab home (bin/fm-lab-home.sh env), real tmux on the lab's private socket, real fm-crew-state.sh, fm-fleet-snapshot.sh, fm-open-loops.sh; fakes only for `no-mistakes` and the forge (`gh api -i`). |
| f3-live-chain.txt | Head: four refusal modes give four reasons; down -> no pending row (wait); norun, uninit, unreadable -> pending_acceptance owned by firstmate, for a PR another lane merged. PASS. |
| f3-live-chain-before-b794ef687.txt | Same driver on the commit before the F3 fix: all four read "could not be read"; no task gets an owned row. FAIL (the defect). |
| f3-live-chain-attempt1..3-*.txt | Earlier driver attempts with fixture flaws (work on main; unlanded cover; no PR). Kept for honesty. |
