# Live validation: teardown of a copy in a superseded Treehouse pool folder

Every scenario ran the real `bin/fm-teardown.sh` (target a6bceeddb; base e27bbad9b for the red runs)
against the real installed `treehouse v3.1.7-fm.8759019`, on real pool folders created by `treehouse get --lease`
in a throwaway `TREEHOUSE_ROOT` and `HOME`. The pool moved by repointing the project's origin, exactly as in the incident.
Stubs were limited to tmux, gh, gh-axi, no-mistakes, docker (forge/terminal surfaces).
`treehouse.log` lines in each transcript are every treehouse command teardown ran.

| Dir | What it shows |
|---|---|
| superseded-copy-base/ | RED at base: teardown runs `lease 2 --lease-holder task-x1`, leases the current pool's slot 2, refuses (the incident) |
| superseded-copy/ | Fixed: old-folder copy returned by path; current pool state sha256 unchanged; record removed |
| incident-recovery/ | Base teardown leaves the wrong lease, then fixed teardown releases it with `--if-lease-holder` and finishes; current pool state returns to its original bytes |
| misdirected-own/ | Pre-existing name lease held by task-x1 released via `return <path> --if-lease-holder task-x1`; other-task's slot 1 kept |
| misdirected-other/ | Same-named slot held by other-task: no lease/return on the current pool, state bytes unchanged |
| unlanded-commit/, dirty/ | Refused with no treehouse command and no state change; landed/clean retry finishes by path |
| current-pool-copy/ | Ordinary copy in the current pool still leased by name and returned, no status listing |
| superseded-copy-no-pool-dir/ | pool-dir hidden (older Treehouse): status-listing fallback places the slot as superseded, same safe result |
| shared-unmerged/ | Shared superseded slot, claimant PR OPEN: refused, no lease taken, old state bytes unchanged |
| shared-merged/ | Claimant PR MERGED: `lease --path <slot> --lease-holder parked` (real treehouse), record retires, parked copy kept |
