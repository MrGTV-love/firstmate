# Live publish-gate transcript
head=78bb3bced base=1c4e2929f no-mistakes=v1.86.1-private.f6.push-owner-clear.20261028

## Fixture remotes
ab: origin=https://github.com/fixture-a/firstmate upstream=https://github.com/fixture-b/firstmate 
evidence: origin=https://github.com/MrGTV-love/firstmate upstream=https://github.com/kunchenguid/firstmate 
ab-regB: origin=https://github.com/fixture-a/firstmate upstream=https://github.com/fixture-b/firstmate 
ab-unreg: origin=https://github.com/fixture-a/firstmate upstream=https://github.com/fixture-b/firstmate 
no-origin: upstream=https://github.com/fixture-b/firstmate 
origin-only: origin=https://github.com/fixture-a/firstmate 
## Registry rows (installed no-mistakes schema, disposable NM_HOME)
proj/ab|https://github.com/fixture-a/firstmate
proj/evidence|https://github.com/MrGTV-love/firstmate
proj/ab-regB|https://github.com/fixture-b/firstmate
proj/origin-only|https://github.com/fixture-a/firstmate
proj/ab-ssh|git@github.com:fixture-a/firstmate.git

## S1 reported bug, exact evidence literals (fm-brief.sh, consent MrGTV-love)

### HEAD | brief evidence layout consent=github.com/mrgtv-love/firstmate
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l1
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l1/data/t2/brief.md (ship, mode=no-mistakes; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### BASE | brief evidence layout consent=github.com/mrgtv-love/firstmate
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l3
error: this home runs as firstmate user/operator and holds no publication authority for github.com/kunchenguid/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l3/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/kunchenguid/firstmate, write 'maintainer github.com/kunchenguid/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l3/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/kunchenguid/firstmate for this one task with the captain's explicit approval

## S2 G1: origin consent passes every entry point (origin A, upstream B)

### HEAD | fm-role.sh check consent A mode no-mistakes
exit=0
authorized: task consent for github.com/fixture-a/firstmate

### BASE | fm-role.sh check consent A mode no-mistakes
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l6/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### HEAD | fm-brief.sh consent A
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l7
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l7/data/t8/brief.md (ship, mode=no-mistakes; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### BASE | fm-brief.sh consent A
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l9
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l9/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-b/firstmate, write 'maintainer github.com/fixture-b/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l9/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-b/firstmate for this one task with the captain's explicit approval

### HEAD | fm-spawn.sh consent A (launch stubbed after gate)
exit=1
spawn log: /private/tmp/fm-pubtest.HIoWqZ/spawn-t12.log
warning: task t12: /private/tmp/fm-pubtest.HIoWqZ/labs/l11/data/t12/brief.md has no ## Definition Of Done (task) section, so nothing grades this task; spawning anyway
reached tmux launch step (stub, exit 1): 1 new-window call(s)

### BASE | fm-spawn.sh consent A (launch stubbed after gate)
exit=1
spawn log: /private/tmp/fm-pubtest.HIoWqZ/spawn-t14.log
warning: task t14: /private/tmp/fm-pubtest.HIoWqZ/labs/l13/data/t14/brief.md has no ## Definition Of Done (task) section, so nothing grades this task; spawning anyway
error: spawn refused for t14: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l13/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-b/firstmate, write 'maintainer github.com/fixture-b/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l13/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-b/firstmate for this one task with the captain's explicit approval
reached tmux launch step (stub, exit 1): 0 new-window call(s)

### HEAD | fm-promote.sh consent A
exit=0
promoted t16 to ship mode=no-mistakes yolo=off (teardown protection restored)
wrote ship instructions for mode=no-mistakes: /private/tmp/fm-pubtest.HIoWqZ/labs/l15/data/t16/ship-instructions.md
next: FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l15 bin/fm-send.sh fm-t16 "$(cat /private/tmp/fm-pubtest.HIoWqZ/labs/l15/data/t16/ship-instructions.md)"

### BASE | fm-promote.sh consent A
exit=1
error: promotion refused for t18: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l17/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-b/firstmate, write 'maintainer github.com/fixture-b/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l17/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-b/firstmate for this one task with the captain's explicit approval

## S3 G2: refusals the guard must keep (HEAD)

### HEAD | role consent B
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l19/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### HEAD | brief consent B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l20
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l20/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-a/firstmate, write 'maintainer github.com/fixture-a/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l20/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-a/firstmate for this one task with the captain's explicit approval

### HEAD | role no consent (user/operator)
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l22/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### HEAD | brief no consent (user/operator)
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l23
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l23/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-a/firstmate, write 'maintainer github.com/fixture-a/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l23/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-a/firstmate for this one task with the captain's explicit approval

### HEAD | spawn no consent (user/operator)
exit=1
spawn log: /private/tmp/fm-pubtest.HIoWqZ/spawn-t26.log
warning: task t26: /private/tmp/fm-pubtest.HIoWqZ/labs/l25/data/t26/brief.md has no ## Definition Of Done (task) section, so nothing grades this task; spawning anyway
error: spawn refused for t26: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l25/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-a/firstmate, write 'maintainer github.com/fixture-a/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l25/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-a/firstmate for this one task with the captain's explicit approval
reached tmux launch step (stub, exit 1): 0 new-window call(s)

### HEAD | role maintainer B
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l27/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### HEAD | brief maintainer B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l28
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l28/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-a/firstmate, write 'maintainer github.com/fixture-a/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l28/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-a/firstmate for this one task with the captain's explicit approval

### HEAD | role maintainer A
exit=0
authorized: maintainer scope github.com/fixture-a/firstmate

### HEAD | brief maintainer A
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l31
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l31/data/t32/brief.md (ship, mode=no-mistakes; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### HEAD | role no origin remote, consent B
exit=1
refused: this task targets firstmate's own repository but no publication target can be determined (no origin remote, which a no-mistakes pull request targets on /private/tmp/fm-pubtest.HIoWqZ/proj/no-origin)

### HEAD | brief no origin remote, consent B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l34
error: this task targets firstmate's own repository but no publication target can be determined (no origin remote, which a no-mistakes pull request targets on /private/tmp/fm-pubtest.HIoWqZ/proj/no-origin)

## S4 adversarial: registration names B while origin is A

### HEAD | role consent A, registered B
exit=1
refused: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again

### HEAD | brief consent A, registered B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l37
error: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again

### HEAD | spawn consent A, registered B
exit=1
spawn log: /private/tmp/fm-pubtest.HIoWqZ/spawn-t40.log
warning: task t40: /private/tmp/fm-pubtest.HIoWqZ/labs/l39/data/t40/brief.md has no ## Definition Of Done (task) section, so nothing grades this task; spawning anyway
error: spawn refused for t40: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again
reached tmux launch step (stub, exit 1): 0 new-window call(s)

### HEAD | promote consent A, registered B
exit=1
error: promotion refused for t42: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again

### HEAD | brief maintainer A, registered B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l43
error: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again

### HEAD | role consent A, linked worktree of a checkout registered B
exit=1
refused: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB-wt publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again

### HEAD | role consent A, symlinked path to checkout registered B
exit=1
refused: origin names github.com/fixture-a/firstmate but the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab-regB-link publishes to github.com/fixture-b/firstmate; when its run-start refresh from origin fails the pipeline keeps the registered destination, so a run could open its pull request against github.com/fixture-b/firstmate instead; the owner must reconcile the no-mistakes registration with origin, then dispatch again

### HEAD | role consent A, registered as ssh spelling of A
exit=0
authorized: task consent for github.com/fixture-a/firstmate

## S5 unregistered and unreadable registry

### HEAD | role consent A, unregistered project
exit=0
authorized: task consent for github.com/fixture-a/firstmate

### HEAD | role consent A, no registry database
exit=0
authorized: task consent for github.com/fixture-a/firstmate

### HEAD | role consent A, corrupt registry file
exit=1
refused: cannot read the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab (registry /private/tmp/fm-pubtest.HIoWqZ/nm-garbage/state.sqlite needs python3 and a readable state.sqlite), so the repository a no-mistakes run would publish to cannot be established; run 'no-mistakes doctor', or set NM_HOME to the registry in use, then dispatch again

### HEAD | brief consent A, corrupt registry file
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l51
error: cannot read the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab (registry /private/tmp/fm-pubtest.HIoWqZ/nm-garbage/state.sqlite needs python3 and a readable state.sqlite), so the repository a no-mistakes run would publish to cannot be established; run 'no-mistakes doctor', or set NM_HOME to the registry in use, then dispatch again

### HEAD | role consent A, registry without repos table
exit=1
refused: cannot read the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab (registry /private/tmp/fm-pubtest.HIoWqZ/nm-notable/state.sqlite needs python3 and a readable state.sqlite), so the repository a no-mistakes run would publish to cannot be established; run 'no-mistakes doctor', or set NM_HOME to the registry in use, then dispatch again

### HEAD | role consent A, registration with blank destination
exit=1
refused: cannot read the no-mistakes registration for /private/tmp/fm-pubtest.HIoWqZ/proj/ab (registry /private/tmp/fm-pubtest.HIoWqZ/nm-blank/state.sqlite needs python3 and a readable state.sqlite), so the repository a no-mistakes run would publish to cannot be established; run 'no-mistakes doctor', or set NM_HOME to the registry in use, then dispatch again

## S6 G3: gh delivery paths unchanged (HEAD vs BASE)

### HEAD | role direct-PR consent A (gh target is upstream B)
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l55/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### BASE | role direct-PR consent A (gh target is upstream B)
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l56/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### HEAD | brief direct-PR consent A
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l57
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l57/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-b/firstmate, write 'maintainer github.com/fixture-b/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l57/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-b/firstmate for this one task with the captain's explicit approval

### BASE | brief direct-PR consent A
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l59
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l59/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-b/firstmate, write 'maintainer github.com/fixture-b/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l59/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-b/firstmate for this one task with the captain's explicit approval

### HEAD | brief direct-PR consent B
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l61
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l61/data/t62/brief.md (ship, mode=direct-PR; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### BASE | brief direct-PR consent B
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l63
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l63/data/t64/brief.md (ship, mode=direct-PR; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### HEAD | spawn direct-PR consent B
exit=1
spawn log: /private/tmp/fm-pubtest.HIoWqZ/spawn-t66.log
warning: task t66: /private/tmp/fm-pubtest.HIoWqZ/labs/l65/data/t66/brief.md has no ## Definition Of Done (task) section, so nothing grades this task; spawning anyway
reached tmux launch step (stub, exit 1): 1 new-window call(s)

### BASE | spawn direct-PR consent B
exit=1
spawn log: /private/tmp/fm-pubtest.HIoWqZ/spawn-t68.log
warning: task t68: /private/tmp/fm-pubtest.HIoWqZ/labs/l67/data/t68/brief.md has no ## Definition Of Done (task) section, so nothing grades this task; spawning anyway
reached tmux launch step (stub, exit 1): 1 new-window call(s)

### HEAD | role no mode consent A
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l69/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### BASE | role no mode consent A
exit=1
refused: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-b/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l70/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>

### HEAD | role no mode consent B
exit=0
authorized: task consent for github.com/fixture-b/firstmate

### BASE | role no mode consent B
exit=0
authorized: task consent for github.com/fixture-b/firstmate

### HEAD | origin-only: brief no-mistakes consent A
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l73
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l73/data/t74/brief.md (ship, mode=no-mistakes; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### BASE | origin-only: brief no-mistakes consent A
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l75
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l75/data/t76/brief.md (ship, mode=no-mistakes; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### HEAD | origin-only: brief direct-PR consent A
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l77
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l77/data/t78/brief.md (ship, mode=direct-PR; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### BASE | origin-only: brief direct-PR consent A
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l79
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l79/data/t80/brief.md (ship, mode=direct-PR; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### HEAD | origin-only: brief no-mistakes consent B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l81
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l81/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-a/firstmate, write 'maintainer github.com/fixture-a/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l81/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-a/firstmate for this one task with the captain's explicit approval

### BASE | origin-only: brief no-mistakes consent B
exit=1
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l83
error: this home runs as firstmate user/operator and holds no publication authority for github.com/fixture-a/firstmate; only the captain grants either a maintainer scope for one <host>/<owner>/<repo>, written as 'maintainer <host>/<owner>/<repo>' in /private/tmp/fm-pubtest.HIoWqZ/labs/l83/config/firstmate-role, or one-task consent recorded at dispatch as --upstream-consent <host>/<owner>/<repo>
error: to let this home publish to github.com/fixture-a/firstmate, write 'maintainer github.com/fixture-a/firstmate' into /private/tmp/fm-pubtest.HIoWqZ/labs/l83/config/firstmate-role (docs/configuration.md "Firstmate role"), or pass --upstream-consent github.com/fixture-a/firstmate for this one task with the captain's explicit approval

### HEAD | origin-only: brief local-only no consent
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l85
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l85/data/t86/brief.md (ship, mode=local-only; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

### BASE | origin-only: brief local-only no consent
exit=0
FM_HOME=/private/tmp/fm-pubtest.HIoWqZ/labs/l87
scaffolded: /private/tmp/fm-pubtest.HIoWqZ/labs/l87/data/t88/brief.md (ship, mode=local-only; replace {TASK}, {FIRSTMATE_SPEC}, and the task Definition of Done placeholders {DOD_CAPABILITY}, {DOD_MANDATORY_ITEMS}, {DOD_SUPPORTING_ITEMS}, {DOD_HARD_GATES}, {DOD_HONESTY_RULE})

## S7 G4: fm-role.sh mode argument is checked, never a repository

### HEAD | role mode names a repository
exit=1
error: mode must be no-mistakes or direct-PR (got 'github.com/fixture-a/firstmate')

### HEAD | role mode without value
exit=1
error: mode requires a value

## S8 registry is read, never written
state.sqlite sha256 before=3a29987f52520aa01343421b0cd962fdf4464e752e7abca968d44cdacc09254b after=3a29987f52520aa01343421b0cd962fdf4464e752e7abca968d44cdacc09254b
unchanged: yes
