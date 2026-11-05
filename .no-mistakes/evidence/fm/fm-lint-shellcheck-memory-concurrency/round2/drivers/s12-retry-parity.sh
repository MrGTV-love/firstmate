#!/usr/bin/env bash
# The real memory retry gives the same diagnostics and status on base and head. Heavy repo root, bound 2 GiB. Clean exports, base in a scratch HOME.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-live-01M6; O=/tmp/nm-r2/s12; rm -rf "$O"; mkdir -p "$O/home/.cache"
for side in base head; do
  ( cd "$S/$side" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR -u FM_LINT_REQUIRE_BOUNDS CI= GITHUB_ACTIONS= HOME="$O/home" XDG_CACHE_HOME="$O/home/.cache" FM_LINT_CACHE_DIR=off FM_LINT_JOBS=1 FM_LINT_ROOT_RSS_KIB=2097152 bin/fm-lint.sh --telemetry "$O/$side.tsv" bin/fm-watch.sh ) > "$O/$side.out" 2>&1
  echo "$side exit=$?"; grep -E 'memory ceiling' "$O/$side.out"
  awk -F '\t' '$1=="end"{print "'"$side"' roots log: status=" $9 " outcome=" $10}' "$O/$side.roots.tsv"
done
diff <(grep -v '^ledger:' "$O/base.out") <(grep -v '^ledger:' "$O/head.out"); echo "diff of the output, base vs head: exit=$?"
