# Live lab evidence: fm/fm-restart-unreadable-launch-settings (head 9d432bade, base d432729a2)

Driver scripts: `lab-restart-attribution.sh` (main run) and `lab-relaunch.sh` (relaunch rows with a brief present).
Each run minted a marked lab home (`bin/fm-lab-home.sh env`), a named Herdr lab session (`bin/fm-herdr-lab.sh`),
and real `claude` v2.1.330 TUIs (scratch CLAUDE_CONFIG_DIR, throwaway API key, `--strict-mcp-config`, `--resume` of a seeded transcript).
Every production `herdr` call was forced through the lab helper. Base = `git archive d432729a2` export, run against the same panes.
Both runs tore the session, lab home and scratch tree down (see the tail of each transcript).

Rows: ua = TeamClaude wrapper layout (node .../teamclaude run -- --resume id, claude child), no pin;
ub = bare personal claude in the same pane/dir shape, no pin; uc = claude under `env -i` (no PATH/HOME: unreadable);
ud = claude pinned to another spawn_gen; mk = matching pin (managed); lg = legacy record (no launch_proof);
sh = shell-only pane; sm = unpinned restored secondmate.

## How to read lab-results.tsv

Some rows say FAIL or CHECK but are harness-label artifacts, not product failures:
- `GATE REFUSAL not attribution`: my pattern matched the gate *allow* notice
  `fm-gate-refuse: gate agent lifecycle permitted only against lab home ...`. The real output follows it.
- `recover-launch ... missing 'launch='`: wrong expected token. The output names the correct cause (see consumer-output-*.txt).
- `relaunch ... has no instructions`: fixture gap in the first run (no brief.md). Re-driven in `relaunch-results.tsv` (all pass).
- `state-unchanged` FAIL in the sweep and consumer stages: `state/guard-events.jsonl` is the gate allow log
  (guard-events-snapshot.jsonl). The `*.inbox/001.msg` files and screen change come from the `fm-send.sh` steer row:
  a plain fm-send steer has no attribution check on base or head (only restart-bound sends gained one), so it records and rings.
- `restart-no-records 4 records`: the count included those four fm-send inbox records of ua..ud. sm has no inbox, no pending reply
  (restart-sm-state-after.txt) and its restart state-unchanged check passed.
- mk/lg/sh controls labelled FAIL only by the gate-allow pattern: outputs show `interrupt-delivered` (mk, lg) and
  `already-stopped` (sh), identical on base and head.

## Omp live test

`FM_OMP_REBOOT_LIVE=1 tests/fm-omp-reboot-live-e2e.test.sh` fails on head and on base with
"inspection or refusal created lifecycle state". The diagnostic copy (omp-reboot-live-e2e-diag.txt) shows the new files are
omp's own extension markers (`.omp-turnend-extension-loaded`, `.omp-watch-extension-loaded`, `extensions/omp-primary-watch/lifecycle.log`),
written by the live omp process, not by a firstmate consumer. This is a pre-existing environment issue on this machine.

## Final run (primary evidence): lab-final.sh -> final-transcript.txt, final-results.tsv

One snapshot pair per verb; PID and start time compared per verb; a composer draft probe; restart rows sm (unpinned),
rx (R5-4 raw-command harness `mytool`, live unpinned agent), sk (managed secondmate positive control);
host `attribution` verb run directly against host records whose `fm-remote` session is mapped to the lab session;
`recover --one` 14 ticks on head and base; plain fm-send steer last, head and base.
Remaining FAIL rows in final-results.tsv:
- `ua fm-send-*:state-unchanged`: the plain steer writes its inbox record on base and head alike (not a lifecycle consumer).
- `sk restart`: the persistence request, pending-reply record and doorbell were delivered (restart-effects pass) and the agent
  started its turn. At the fallback nudge the re-check refused because a short-lived group member (the agent's own tool shell,
  pid 79158) could not have its environment read. This is the behaviour of declined review finding N1, observed live.
- `mk detector NOTE`: a delivered interrupt on an idle claude leaves the screen identical, so the screen is not a detector for
  interrupt; the draft probe (ua draft-kept) plus refusal text, exit code and same PID/start are the evidence for that verb.

## Omp

omp-reboot-live-e2e-filtered.txt: a copy of tests/fm-omp-reboot-live-e2e.test.sh run outside the worktree that only drops omp's own
three extension marker files from the state comparison (omp-filtered-copy.diff) passes the full matrix on head:
"ok - native omp: task and local secondmate remain unmanaged and unchanged for empty/pending interrupt, exit, relaunch, direct recovery and reboot sweep".

## Side effect to know

The lab panes inherited this shell's TeamClaude proxy variables (HTTPS_PROXY, NODE_EXTRA_CA_CERTS). Where input reached a lab
claude (plain fm-send doorbells, the base restart's nudge, the sk persistence request), that claude ran short real turns through
the proxy. The `env -i` row had no proxy and got "Invalid API key". All lab processes are gone.
