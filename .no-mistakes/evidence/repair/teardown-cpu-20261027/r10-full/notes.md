# Round 10: one bounded full-suite reproduction (HEAD 609f8093)
Command: FM_R10_EVIDENCE=<this dir> bash tests/fm-wake-queue.test.sh (original membership/order/assertions/deadlines).
Temporary observation: temp-observation.diff (tests/wake-helpers.sh only; pre-TERM case copy in wait_for_exit timeout
branch after the existing printf+ps snapshot, and a first-fail case copy before exit). Restored via git checkout before return.
Result: exit=0 (caller's actual exit after ordinary EXIT cleanup), 83 ok, 0 not ok, 09:38:34-09:43:49, load ~12 on 18 CPUs.
Timeout branch never fired: no pre-term.meta / fail.meta written; observation overhead on the pass path = one env test per call.
In-suite timing: queue held=1204 control=1138; presentation held=2188 control=1190 (passed in-suite limits).
Verdict: INCONCLUSIVE, not fixed and not waived. No failure boundary captured. r8 failure (load ~58) and earlier
presentation failures remain unresolved. Host load differed sharply (12 vs 32-58), which is a correlation only.
No second reproduction run (one-run bound).
