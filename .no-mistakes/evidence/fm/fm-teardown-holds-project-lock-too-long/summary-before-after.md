# Lock hold before / after (this host, 2026-10-15; base 8221de43 vs target de3e46e3)

Fixture: real bin/fm-teardown.sh + bin/fm-spawn.sh, one 8s slow non-pool phase injected in the teardown, a fresh spawn started during it.
Hold times are the project-lock `.holds` records the lock library writes (whole seconds).

| slow phase (8s) | base teardown lock hold | target teardown lock holds | base: spawn published after | target: spawn published after |
|---|---|---|---|---|
| process reap | 11s (1 hold) | 3 holds, sum 1s, longest 1s | 12.2s | 3.4s |
| clone sync (git fetch) | 13s (1 hold) | 3 holds, sum 0s | 11.3s | 3.7s |
| backlog completion | 11s (1 hold) | 3 holds, sum 0s | 11.6s | 3.1s |
| docker cleanup | 17s (1 hold) | 3 holds, sum 0s | 18.6s | 3.7s |

Real Treehouse (v2.3.1-fm.e58947de) + real tmux, slow reap phase 8s, competing allocator queued behind the lock:
base: teardown hold 17s, competitor waited 15.6s; target: teardown holds 3 (sum 1s), competitor waited 0.3s and got a different slot while the retiring slot stayed leased (holder=retire).
Lease-less Treehouse (lease command hidden): target keeps project custody (hold 17s) - the documented safe fallback.

Spawn side, slow remote fetch 8s, second allocator queued 1s after the spawn started:
base: spawn lock hold 11s, second allocator waited 7.8s; target: spawn lock hold 3s, second allocator waited 0.4s.
