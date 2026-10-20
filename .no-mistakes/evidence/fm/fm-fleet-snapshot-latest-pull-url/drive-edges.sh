#!/usr/bin/env bash
# Edge-case logs through the REAL bin/fm-fleet-snapshot.sh --json, under the shell given as $3.
# usage: drive-edges.sh <lab-home> <code-root> <bash-binary>
set -u
LAB=$1
CODE=$2
SH=$3
FB="$LAB/fakebin"
U=https://github.com/example/repo/pull
chmod 600 "$LAB"/state/*.status 2>/dev/null
rm -f "$LAB"/state/*.meta "$LAB"/state/*.status "$LAB"/state/*.json
mk() { printf 'kind=ship\nremote_host=example.invalid\n' > "$LAB/state/$1.meta"; }
mk crlf;       printf 'working: %s/60\r\ndone: %s/61 ok\r\n' $U $U > "$LAB/state/crlf.status"
mk tabbed;     printf 'working:\t%s/80\t(replacement for %s/79)\n' $U $U > "$LAB/state/tabbed.status"
mk quoted;     printf 'note: "%s/90" and (%s/91)\n' $U $U > "$LAB/state/quoted.status"
mk huge-line;  { printf 'working: '; head -c 100000 /dev/zero | tr '\0' 'x'; printf ' %s/100\n' $U; } > "$LAB/state/huge-line.status"
mk empty-file; : > "$LAB/state/empty-file.status"
mk blank-tail; printf 'done: %s/110\n\n\n' $U > "$LAB/state/blank-tail.status"
PATH="$FB:$PATH" FM_HOME="$LAB" LC_ALL=en_US.UTF-8 "$SH" "$CODE/bin/fm-fleet-snapshot.sh" --json 2>&1 | jq -c '.tasks[]|{id,url:.pr.url,source:.pr.source}'
chmod 600 "$LAB"/state/unreadable.status
