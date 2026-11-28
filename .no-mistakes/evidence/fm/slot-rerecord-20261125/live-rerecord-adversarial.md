
### Adversarial: other-owner (check)
$ fm-control.sh rrt rerecord-slot --check
error: slot rerecord refused: owner_mismatch: manifest owner is 'someone-else', the task is 'rrt'; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=3feef0e0ac3f8a8ce7ed186d930ddf704f41adb9
slot_owned_path=src
--- audit records: 0; archives: 0

### Adversarial: other-owner (write)
$ fm-control.sh rrt rerecord-slot --manifest-sha ae1b2d3953f829657aef354c23d416f59265e408a553e70c0048719dc2de78e5 --note Main ruling: test
error: slot rerecord refused: owner_mismatch: manifest owner is 'someone-else', the task is 'rrt'; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=3feef0e0ac3f8a8ce7ed186d930ddf704f41adb9
slot_owned_path=src
--- audit records: 0; archives: 0
--- record bytes unchanged: yes

### Adversarial: base-not-merge-base (check)
$ fm-control.sh rrt rerecord-slot --check
error: slot rerecord refused: base_not_merge_base: the manifest base a9133f886da75f4142445eeb2746e8ee2c831480 is not merge-base(origin/main, HEAD) = 70227e351dd9f6cc7e8f4a8bf3a657a3cb885bf1; renew the durable record against the current merge-base (this verb never fetches: if origin/main is stale, fetch it in the primary clone first); no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=a9133f886da75f4142445eeb2746e8ee2c831480
slot_owned_path=src
--- audit records: 0; archives: 0

### Adversarial: base-not-merge-base (write)
$ fm-control.sh rrt rerecord-slot --manifest-sha afe01751e41abedaf599020a6e2a69192a8d3ae8b2b7f7515136e8780157be12 --note Main ruling: test
error: slot rerecord refused: base_not_merge_base: the manifest base a9133f886da75f4142445eeb2746e8ee2c831480 is not merge-base(origin/main, HEAD) = 70227e351dd9f6cc7e8f4a8bf3a657a3cb885bf1; renew the durable record against the current merge-base (this verb never fetches: if origin/main is stale, fetch it in the primary clone first); no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=a9133f886da75f4142445eeb2746e8ee2c831480
slot_owned_path=src
--- audit records: 0; archives: 0
--- record bytes unchanged: yes

### Adversarial: scope-entry-not-own-work (check)
$ fm-control.sh rrt rerecord-slot --check
error: slot rerecord refused: scope_entry_not_own_work: docs.txt is neither inside the recorded scope, nor a path the branch changed, nor the deepest tracked directory holding a file the branch added; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=392f5f79318dc830bddf50f46ea49e4adace0583
slot_owned_path=src
--- audit records: 0; archives: 0

### Adversarial: scope-entry-not-own-work (write)
$ fm-control.sh rrt rerecord-slot --manifest-sha 1579dd5b84735a7f8bba87d70d4616e40d81c955708924375e9496cac309a9cb --note Main ruling: test
error: slot rerecord refused: scope_entry_not_own_work: docs.txt is neither inside the recorded scope, nor a path the branch changed, nor the deepest tracked directory holding a file the branch added; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=392f5f79318dc830bddf50f46ea49e4adace0583
slot_owned_path=src
--- audit records: 0; archives: 0
--- record bytes unchanged: yes

### Adversarial: scope-uncovered-change (check)
$ fm-control.sh rrt rerecord-slot --check
error: slot rerecord refused: scope_uncovered_change: tools/x.sh; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=90b961a3fcff129e941b86d0fcc57dd173ec2559
slot_owned_path=src
--- audit records: 0; archives: 0

### Adversarial: scope-uncovered-change (write)
$ fm-control.sh rrt rerecord-slot --manifest-sha 091b7db68541b29ed935367d81620815f57e55154689d03c6282736e1c441c18 --note Main ruling: test
error: slot rerecord refused: scope_uncovered_change: tools/x.sh; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=90b961a3fcff129e941b86d0fcc57dd173ec2559
slot_owned_path=src
--- audit records: 0; archives: 0
--- record bytes unchanged: yes

### Adversarial: root-added-file-residual (check)
$ fm-control.sh rrt rerecord-slot --check
error: slot rerecord refused: scope_not_tracked: NEWS.md is not tracked at the manifest base 85f831323bcb1a22b0196285bbd4cdb93d659064; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=7a66d42ef5939ce857544a52a7ef631e3b6dcb92
slot_owned_path=src
--- audit records: 0; archives: 0

### Adversarial: root-added-file-residual (write)
$ fm-control.sh rrt rerecord-slot --manifest-sha 41a2162f0010beafd97a91e77e3ad8ed1f8b80feb743d1dd66b0381fe9128bfe --note Main ruling: test
error: slot rerecord refused: scope_not_tracked: NEWS.md is not tracked at the manifest base 85f831323bcb1a22b0196285bbd4cdb93d659064; no record, manifest, copy or journal was changed
[exit 1]
--- record slot lines now:
slot_base_sha=7a66d42ef5939ce857544a52a7ef631e3b6dcb92
slot_owned_path=src
--- audit records: 0; archives: 0
--- record bytes unchanged: yes
