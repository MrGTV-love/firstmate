# G142 measurement note (test phase)

Threshold check: NOT APPLICABLE. The change adds no threshold, limit, window, or count.
The only new decision is a string test: the first argument is exactly `--help` or `-h`.
Because there is no number, no measurement is needed. The proof of the change is the paired run.

Inputs checked:
- `git diff 7f3a198b..9418fb9b -- bin/fm-send.sh` adds one `if` block for a leading `--help` / `-h`.
- Live transcript: `G141/live-transcript.txt` (base vs head, scratch copies, FM_HOME unset).
- Paired test run: `../G14V/paired-summary.txt` (logs in ../G14V/).

Harm statement and PR body: NOT checked by the test phase. The PR body is outside this phase.
The grader must confirm the PR body states the harm in plain words and names the proxy it replaces.
