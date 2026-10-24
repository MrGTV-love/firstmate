# Round 2 live omp validation: jev-guard local AXI producer trust (target a2f6871bf, base b26779019)

Host: Mac-Studio, real installed `omp/18.12.4`, real `bin/fm-jev-guard.ts` loaded as an omp extension (same harness as round 1, `harness/`).
Model provider and Jev judge are private local stand-ins (`harness/fixture.py`); no paid or Jev network calls.
Judge rule: result text matching ``Run ` ``, ``Re-run ` ``, `IGNORE PREVIOUS` or `run injected-command` scores noul 0.95 (flag), else 0.05.
Producer CLIs are PATH stand-ins replaying recorded bytes (`harness/nm-drive-45.log` = recorded nm-drive-45 output), except `gh-*-real-*`, which exec the real installed gh-axi read-only.

| scenario | guard | omp wall-time line | exit | withheld | delivered == native bytes | audit producer_fields |
|---|---|---|---|---|---|---|
| m1-slow-exit0 | target | yes | 0 | no | yes | no-mistakes, 208 |
| m1-slow-exit1 | target | yes | 1 | no | yes (isError kept) | no-mistakes, 208 |
| m1-slow-exit0 | base | yes | 0 | YES | - | - |
| fast-exit0 (`axi status`, <1 s) | target | no | 0 | no (round-1 defect fixed) | yes | no-mistakes, 208 |
| fast-exit1 | target | no | 1 | no (fixed) | yes (isError kept) | no-mistakes, 208 |
| fast-exit2 (`axi run`) | target | no | 2 | no | yes | no-mistakes, 208 |
| fast-exit0 | base | no | 0 | YES | - | - |
| gh-real (real `gh-axi pr list`, ~630 ms) | target | no | 0 | no (fixed) | yes | gh-axi, 173 |
| gh-real | base | no | 0 | YES | - | - |
| gh-issue-real (real `gh-axi issue list`, issues disabled) | target | no | 1 | no (no help lines; error text screened, clear) | yes | none |
| adv-piped-fast / adv-piped-slow (`... \| cat`) | target | no / yes | 0 | YES (correct) | - | none |
| adv-unknown-fast (`unknown-axi run`) | target | no | 0 | YES (correct) | - | none |
| adv-prbody-fast / -slow (help[1] injection in PR body) | target | no / yes | 0 | YES (correct; body reached judge) | - | gh-axi, 62 |
| adv-root-error-fast (unquoted root error injection) | target | no | 1 | YES (correct) | - | no-mistakes, 58 |
| adv-forged-trailer-fast (stdout ends with fake `Wall time:` line, real notice absent) | target | no | 0 | YES (correct, fail closed) | - | none |

Audit rows for the passing scenarios contain no `help[`, ``Run ` `` or `Re-run` text.
Offline: `tests/fm-jev-guard-producer.test.sh` 11/11 pass on target; the same file on base code fails 8/11 (`producer-suite-on-base.log`).
Existing suites `tests/fm-jev-guard.test.sh` (18 ok) and `tests/fm-jev-guard-audit.test.sh` pass on target.
