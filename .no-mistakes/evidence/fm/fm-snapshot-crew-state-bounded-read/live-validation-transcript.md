# Live validation transcript - fm/fm-snapshot-crew-state-bounded-read (target e1377c3c vs base 6eb60860)

Fixture: disposable lab homes (bin/fm-lab-home.sh create), real bin/fm-fleet-snapshot.sh / fm-crew-state.sh / fm-open-loops.sh,
stand-in no-mistakes CLI that sleeps 4s per call (3 calls = 12-14s read, like the loaded-home reads in the intent), private tmux server.

## s1-base
```
label=s1-base rc=0 elapsed=10s
{"id":"loaded","current_state":{"state":"unknown","source":"none","detail":"current-state command failed (exit 124)","raw":"","observed_at":"2026-10-18T05:12:35Z","freshness":"fresh"}}
{"id":"quick","current_state":{"state":"done","source":"run-step","detail":"run passed: PR state unknown (no PR identity) · run: 01RUNquick","raw":"state: done · source: run-step · run passed: PR state unknown (no PR identity) · run: 01RUNquick","observed_at":"2026-10-18T05:12:35Z","freshness":"fresh"}}
nm calls per lane:
   3 loaded
   3 quick
```

## s1-target
```
label=s1-target rc=0 elapsed=14s
{"id":"loaded","current_state":{"state":"done","source":"run-step","detail":"run passed: PR state unknown (no PR identity) · run: 01RUNloaded","raw":"state: done · source: run-step · run passed: PR state unknown (no PR identity) · run: 01RUNloaded","observed_at":"2026-10-18T05:12:15Z","freshness":"fresh"}}
{"id":"quick","current_state":{"state":"done","source":"run-step","detail":"run passed: PR state unknown (no PR identity) · run: 01RUNquick","raw":"state: done · source: run-step · run passed: PR state unknown (no PR identity) · run: 01RUNquick","observed_at":"2026-10-18T05:12:15Z","freshness":"fresh"}}
nm calls per lane:
   3 loaded
   3 quick
```

## s6-override
```
label=s6-override rc=0 elapsed=5s
{"id":"loaded","current_state":{"state":"unknown","source":"none","detail":"current-state command failed (exit 124)","raw":"","observed_at":"2026-10-18T05:14:26Z","freshness":"fresh"}}
{"id":"quick","current_state":{"state":"done","source":"run-step","detail":"run passed: PR state unknown (no PR identity) · run: 01RUNquick","raw":"state: done · source: run-step · run passed: PR state unknown (no PR identity) · run: 01RUNquick","observed_at":"2026-10-18T05:14:26Z","freshness":"fresh"}}
nm calls per lane:
   2 loaded
   3 quick
```

## s2-target
```
label=s2-target rc=0 elapsed=41s
{"id":"hung","current_state":{"state":"unknown","source":"none","detail":"current-state command failed (exit 124)","raw":"","observed_at":"2026-10-18T05:12:56Z","freshness":"fresh"}}
{"id":"loaded","current_state":{"state":"done","source":"run-step","detail":"run passed: PR state unknown (no PR identity) · run: 01RUNloaded","raw":"state: done · source: run-step · run passed: PR state unknown (no PR identity) · run: 01RUNloaded","observed_at":"2026-10-18T05:12:56Z","freshness":"fresh"}}
{"id":"quick","current_state":{"state":"done","source":"run-step","detail":"run passed: PR state unknown (no PR identity) · run: 01RUNquick","raw":"state: done · source: run-step · run passed: PR state unknown (no PR identity) · run: 01RUNquick","observed_at":"2026-10-18T05:12:56Z","freshness":"fresh"}}
nm calls per lane:
   3 loaded
   3 quick
```

## fm-crew-state.sh direct, hung store (FM_CREW_STATE_NM_TIMEOUT=2), BASE vs TARGET

### s3-base-dead
```
label=s3-base-dead rc=0 elapsed=2s nm_calls=1
state: unknown · source: none · backend target gone: fm:fm-feat
```

### s3-target-dead
```
label=s3-target-dead rc=0 elapsed=3s nm_calls=1
state: unknown · source: none · backend target gone: fm:fm-feat · run-store: skipped (read budget exceeded)
```

### s4-base-live
```
label=s4-base-live rc=0 elapsed=2s nm_calls=1
state: unknown · source: pane · harness state unavailable (unknown missing)
```

### s4-target-live
```
label=s4-target-live rc=0 elapsed=2s nm_calls=1
state: unknown · source: pane · harness state unavailable (unknown missing) · run-store: skipped (read budget exceeded)
```

### s5-target-slow
```
label=s5-target-slow rc=0 elapsed=2s nm_calls=1
state: unknown · source: pane · harness state unavailable (unknown missing)
```

## fm-snapshot --help
```
36:Each local per-task current-state read is bounded by FM_SNAPSHOT_CREW_STATE_TIMEOUT
37-(default 40 seconds); a read that hits the bound reports state unknown. Local task
```

## fm-open-loops.sh --json (the 'ledger degraded' consumer), loaded lane 14s read
base:   complete=false  coverage rows: ["worker liveness loaded: worker liveness is inconclusive: unreadable; worker current state loaded: current-state command failed (exit 124)"]
target: complete=true  coverage rows: []

target with hung lane added (only the hung lane degrades): complete=false
["worker liveness hung: worker liveness is inconclusive: unreadable; worker current state hung: current-state command failed (exit 124); unlanded work hung: Command '['git', '-C', '/Users/charlesabrooker/tmp/fm-lab.Xk8X3I/wt-hung', 'symbolic-ref', '--quiet', 'refs/heads/main']' timed out after 60 seconds"]

## Existing tests
### tests/fm-nm-read-cache.test.sh (full file, target)
```
ok - the default whole-read bound cuts only the hung lane, after 41s
ok - case_finished_run_is_kept_until_the_id_changes: a finished run is cached until a newer run replaces it
ok - case_finished_run_needs_the_database: an unverifiable finished run is read again, never guessed
ok - case_live_run_is_read_fresh_every_time: a live run gets a fresh read on every call
ok - case_failure_is_read_fresh_every_time: a failed or timed-out call is read fresh on every call and never replayed
ok - case_unknown_inventory_is_read_fresh_every_time: an unknown inventory verdict is never kept
ok - the daemon probe is read fresh on every call
ok - a hit prints exactly the bytes of the fresh read, and a failure is never stored
ok - answers are classified by what they say, and only a settled finished run is kept
ok - cold, warm and uncached reads classify every run shape the same
ok - mutation caught: finished-always-valid fails case_finished_run_is_kept_until_the_id_changes
ok - mutation caught: finished-needs-no-database fails case_finished_run_needs_the_database
ok - mutation caught: live-run-kept fails case_live_run_is_read_fresh_every_time
ok - mutation caught: failure-kept fails case_failure_is_read_fresh_every_time
exit=0
```
### tests/fm-crew-state.test.sh, 4 changed cases only - TARGET
```
ok - no timeout command uses perl bound
ok - a cut run-store lookup keeps pane liveness: old working status does not revive a dead worker
ok - responsive lookups each keep their own allowance
ok - the capped inventory reader is bounded by the crew read budget
all fm-crew-state tests passed
exit=0
```
### same 4 cases against BASE bin/ (expected to fail: marker absent)
```
88:not ok - the cut lookup is disclosed, not hidden (missing: 'run-store: skipped (read budget exceeded)')
exit=1
```
