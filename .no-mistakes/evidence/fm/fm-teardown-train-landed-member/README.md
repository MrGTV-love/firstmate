# Live validation: teardown accepts a ship landed by a merged merge-train PR

Target commit: 1259aee14bdde8b9f4950da0f92a396b15108449 (base 9c5874baa019f4f14450901985fc46476b0dc64b).

How each live run works (live-driver-drive.sh):
- The REAL bin/fm-teardown.sh runs in a fresh marked lab home (bin/fm-lab-home.sh env), torn down after each run.
- The task's project is a disposable blob:none clone of https://github.com/MrGTV-love/vernant.
- The REAL gh reads the REAL forge (read-only: pr view, pr list --search).
- Only treehouse, tmux, docker and no-mistakes are stubs (the hard gates forbid the real ones). treehouse logs its calls.
- No real copy was torn down. The real d1 B5 copy was only read with git (rev-parse, status, and a fetch FROM it into the disposable clone).

| Run | Expected | Result |
|---|---|---|
| live-record-3528.txt | copy gone, PR 3528 CLOSED, train 3599 MERGED: accept; backlog row pr=3599, note "closed by merge train: .../3528" | exit 0, matches |
| live-work-3528-prhead.txt | clean copy at PR head 0b2e8a9f: accept by train route | exit 0, train line printed, treehouse return called once |
| live-work-d1b5-real-copy-head.txt | real d1 B5 copy head 5714eb0f: refuse (recorded ruling Main 3011 F1) | exit 1, names 0bb1ac955 not carried by train 3599 |
| live-record-3567-unlisted.txt | real CLOSED PR listed by no PR: refuse | exit 1, "no PR found by the forge lists it at a 40-hex sha" |
| live-work-3528-search-fails.txt | train search fails (injected, live-fault-search-gh.sh): unknown, never "not landed" | exit 1, "not known", "unknown, retry", guard source_ok=false |
| live-work-3528-extra-unlanded-commit.txt | PR head + one unlanded commit: refuse naming it | exit 1, names 71a6f79c7 |
| live-work-3528-dirty-copy.txt | dirty copy: existing dirty refusal first | exit 1, dirty refusal, no train read |
| live-record-3528-captain-held.txt | captain-held row: teardown keeps it held; answer closes with train PR + member note | done row links 3599 and says "closed by merge train: .../3528" |

Raw forge reads: live-forge-search-3528.json (search returns only 3599 MERGED into main), live-pr3599-body.md, live-pr3567.json.
Real data fact: PR 3528 head 0b2e8a9f is NOT an ancestor of train head eab72358, so the flat-replay route (kept by Main 2863) is what accepts it.
Fixture noise: "STUCK: on branch main with uncommitted changes" refers to the disposable --no-checkout clone, not the product.
Suites (fake gh, not live): suite-*.txt and suite-summary.txt.
