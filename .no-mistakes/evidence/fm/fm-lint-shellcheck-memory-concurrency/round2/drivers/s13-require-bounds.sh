#!/usr/bin/env bash
# The enforced-envelope switch on this macOS host, base vs head. Nothing runs if the host cannot enforce it.
S=/tmp/nm-live-01M6; F=$S/fx/clean.sh; [ -f "$F" ] || { mkdir -p "$S/fx"; printf '#!/usr/bin/env bash\nexit 0\n' > "$F"; }
for side in base head; do
  ( cd "$S/$side" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR HOME=/tmp/nm-r2/s13h XDG_CACHE_HOME=/tmp/nm-r2/s13h/.c FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_CACHE_DIR=off bin/fm-lint.sh --jobs 1 "$F" ) > "/tmp/nm-r2/s13.$side" 2>&1; echo "$side FM_LINT_REQUIRE_BOUNDS=1 exit=$?"
done
grep -v '^ledger:' /tmp/nm-r2/s13.head | cut -c1-200
diff <(grep -v '^ledger:' /tmp/nm-r2/s13.base) <(grep -v '^ledger:' /tmp/nm-r2/s13.head); echo "diff base vs head: exit=$?"
