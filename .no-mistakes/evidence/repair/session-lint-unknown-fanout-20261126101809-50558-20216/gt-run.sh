#!/usr/bin/env bash
P=$1 R=$P/gt; cd "$R" || exit 1
rm -rf "$P/gt-cache"; mkdir "$P/gt-cache"
printf '%s\n' '#!/usr/bin/env bash' $'gt_fn() {\n  echo ok\n}' > bin/gt-lib.sh
lint() { env -u FM_HOME CI= GITHUB_ACTIONS= FM_LINT_CACHE_DIR=$1 FM_LINT_SLOT_DIR=$P/slots FM_DURATION_FILE=$P/gt-dur.jsonl bin/fm-lint.sh --jobs 1 "$2" 2>&1; }
roots=(bin/gt-dq-static.sh bin/gt-dq-static-directive.sh bin/gt-dq-dynamic.sh bin/gt-uq-heredoc-dynamic.sh bin/gt-uq-heredoc-static.sh bin/gt-q-heredoc-static.sh bin/gt-sq-static.sh)
for r in "${roots[@]}"; do echo "--- $r:"; sed 1d "$r"; done
for r in "${roots[@]}"; do o=$(lint "$P/gt-cache" "$r"); c=$?; echo "warm-up $r rc=$c $(grep -o 'SC[0-9]*' <<<"$o" | sort -u | tr '\n' ' ')"; done
printf '%s\n' '#!/usr/bin/env bash' 'gt_fn() {' '  printf "%s\n" "$1"' '}' > bin/gt-lib.sh; echo "-- mutated bin/gt-lib.sh so gt_fn reads \$1 --"
for r in "${roots[@]}"; do
  o1=$(lint "$P/gt-cache" "$r"); c=$?; o2=$(lint off "$r"); u=$?
  hit=$(grep -q "cache hit $r" <<<"$o1" && echo HIT || echo cold)
  printf '%-34s cached: rc=%s %-4s %-14s | uncached: rc=%s %-14s | %s\n' "$r" $c $hit "$(grep -o 'SC[0-9]*' <<<"$o1" | sort -u | tr '\n' ' ')" $u "$(grep -o 'SC[0-9]*' <<<"$o2" | sort -u | tr '\n' ' ')" "$([ $c = $u ] && echo AGREE || echo DISAGREE)"
done
