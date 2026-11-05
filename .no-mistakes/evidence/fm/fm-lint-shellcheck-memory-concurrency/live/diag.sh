#!/usr/bin/env bash
# Live driver: the same fixtures through real ShellCheck on base and head. Stdout,
# exit status and roots log (status columns) compared. One run per side, one at a
# time. Head uses the live pool; the marks it leaves are removed. Base gets a scratch HOME.
set -u
S=/tmp/nm-live-01M6; F=$S/diag; rm -rf "$F" "$S"/out.*; mkdir -p "$F"
cat > "$F/clean.sh" <<'X'
#!/usr/bin/env bash
echo clean
X
cat > "$F/error.sh" <<'X'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  echo a
X
cat > "$F/warning.sh" <<'X'
#!/usr/bin/env bash
unused=1
x=(a b); echo "$x"
X
cat > "$F/info.sh" <<'X'
#!/usr/bin/env bash
echo $1
X
cat > "$F/style.sh" <<'X'
#!/usr/bin/env bash
for f in $(ls); do echo "$f"; done
echo `pwd`
X
FILES=("$F/clean.sh" "$F/error.sh" "$F/warning.sh" "$F/info.sh" "$F/style.sh")
for side in base head; do
  H=$S/out.$side.home; mkdir -p "$H/.cache"
  rc=0
  ( cd "$S/$side" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR HOME="$H" XDG_CACHE_HOME="$H/.cache" FM_LINT_CACHE_DIR=off bin/fm-lint.sh --jobs 1 --telemetry "$S/out.$side.tsv" "${FILES[@]}" ) > "$S/out.$side.full" 2>&1 || rc=$?
  echo "$rc" > "$S/out.$side.rc"
  # one file at a time for per-root status
  for f in "${FILES[@]}"; do
    r=0; ( cd "$S/$side" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR HOME="$H" XDG_CACHE_HOME="$H/.cache" FM_LINT_CACHE_DIR=off bin/fm-lint.sh --jobs 1 "$f" ) > "$S/out.$side.$(basename "$f").txt" 2>&1 || r=$?
    echo "$side $(basename "$f") exit=$r lines=$(wc -l < "$S/out.$side.$(basename "$f").txt" | tr -d ' ')"
  done
done
echo "--- all-files run: base exit=$(cat "$S/out.base.rc") head exit=$(cat "$S/out.head.rc")"
strip() { grep -v '^ledger:\|hit the memory\|elapsed\|took' "$1" | sed "s#$S/base#ROOT#g;s#$S/head#ROOT#g"; }
diff <(strip "$S/out.base.full") <(strip "$S/out.head.full") > "$S/diag.diff"; echo "diff of the all-files output, base vs head: exit=$? lines=$(wc -l < "$S/diag.diff" | tr -d ' ')"
for f in "${FILES[@]}"; do b=$(basename "$f"); diff <(strip "$S/out.base.$b.txt") <(strip "$S/out.head.$b.txt") >/dev/null; echo "diff $b: exit=$?"; done
echo "--- diagnostic codes found (head):"; grep -oE 'SC[0-9]{4}[^ ]* ?\(?(error|warning|info|style)?' "$S/out.head.full" | sort | uniq -c | head -20
grep -oE 'SC[0-9]{4}' "$S/out.head.full" | sort | uniq -c | tr '\n' ' '; echo
P=/var/tmp/firstmate-lint-$(id -u)/lint-slots/history
n=0; for f in "${FILES[@]}"; do m=$P/$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "full:$f"); [ -f "$m" ] && { rm -f "$m"; n=$((n+1)); }; done; echo "history marks removed from the live pool: $n of ${#FILES[@]}"
