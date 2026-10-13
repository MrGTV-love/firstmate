# Live lab results: fm-teardown reassigned/shared copy (target 5ecd4a1a vs base 9e70f4ec)

Driver: lab-drive.sh <src> <scenario> <out>. Real bin/fm-teardown.sh, real git, real private tmux (fm-lab socket), real tasks-axi backlog, real claimant process; marked lab FM_HOME via bin/fm-lab-home.sh, removed after each run. Shims only for GitHub/Docker/no-mistakes/treehouse (logged).

| scenario | code | exit | result |
|---|---|---|---|
| reassigned-clean-unlanded | after-fix | 1 | REFUSED: task task-x1's recorded copy /Users/charlesabrooker/tmp/fm-lab.s0pwuz/pool/1/proj was reassigned to t |
| reassigned-finished | after-fix | 0 | teardown task-x1 complete (window firstmate:fm-task-x1; pool slot /Users/charlesabrooker/tmp/fm-lab.JSaTs0/poo |
| reassigned-unlanded | after-fix | 1 | REFUSED: task task-x1's recorded copy /Users/charlesabrooker/tmp/fm-lab.Kxfexa/pool/1/proj was reassigned to t |
| shared-finished | after-fix | 0 | teardown task-x1 complete (window firstmate:fm-task-x1; shared pool slot /Users/charlesabrooker/tmp/fm-lab.EUY |
| shared-unlanded | after-fix | 1 | REFUSED: task task-x1 shares pool slot /Users/charlesabrooker/tmp/fm-lab.uV7KiZ/pool/1/proj, but its recorded  |
| reassigned-clean-unlanded | base | 0 | teardown task-x1 complete (window firstmate:fm-task-x1; pool slot /Users/charlesabrooker/tmp/fm-lab.AsOEK1/poo |
| reassigned-finished | base | 1 | REFUSED: worktree /Users/charlesabrooker/tmp/fm-lab.XBmIFO/pool/1/proj has uncommitted changes. |
| reassigned-unlanded | base | 1 | REFUSED: worktree /Users/charlesabrooker/tmp/fm-lab.CcDzlj/pool/1/proj has uncommitted changes. |
