# Lab home: $FM_HOME (disposable fm-lab-home), real bin/fm-captain-hold.sh + tasks-axi at d90178a6
## S1: new hold with NO --boundary is refused, backlog unchanged

$ bin/fm-captain-hold.sh hold call1 --title Pick a color --reason Decision sought: color
fm-captain-hold: Main decides: a new captain hold requires --boundary credential, spend, destructive, irreversible, tool-denial, or owner-rule-change
[exit=1]
backlog unchanged: yes
## S2: unknown boundary name refused

$ bin/fm-captain-hold.sh hold call1 --title Pick a color --reason Decision sought: color --boundary convenience --if-no Pick blue
fm-captain-hold: Main decides: a new captain hold requires --boundary credential, spend, destructive, irreversible, tool-denial, or owner-rule-change
[exit=1]
## S3: wrong case boundary refused

$ bin/fm-captain-hold.sh hold call1 --title Pick a color --reason x --boundary Spend --if-no Pick blue
fm-captain-hold: Main decides: a new captain hold requires --boundary credential, spend, destructive, irreversible, tool-denial, or owner-rule-change
[exit=1]
## S4: whitespace-only --if-no refused

$ bin/fm-captain-hold.sh hold call1 --title Pick a color --reason x --boundary spend --if-no    
fm-captain-hold: Main decides: a captain hold requires a nonempty --if-no action
[exit=1]
backlog still unchanged: yes
## S5: valid boundary + if-no accepted and stored for readback

$ bin/fm-captain-hold.sh hold call1 --title Authorize the charge --reason Decision sought: Authorize the $20 charge
Recommendation: Approve the charge (approve) --boundary spend --if-no Continue without the paid operation --recommendation approve
call1
[exit=0]

$ (cd $FM_HOME) tasks-axi show call1 --full
task:
  id: call1
  title: Authorize the charge
  state: queued
  blocked: no
  blocked_by: none
  held: yes
  hold_reason: "fm-hold-v1:RGVjaXNpb24gc291Z2h0OiBBdXRob3JpemUgdGhlICQyMCBjaGFyZ2UKUmVjb21tZW5kYXRpb246IEFwcHJvdmUgdGhlIGNoYXJnZSAoYXBwcm92ZSk="
  hold_kind: captain
  hold_until: "-"
  kind: captain
  repo: firstmate
  priority: "-"
  created: 2026-11-18
  closed: "-"
  deps: none
  links: none
  body: "Captain hold set: 2026-11-18T08:54:32Z\nCaptain hold boundary: spend\nCaptain hold if-no: \"Continue without the paid operation\"\nCaptain hold recommendation: \"approve\""
[exit=0]
