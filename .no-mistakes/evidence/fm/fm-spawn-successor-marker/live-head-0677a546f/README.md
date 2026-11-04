# Live validation of fm-spawn --successor-of at head 0677a546f

Lab: a marked lab home from `bin/fm-lab-home.sh env`. A real tmux server on the lab socket (`tmux -L fm-lab`).
A real treehouse pool under a lab `TREEHOUSE_ROOT`. A lab clone of Vernant at 06a1855330d36d23d236f4ee2a62710b04ed4bae (the landed verb).
Its origin is a lab bare repo. `CODEX_HOOK_STATE_DIR` points to a lab directory.
The real `bin/fm-spawn.sh` ran inside the lab primary pane. The real Vernant `provision_existing_slot.py` wrote every marker.
The R-13 decision comes from Vernant's own `scripts/hooks/pre_push_base_ref_staleness` module. Its canonical origin list was set to the lab bare remote.
Stubbed: only the worker agent (`codex` is a script that logs and sleeps). The agent is outside this change.
The lab panes use a lab-only shell with no user profile, so the stub stays first on PATH.

Files:
- 00 and 08: fingerprints of the real Vernant hook state, the operator Vernant clone and the default tmux server, before and after. They are identical.
- 01: the predecessor spawn (a real task, no flag).
- 02: refusal rows. Each one exits nonzero with one error line. state/, data/, tmux windows, treehouse leases and markers do not change.
- 03: positive successor (marker written by Vernant, R-13 foreign=0 block=no). Control without the flag (no marker, R-13 blocks). A different successor carrying the same predecessor (R-13 blocks).
- 04: a real provisioner refusal keeps successor_of beside recovery=slot-provision-refused. A fresh respawn without the flag refuses, and the message names both routes. --relaunch while the window lives recovers and writes the marker. After the window is gone, --relaunch refuses, a fresh spawn with no flag or a different flag refuses, and a fresh spawn naming the same flag recovers.
- 05: the targeted successor test rows (stub provisioner). These are not live.
- 06: a later relaunch of an admitted successor. Vernant refuses it with manifest_exists. A plain admitted task without a declaration gets the same refusal, so this is existing Vernant behavior.
- 07: worker pane captures and the stub agent log.
- lab-drivers: the exact scripts that were run.

Named limits not driven live: the window for a branch switch between the re-check and the provisioner call. The case where the copy base lacks the verb.

Setup notes:
- The snapshot leaves out `guard-events.jsonl`, which the lab gate writes on every call. It also leaves out the `home-summary*` files, which a spawn refreshes in the background.
- The lab ran with `FM_SPAWN_NO_GUARD=1`, so the host memory guard was skipped.
- The lab primary's `.venv` was a symlink to the operator Vernant `.venv`. No file under it changed (checked with `find -newer`).
- A first lab attempt was discarded. Before the stub shell was in place, real `codex` started twice in lab panes. Both stopped at the folder-trust prompt and were quit with Escape. No agent work was done, and `~/.codex/config.toml` has no lab entry.
- The retry refusal for an off-branch predecessor was not driven again in this run. The earlier round's `../16-retry-pred-off-branch.txt` drove it at e2b25eab5. Since then the only bin/ change is the respawn-drop message text.
