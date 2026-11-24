# Test-step evidence, head 44832a646 (base 87836f79b)

Providers:
- installed real binary: ~/.local/bin/treehouse v3.1.7-fm.b8ea2fd.slot-return-r3 (schema 1). Unchanged: installed-before.txt / installed-after.txt.
- stand-in schema-2 build: locally patched from treehouse main b8ea2fd. See standin-provider.txt and standin-provider.patch. Not a shipped build. Deleted after the run.

Files:
- bootstrap-live.txt: real bin/fm-bootstrap.sh in a marked lab home (reduced: FM_BOOTSTRAP_DETECT_ONLY=1, FM_BOOTSTRAP_NETWORK=skip), installed binary then stand-in, with every treehouse argv.
- bootstrap-live-orca.txt: the same in an Orca lab home: no line, no treehouse call.
- spawn-installed/schema1-*/: bin/fm-spawn.sh refusal on the installed binary, argv log, pool state before/after (byte-identical).
- spawn-standin/real-provider-protected-*/: bin/fm-spawn.sh admission on the stand-in; the spawn's own get took free slot B; slot A entry and copy unchanged.
- spawn-standin-old-holder/: proven stand-in, old-holder entry: refusal with the cutover remedy, state byte-identical.
- teardown-{ordinary,recovered,recovered-id}/: bin/fm-teardown.sh task-x1 (no --force) on the stand-in: exact conditional return argv, slot A released, sibling B unchanged.
- teardown-unclaimed-cases.log: 15 unclaimed-route teardown cases, exit 0.
- spawn-guard-cases.log: first full spawn run; its one "not ok" is the old-holder cutover step the stand-in does not implement (see spawn-protected-only.sed.txt for the trimmed rerun).
