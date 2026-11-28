# Fixture: M0=6211f2c011caf0ad9c5f2434021935acbfbf1973 M1=e5284bd8d53dad01527ed868ad237520a5475c48 HEAD=a603bbd866bc53d85486c89d703ea607f4239c10
# merge-base origin/main HEAD = e5284bd8d53dad01527ed868ad237520a5475c48
# renewed manifest: {'base_sha': 'e5284bd8d53dad01527ed868ad237520a5475c48', 'branch': 'fm/rrt', 'owned_paths': ['src', 'lib', 'tools/x.sh'], 'owner_id': 'rrt', 'worktree_path': '~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/wt'}
# record before:
slot_base_sha=6211f2c011caf0ad9c5f2434021935acbfbf1973
slot_owned_path=src

### Relaunch before rerecord (admission must still refuse)
error: slot adoption refused: base_mismatch: manifest base is 'e5284bd8d53dad01527ed868ad237520a5475c48', the recorded base is '6211f2c011caf0ad9c5f2434021935acbfbf1973'; no manifest, scope, record or copy was changed
error: refused relaunch of governed task rrt: its recorded slot manifest cannot be adopted for ~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/wt; preserve and reconcile it first (a base_mismatch or scope_mismatch after the durable slot record was renewed is re-recorded with fm-control.sh rrt rerecord-slot --check, then without --check); the running agent was not stopped
[exit 1]

### Check mode reports and writes nothing
$ fm-control.sh rrt rerecord-slot --check
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
manifest_sha256=4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585
base=6211f2c011caf0ad9c5f2434021935acbfbf1973 -> e5284bd8d53dad01527ed868ad237520a5475c48
launch_proof=ok
journal_proof=absent
backlog_close_proof=ok
stopped_proof=ok
write_would=pass
command: bin/fm-control.sh rrt rerecord-slot --manifest-sha 4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585 --note '<the ruling this carries out>'
[exit 0]
--- record slot lines now:
slot_base_sha=6211f2c011caf0ad9c5f2434021935acbfbf1973
slot_owned_path=src
--- audit records: 0; archives: 0
--- record sha unchanged by --check: yes

### Write with no note is refused
$ fm-control.sh rrt rerecord-slot --manifest-sha 4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
error: slot rerecord refused: note_required: a write needs --note (or --note-file) naming the ruling it carries out; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=6211f2c011caf0ad9c5f2434021935acbfbf1973
slot_owned_path=src
--- audit records: 0; archives: 0

### Write with a wrong manifest sha is refused
$ fm-control.sh rrt rerecord-slot --manifest-sha 0000000000000000000000000000000000000000000000000000000000000000 --note Main ruling: test
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
error: slot rerecord refused: manifest_sha_mismatch: the manifest sha256 is 4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585, but --manifest-sha names 0000000000000000000000000000000000000000000000000000000000000000; review the manifest again and bind the digest fm-control.sh <id> rerecord-slot --check prints; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=6211f2c011caf0ad9c5f2434021935acbfbf1973
slot_owned_path=src
--- audit records: 0; archives: 0

### Write while the agent is alive is refused
$ fm-control.sh rrt rerecord-slot --manifest-sha 4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585 --note Main ruling: test
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
error: slot rerecord refused: agent_not_proven_stopped: the endpoint fmses:fm-rrt reads 'alive'; stop it with fm-control.sh <id> exit, then re-record; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=6211f2c011caf0ad9c5f2434021935acbfbf1973
slot_owned_path=src
--- audit records: 0; archives: 0

### Write with the correct sha and a note publishes
$ fm-control.sh rrt rerecord-slot --manifest-sha 4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585 --note Main ruling: re-record the renewed slot
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
rerecord-slot rrt: base 6211f2c011caf0ad9c5f2434021935acbfbf1973 -> e5284bd8d53dad01527ed868ad237520a5475c48; scope 3 entries (2 added, 0 released, 0 side-branch); prior record archived at ~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/home/data/rrt/slot-rerecord/prior-meta.20261128T041038Z.16c8f02c0f99.0
[exit 0]
--- record slot lines now:
slot_base_sha=e5284bd8d53dad01527ed868ad237520a5475c48
slot_owned_path=src
slot_owned_path=lib
slot_owned_path=tools/x.sh
--- audit records: 1; archives: 1
--- audit record 20261128T041038Z.16c8f02c0f99.0.record:
v1
result=published
archive=~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/home/data/rrt/slot-rerecord/prior-meta.20261128T041038Z.16c8f02c0f99.0
task=rrt
prior_sha256=16c8f02c0f996e4f79754ec08d062a7cc1b90f2ef299117d49145b85686e1b48
staged=~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/home/state/.rrt.meta.rerecord.rws902
staged_sha256=4d3f97381b339a96a703f5196569703d67605683386b6f5561b56dc098d07c87
prior_block_sha256=b0beb654db83bbfe0aac8c25cde88de7cc5de174867dcdc7848dcdf5e3f945bd
staged_block_sha256=4de108ab69a03315fd55de70ea76007daf1d09101af3f3ac8777f1fe9944329f
manifest=~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/manifests/manifest.json
manifest_sha256=4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585
old_base=6211f2c011caf0ad9c5f2434021935acbfbf1973
new_base=e5284bd8d53dad01527ed868ad237520a5475c48
head=a603bbd866bc53d85486c89d703ea607f4239c10
added_scope=lib rule=c
added_scope=tools/x.sh rule=b
rule_c_entry=lib added=1 tracked_newly_covered=1 untouched=1 uncommitted_newly_covered=0
added_uncommitted_newly_covered=0
scope_split=prior:1 changed:1 ancestor:1
note="Main ruling: re-record the renewed slot"
--- archive equals the prior record bytes: yes

### A second write is a no-op
$ fm-control.sh rrt rerecord-slot --manifest-sha 4f651b9bc7a4edcca79d94355ed01edd3510e291d813305cb118eb885da7e585 --note Main ruling: re-record the renewed slot
added_uncommitted_newly_covered=0
scope_split=prior:3 changed:0 ancestor:0
launch_proof=ok
journal_proof=absent
backlog_close_proof=ok
stopped_proof=ok
rerecord-slot rrt: already recorded
[exit 0]
--- record slot lines now:
slot_base_sha=e5284bd8d53dad01527ed868ad237520a5475c48
slot_owned_path=src
slot_owned_path=lib
slot_owned_path=tools/x.sh
--- audit records: 1; archives: 1

### Relaunch after rerecord (adoption must admit the record)
  a relaunch is not a new scope declaration: Vernant's push-time owned_paths gate stays the enforcement point, and a pool slot another task claims refuses the relaunch by name unless that task's record places its copy inside the slot
error: configured backend 'tmux' is not herdr; refusing to replace task rrt's proven-gone tmux endpoint
error: the replacement agent for rrt could not be launched on claude
error: rrt's agent was stopped but the replacement did not launch; no agent is running, and its work plus the recorded progress note are preserved at ~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/wt
[exit 1]
--- provisioner sentinel empty (adopted, not reprovisioned): yes

### Relaunch after rerecord on a dead pane (adoption admits, new agent launches)
  a relaunch is not a new scope declaration: Vernant's push-time owned_paths gate stays the enforcement point, and a pool slot another task claims refuses the relaunch by name unless that task's record places its copy inside the slot
warning: ~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/home/data/rrt/launch-brief.md records no ship branch; defaulting to legacy branch fm/rrt
warning: ~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/home/data/rrt/launch-brief.md records no delivery contract line (scaffolded before ship briefs recorded one); launching on the explicit --mode no-mistakes - confirm its definition of done matches
relaunch drift report for rrt: no out-of-scope path changed by this task's own work; the recorded scope is unchanged
  a relaunch is not a new scope declaration: Vernant's push-time owned_paths gate stays the enforcement point, and a pool slot another task claims refuses the relaunch by name unless that task's record places its copy inside the slot
relaunched rrt harness=claude from=claude model=default effort=default backend=tmux endpoint=fmses:fm-rrt worktree=~/tmp/fm-control-relaunch.aCJOxc/rr-live-6533/wt
[exit 0]
--- journal phase: complete; agent command now: claude; provisioner sentinel empty: yes
