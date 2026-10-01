### README.md-only branch on target 8e4050a: default bin/fm-lint.sh (changed mode), isolated cache
--- git status
 M README.md
--- bin/fm-lint.sh --list-files
(listed 0 roots)
--- bin/fm-lint.sh
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
fm-lint.sh: no changed lint targets
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
       42.03 real         8.86 user         0.57 sys
            15679488  maximum resident set size
             1818960  peak memory footprint
exit= wall=42s

### CI full set on target: CI=true bin/fm-lint.sh --list-files
roots listed: 449

### Lint owner changed (bin/fm-lint-cache.pl edited): local --list-files
roots listed: 449
--- rerun under bash for exit status: bin/fm-lint.sh (README.md-only change)
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
fm-lint.sh: full ShellCheck extended analysis enabled
fm-lint.sh: no changed lint targets
fm-lint-workflows.sh: actionlint 1.7.12 (pinned 1.7.12)
fm-lint-workflows.sh: 3 workflow files valid
exit=0 wall=28s
selection-only (--list-files) wall=21s
workflow-lint-only wall=1s
