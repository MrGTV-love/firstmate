# Test evidence: fm-pi-calm-layout-readonly-lines (head 26b929766, base d432729a2)
Pi installed into private scratch prefixes (`npm install -g --prefix <scratch>`), never system-global. tsc 7.0.2 (also npm latest typescript).

## Typecheck (tests/fm-pi-primary-types.test.sh)
| tree | Pi 1.6.0 | Pi 1.5.2 |
|---|---|---|
| base d432729a2 | exit 1, TS4104 at fm-calm-operational-user-layout.ts(108,55) | exit 0 |
| head 26b929766 | exit 0 | exit 0 |
Logs: typecheck-<tree>-pi<ver>.log

## Calm behaviour (tests/fm-calm-pi-extension.test.sh, real pi binary of that version on PATH)
| tree | Pi 1.6.0 (serial) | Pi 1.5.2 (serial) |
|---|---|---|
| base | exit 0 (all) | exit 1 at last ship-animation E2E ("water never animated") after all earlier tests ok |
| head | exit 0 (all) | exit 1 at last ship-animation E2E ("boat reset column") after all earlier tests ok |
The Pi 1.5.2 ship-animation failure occurs on base too: not caused by this change. calm-ext-*.log without `.serial` were 4 concurrent runs; they flaked on timing (base and head alike) and are not used as results.

## Focused (scratch copy driver tests/fm-calm-focus.sh = the same test file, running one test function)
- focus-head-pi1.6.0.log, focus-head-pi1.5.2.log: renderer contract + operational follow-up TUI E2E pass.
- focus-base-pi1.6.0-e2e.log + panes-base-pi1.6.0/: base TUI panes; identical to head panes except the random temp dir path.
- mutant-drop-spacer-pi1.6.0.log: dropping the leading spacer -> existing assertion fails.
- mutant-always-spacer-pi1.6.0.log: adding a spacer to the first row -> new assertion fails.
- tui-panes-base-vs-head.html: rendered pane captures side by side.
