#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6N1HVAKM46GY6DT148EV8A5 || exit 1
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6N1HVAKM46GY6DT148EV8A5/m4
for p in "" "--partition 1of3" "--partition 2of3" "--partition 3of3"; do
  n=${p:-full}; n=${n// /_}; n=${n#--}
  (CI=true bin/fm-lint.sh --list-files $p 2>/dev/null) | sed "s|$PWD/||" > $E/head.$n.txt
  (cd /tmp/fmlt/base && CI=true bin/fm-lint.sh --list-files $p 2>/dev/null) | sed "s|/tmp/fmlt/base/||" > $E/base.$n.txt
  if cmp -s $E/head.$n.txt $E/base.$n.txt; then echo "$n: identical ($(wc -l < $E/head.$n.txt | tr -d " ") roots)"; else echo "$n: DIFFERENT"; diff $E/base.$n.txt $E/head.$n.txt | head; fi
done
