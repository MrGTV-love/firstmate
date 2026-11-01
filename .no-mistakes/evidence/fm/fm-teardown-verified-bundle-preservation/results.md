# Lab results (target 2c87c3b11)

- S1 main chain (no bundle refuse -> no hold refuse -> printed hold cmd -> ordinary teardown exit 0 -> restore after source deletion): PASS. transcripts/s1-main-chain.txt, transcripts/s1b-main-chain-cont.txt
- S2a wrong sha256: refused, copy/meta/endpoint kept: PASS
- S2b missing later tip: refused; re-bundled + re-held: removed, both commits restore: PASS
- S2c dirty + valid bundle: dirty refusal unchanged text, bytes kept: PASS
- S2d .afk + valid bundle: refused (attended only): PASS  (transcripts/s2-adversarial.txt)
- S3 base vs new: wrong-sha and dirty refusal blocks identical; base refuses a fully valid bundle (new accepts); --force without drop words refused identically on both: PASS (transcripts/s3-before-after-force.txt)
- S4 --force --drop-file: new and base both remove (unheld lbndl5/lbndl7; held lbndl9/lbndl10 identical outputs): PASS (transcripts/s4-force-drop.txt, transcripts/s5-force-held.txt)
- S6 nested anchored prior + unique ignored bytes, current copy present: exit 1 before any reap (sentinel alive, endpoint alive, bytes kept, meta kept); clean control exit 0, prior removed, slot returned: PASS (transcripts/s6-nested-prior-present.txt)
- S7 removed current copy (branch admitted by bundle) + anchored prior unique bytes: exit 1 before retire (sentinel alive, endpoint alive, bytes kept); clean control removed, restores from stored bundle after source deletion: PASS (transcripts/s7-nested-prior-removed-copy.txt)
- S8 secondmate retirement with stored bundle in its home: ordinary and forced both exit 1 before any removal (endpoint alive, child record+copy kept, bundle kept); after moving bundle out, both retire: PASS (transcripts/s8-secondmate-retirement.txt ordinary half, transcripts/s8b-secondmate-forced-rerun.txt forced)
- S9 Recently Landed: landed control lbndl11 listed; bundle-kept lbndl1 (captain-answered, closed) and lbndl3 (held) not listed: PASS (transcripts/s9-recently-landed.txt, transcripts/s9-bearings.json)
- S10 (idle-reaper / branch actor / malformed / symlink / truncated live shapes): NOT RUN — step ended before it; fixture tests cover them
