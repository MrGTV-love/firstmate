live-admission-transcript.txt: first full pass. Its 5 FAILED lines are driver bugs, not product failures:
  1. peaks_for(R, S) with S < R swapped the two values, so the start fit the formula and was correctly admitted (4 lines).
  2. The driver's own census inherited NM_HOME from the agent shell; the product ran under the lab environment (1 line).
live-admission-transcript-rerun.txt: the fixed budget, held and reattach scenarios, 16 of 16 checks pass.
live-admission-highload.txt: real load5 37.5 above the old limit of 36: head admits 3, base waits.
fixture-admission-test.txt: tests/fm-cpu-pass.test.sh, not live; covers real pressure and pile-up branches at the fixture boundary.
drive_admission.py: the driver. Its no-mistakes command is a stand-in that writes a row to the disposable database.
