# record before:
slot_base_sha=955c9d57bdd5ea52204ade38a55cd2ad3bc43b28
slot_owned_path=src
# renewed manifest base=955c9d57bdd5ea52204ade38a55cd2ad3bc43b28 owned_paths=['src', 'lib', 'tools/x.sh']

### Relaunch before rerecord (scope-only)
error: slot adoption refused: scope_mismatch: the manifest scope differs from the recorded task scope; no manifest, scope, record or copy was changed
error: refused relaunch of governed task rrt: its recorded slot manifest cannot be adopted for ~/tmp/fm-control-relaunch.chguBH/rr-scope-only-19340/wt; preserve and reconcile it first (a base_mismatch or scope_mismatch after the durable slot record was renewed is re-recorded with fm-control.sh rrt rerecord-slot --check, then without --check); the running agent was not stopped
[exit 1]

### Scope-only check
$ fm-control.sh rrt rerecord-slot --check
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
manifest_sha256=4be68a17c4d940dbf986784410872f944da359b686cb4fdcddab981711b2b986
base=955c9d57bdd5ea52204ade38a55cd2ad3bc43b28 -> 955c9d57bdd5ea52204ade38a55cd2ad3bc43b28
launch_proof=ok
journal_proof=absent
backlog_close_proof=ok
stopped_proof=ok
write_would=pass
command: bin/fm-control.sh rrt rerecord-slot --manifest-sha 4be68a17c4d940dbf986784410872f944da359b686cb4fdcddab981711b2b986 --note '<the ruling this carries out>'
[exit 0]
--- record slot lines now:
slot_base_sha=955c9d57bdd5ea52204ade38a55cd2ad3bc43b28
slot_owned_path=src
--- audit records: 0; archives: 0

### Scope-only write
$ fm-control.sh rrt rerecord-slot --manifest-sha 4be68a17c4d940dbf986784410872f944da359b686cb4fdcddab981711b2b986 --note Main ruling: re-record the grown scope
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
rerecord-slot rrt: base 955c9d57bdd5ea52204ade38a55cd2ad3bc43b28 -> 955c9d57bdd5ea52204ade38a55cd2ad3bc43b28; scope 3 entries (2 added, 0 released, 0 side-branch); prior record archived at ~/tmp/fm-control-relaunch.chguBH/rr-scope-only-19340/home/data/rrt/slot-rerecord/prior-meta.20261128T042920Z.0b125deca6e3.0
[exit 0]
--- record slot lines now:
slot_base_sha=955c9d57bdd5ea52204ade38a55cd2ad3bc43b28
slot_owned_path=src
slot_owned_path=lib
slot_owned_path=tools/x.sh
--- audit records: 1; archives: 1

### Relaunch after rerecord (scope-only)
relaunched rrt harness=claude from=claude model=default effort=default backend=tmux endpoint=fmses:fm-rrt worktree=~/tmp/fm-control-relaunch.chguBH/rr-scope-only-19340/wt
[exit 0]
--- journal phase: complete; provisioner sentinel empty: yes
