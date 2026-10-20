#!/usr/bin/env bash
# Does the snapshot scan the status log for pull URLs when the record carries an explicit pr= ?
# A spy `grep` on PATH logs every invocation whose pattern mentions /pull/, then runs the real grep.
# usage: drive-explicit-spy.sh <lab-home> <code-root>
set -u
LAB=$1
CODE=$2
FB="$LAB/fakebin"
SPY="$LAB/spybin"
mkdir -p "$SPY"
REAL_GREP=$(command -v grep)
cat > "$SPY/grep" <<SH
#!/usr/bin/env bash
case "\$*" in *'/pull/'*) printf 'PULL-GREP %s\n' "\$*" >> "$LAB/grep-spy.log" ;; esac
exec "$REAL_GREP" "\$@"
SH
chmod +x "$SPY/grep"
U=https://github.com/example/repo/pull
for scen in explicit noexplicit; do
  rm -f "$LAB"/state/*.meta "$LAB"/state/*.status "$LAB"/state/*.json "$LAB/grep-spy.log"
  printf 'kind=ship\nremote_host=example.invalid\n' > "$LAB/state/t.meta"
  [ "$scen" = explicit ] && printf 'pr=%s/8\n' $U >> "$LAB/state/t.meta"
  printf 'done: %s/9\n' $U > "$LAB/state/t.status"
  out=$(PATH="$SPY:$FB:$PATH" FM_HOME="$LAB" "$CODE/bin/fm-fleet-snapshot.sh" --json | jq -c '.tasks[]|{id,url:.pr.url,source:.pr.source}')
  echo "$scen: $out  pull-url-grep-invocations=$( [ -f "$LAB/grep-spy.log" ] && wc -l < "$LAB/grep-spy.log" | tr -d ' ' || echo 0 )"
done
