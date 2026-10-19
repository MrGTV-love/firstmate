#!/usr/bin/env bash
# Edge cases for the restart-time bundle-note retirement (real wrapper + real tasks-axi).
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5A4VN5CHDW0VF1ZACABHHZK
LAB=$(cat /tmp/fm-lab-path.txt)
cd "$WT" || exit 1
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$WT/bin/fm-tasks-axi.sh" "$@"; }
body() { fm show "$1" --full | sed -n 's/^  body: //p'; }
mk() {  # <id> <body-text>
  fm add "$1" "Edge $1" --kind ship --repo firstmate >/dev/null
  printf '%s' "$2" > "$LAB/body-$1.txt"
  tasks-axi update "$1" --body-file "$LAB/body-$1.txt" --file "$LAB/data/backlog.md" >/dev/null
  echo "before start [$1]: $(body "$1")"
  fm start "$1" >/dev/null
  echo "after  start [$1]: $(body "$1")"
}
echo "=== E1 indented + trailing spaces"
mk e1 "  preserved in bundle /x/y.bundle, not landed   "
echo "=== E2 mid-line mention is untouched"
mk e2 "see preserved in bundle /x/y.bundle, not landed for details"
echo "=== E3 relative path is untouched (snapshot rule requires a leading slash)"
mk e3 "preserved in bundle rel/y.bundle, not landed"
echo "=== E4 comma-containing path"
mk e4 "preserved in bundle /x/a, not landed.bundle, not landed"
echo "=== E5 note with another line around it"
mk e5 "First line
preserved in bundle /x/y.bundle, not landed
Last line"
echo "=== E6 reopen path (done row -> reopen) retires too"
fm add e6 "Edge e6" --kind ship --repo firstmate >/dev/null
fm start e6 >/dev/null
tasks-axi done e6 --note "preserved in bundle /x/y.bundle, not landed" --file "$LAB/data/backlog.md" >/dev/null
echo "before reopen [e6]: $(body e6)"
fm reopen e6 >/dev/null
echo "after  reopen [e6]: state=$(fm show e6 --full | sed -n 's/^  state: //p') $(body e6)"
