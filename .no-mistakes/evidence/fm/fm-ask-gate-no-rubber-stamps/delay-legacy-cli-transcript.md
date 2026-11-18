# Delay accounting + legacy compatibility, real bin/fm-captain-hold.sh at d90178a6 in disposable lab home
## S6: captain answers call1 with its recorded recommendation value 'approve' -> one delay row

$ bin/fm-captain-hold.sh answer call1 --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-approve.txt
answered: call1
[exit=0]
--- data/error-log.jsonl:
{"answer":"  approve \n","at":"2026-11-18T08:55:35.595043Z","hold_id":"call1","hours_open":0.02,"kind":"delay"}
---
## S7: exact replay of the same answer does not duplicate the row

$ bin/fm-captain-hold.sh answer call1 --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-approve.txt
answered: call1
[exit=0]
--- data/error-log.jsonl:
{"answer":"  approve \n","at":"2026-11-18T08:55:35.595043Z","hold_id":"call1","hours_open":0.02,"kind":"delay"}
---
## S8: different answer -> no delay row

$ bin/fm-captain-hold.sh hold call2 --title Second charge --reason Decision sought: x
Recommendation: Approve (approve) --boundary spend --if-no Skip it --recommendation approve
call2
[exit=0]

$ bin/fm-captain-hold.sh answer call2 --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-decline.txt
answered: call2
[exit=0]
--- data/error-log.jsonl:
{"answer":"  approve \n","at":"2026-11-18T08:55:35.595043Z","hold_id":"call1","hours_open":0.02,"kind":"delay"}
---
## S9: hold with Recommendation prose but no --recommendation flag; answer equals prose -> no row (prose not guessed)

$ bin/fm-captain-hold.sh hold call3 --title Third --reason Decision sought: x
Recommendation: approve --boundary spend --if-no Skip it
call3
[exit=0]

$ bin/fm-captain-hold.sh answer call3 --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-approve.txt
answered: call3
[exit=0]
--- data/error-log.jsonl:
{"answer":"  approve \n","at":"2026-11-18T08:55:35.595043Z","hold_id":"call1","hours_open":0.02,"kind":"delay"}
---
## S10: malformed/blank/non-object rows already in the log are preserved; matching answer still appends once

$ bin/fm-captain-hold.sh hold call4 --title Fourth --reason Decision sought: x --boundary irreversible --if-no Keep current state --recommendation approve
call4
[exit=0]

$ bin/fm-captain-hold.sh answer call4 --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-approve.txt
answered: call4
[exit=0]

$ bin/fm-captain-hold.sh answer call4 --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-approve.txt
answered: call4
[exit=0]
--- data/error-log.jsonl:
{"answer":"  approve \n","at":"2026-11-18T08:55:35.595043Z","hold_id":"call1","hours_open":0.02,"kind":"delay"}

not json at all
[1,2,3]
"str"
{"answer":"  approve \n","at":"2026-11-18T08:58:16.237546Z","hold_id":"call4","hours_open":0.01,"kind":"delay"}
---
prefix bytes preserved: yes
## S11: legacy hold (filed by base 03727baf writer, no boundary) stays readable and re-holds without new flags

$ env FM_ROOT_OVERRIDE= /Users/charlesabrooker/tmp/fm-lab.SaEyI3/base/bin/fm-captain-hold.sh hold old --title Legacy call --reason Legacy decision
old
[exit=0]
$ tasks-axi show old --full | body
  state: queued
  held: yes
  closed: "-"
  body: "Captain hold set: 2026-11-18T08:58:32Z"

$ bin/fm-captain-hold.sh open old
[exit=0]

$ bin/fm-captain-hold.sh hold old --reason Later --until 2099-01-01
old
[exit=0]
$ tasks-axi show old --full | body
  state: queued
  held: yes
  closed: "-"
  body: "Captain hold set: 2026-11-18T08:58:32Z"
## S12: a released legacy task re-held as a NEW hold must now supply --boundary

$ bin/fm-captain-hold.sh answer old --decision-file /Users/charlesabrooker/tmp/fm-lab.SaEyI3/ans-old.txt --release
released: old
[exit=0]

$ bin/fm-captain-hold.sh hold old --reason Ask again
fm-captain-hold: Main decides: a new captain hold requires --boundary credential, spend, destructive, irreversible, tool-denial, or owner-rule-change
[exit=1]
