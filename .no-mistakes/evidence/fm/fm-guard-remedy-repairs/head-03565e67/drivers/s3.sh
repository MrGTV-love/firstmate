#!/usr/bin/env bash
set -u
cd "$1"; EV=$2; WT=$PWD; BASECOMMIT=cf0e8a49a20ffb68de01d6ee8251c1516a4ee53c
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_PROJECTS_OVERRIDE
S=$(mktemp -d /tmp/nm-s3.XXXXXX); S=$(cd "$S"; pwd -P); trap 'rm -rf "$S"' EXIT
git archive HEAD | tar -x -C "$S"
git -C "$S" init -q; git -C "$S" -c user.email=t@e.invalid -c user.name=t add -A >/dev/null; git -C "$S" -c user.email=t@e.invalid -c user.name=t commit -qm base
L="bash $S/bin/fm-guard-lint.sh --root $S --mode new-or-touched --base HEAD"
reset() { git -C "$S" checkout -q -- . ; git -C "$S" clean -fdq; }
san() { sed -e "s#$S#\$SCRATCH#g" -e "s#$WT#\$WT#g"; }
lint() { out=$($L 2>&1); rc=$?; printf '%s\n' "$out" | grep -E '^(VIOLATION|STALE)' | grep -E "${1:-.}" | san | cut -c1-${2:-280}; printf 'lint exit=%s\n' "$rc"; }
{
echo "## 0. the shipped repo at this head"
echo "\$ bin/fm-guard-lint.sh --mode enforce --counts"; bin/fm-guard-lint.sh --mode enforce --counts 2>&1 | san | cut -c1-200; echo "exit=${PIPESTATUS[0]}"
echo "\$ bin/fm-guard-lint.sh --mode new-or-touched --base <run base>"; bin/fm-guard-lint.sh --mode new-or-touched --base "$BASECOMMIT" 2>&1 | san | cut -c1-200; echo "exit=${PIPESTATUS[0]}"

echo; echo "## 1. flag: strip the printed remedy from a shipped refusal; registry remedy still present"
python3 - "$S/bin/fm-merge-local.sh" <<'P'
import re,sys
p=sys.argv[1];s=open(p).read();n=re.sub(r"(refusing to merge into it)\. Remedy:[^\"]*\"",r'\1"',s);assert n!=s;open(p,'w').write(n)
P
lint 'S3|S1'
reset
echo; echo "## 2. flag: edit only an unchanged legacy refusal line (allowlisted for S1): touching it requires the printed remedy"
python3 - "$S/bin/fm-teardown.sh" <<'P'
import sys
p=sys.argv[1];s=open(p).read();t='REFUSED: cannot resolve the shared Treehouse project lock for ${PROJ:-<missing>}; nothing was changed';assert t in s;open(p,'w').write(s.replace(t,t+' at all'))
P
lint 'fm-teardown.sh'
reset
echo; echo "## 3. accept: a new shipped-style refusal with a real command remedy, mapped to a guard"
printf '#!/usr/bin/env bash\necho "REFUSED: blocked. Remedy: run bin/fm-teardown.sh x, then retry" >&2\n' > "$S/bin/fm-labguard.sh"
jq '.guards[0].sites=((.guards[0].sites//[])+[{"file":"bin/fm-labguard.sh","match":"REFUSED: blocked"}])' "$S/docs/guards/registry.json" > "$S/r.tmp" && mv "$S/r.tmp" "$S/docs/guards/registry.json"
lint .
echo; echo "## 4. remedy text classification on that mapped site"
for body in \
  'REFUSED: blocked' \
  'REFUSED: blocked. Remedy: ask someone' \
  'REFUSED: blocked. Remedy: ask someone about git history' \
  'REFUSED: blocked. Remedy: the herdr team will help' \
  'REFUSED: blocked. Remedy: run bin/missing.sh' \
  'REFUSED: blocked. Remedy: run ./bin/missing.sh, then herdr --session lab status' \
  'REFUSED: blocked. Remedy: run /usr/bin/env bash bin/missing.sh' \
  'REFUSED: blocked. Remedy: run /usr/bin/env bash bin/fm-teardown.sh x' \
  'REFUSED: blocked. Remedy: run ./bin/fm-teardown.sh x' \
  'REFUSED: blocked. Remedy: run /usr/./bin/env bash bin/fm-teardown.sh x' \
  'REFUSED: blocked. Remedy: run herdr --session lab status --json'; do
  printf '#!/usr/bin/env bash\necho "%s" >&2\n' "$body" > "$S/bin/fm-labguard.sh"
  out=$($L 2>&1); rc=$?
  n=$(printf '%s\n' "$out" | grep -c '^VIOLATION S3 ')
  printf '  %-78s -> %s (exit %s)\n' "$body" "$([ "$n" -gt 0 ] && echo rejected-S3 || echo accepted)" "$rc"
done
echo; echo "## 4b. a remedy only in a neighbouring statement, a comment, or the registry"
printf '#!/usr/bin/env bash\necho "REFUSED: blocked" >&2; echo "Remedy: run bin/fm-teardown.sh x" >&2\n' > "$S/bin/fm-labguard.sh"; lint S3 200
printf '#!/usr/bin/env bash\n# Remedy: run bin/fm-teardown.sh x\necho "REFUSED: blocked" >&2\n' > "$S/bin/fm-labguard.sh"; lint S3 200
reset

echo; echo "## 5. printed refusal forms that must stay sites, and test-only forms that must not (real scanner on one new file)"
cat > "$S/bin/fm-labforms.sh" <<'F'
#!/usr/bin/env bash
msg=$(printf '%s' \
  "REFUSED: form1-closes-substitution")
( echo \
  "REFUSED: form2-closes-subshell" )
fail "$(printf '%s %s' \
  "$x" \
  "REFUSED: form3-closes-nested")"
lines=(
  "REFUSED: form4-a"
  "REFUSED: form4-b")
case "$x" in
  a)
    m=$(printf '%s' \
      "REFUSED: form5-in-case-arm-body")
    ;;
  b)
    list=(
      "REFUSED: form6-a"
      "REFUSED: form6-b")
    ;;
  c) echo "REFUSED: form7-same-line-body" >&2 ;;
  "REFUSED: notasite-pattern-1") : ;;
  *"connection refused"*) : ;;
  d) : ;;
  "REFUSED: notasite-pattern-2"|"REFUSED: notasite-pattern-3")
    echo "REFUSED: form8-arm-body" >&2
    ;;
esac
"REFUSED: form9-outside-any-case")
printf '%s\n' "$err" | sed 's/^/REFUSED: /' >&2
printf 'refuse\n'
sed -n '/^REFUSED: /p' "$f"
F
python3 "$S/bin/fm-guard-sites.py" --root "$S" 2>/dev/null | jq -r '.sites[]|select(.file=="bin/fm-labforms.sh")|"site line \(.line) [\(.sig)] \(.text // "")"' | cut -c1-110
echo "--- shipped case patterns, sed address, token and option help that must be no site:"
python3 "$S/bin/fm-guard-sites.py" --root "$S" 2>/dev/null | jq -r '.sites[]|select((.file=="bin/fm-merge-prune.sh" and (.line>=329 and .line<=331)) or (.file=="bin/backends/herdr.sh" and .line==1277) or (.file=="bin/fm_open_loops.py" and .text!=null and (.text|test("add_argument"))))|"UNEXPECTED SITE \(.file):\(.line)"' ; echo "(end of list)"
reset

echo; echo "## 6. allowlist must not grow"
printf 'echo "REFUSED: new debt" >&2\n' > "$S/bin/fm-labdebt.sh"
id=$(python3 "$S/bin/fm-guard-sites.py" --root "$S" 2>/dev/null | jq -r '.sites[]|select(.file=="bin/fm-labdebt.sh")|.key')
jq --arg id "$id" '.allowed+=[{"id":$id,"rule":"S1"}]' "$S/docs/guards/lint-allowlist.json" > "$S/a.tmp" && mv "$S/a.tmp" "$S/docs/guards/lint-allowlist.json"
lint 'S5|fm-labdebt' 200
reset

echo; echo "## 7. audited-30 accounting by the real consumer, without population pins"
C="bash $S/bin/fm-guard-lint.sh --root $S --mode enforce --counts"
$C 2>&1 | grep -E '^INFO inventory' | cut -c1-170
echo "--- add one guard beyond the audit, correctly recorded: audited stays 30"
jq '.guards += [(.guards[0] | .id="lab-extra" | .invariant="a lab-only invariant beyond the audit" | del(.sites))] | .beyond_audit_active += ["lab-extra"]' "$S/docs/guards/registry.json" > "$S/r.tmp" && mv "$S/r.tmp" "$S/docs/guards/registry.json"
$C 2>&1 | grep -E '^INFO inventory|^VIOLATION R1' | cut -c1-170; echo "exit=$($C >/dev/null 2>&1; echo $?)"
reset
echo "--- adversarial: same guard, not recorded beyond the audit: refused"
jq '.guards += [(.guards[0] | .id="lab-extra" | .invariant="a lab-only invariant beyond the audit" | del(.sites))]' "$S/docs/guards/registry.json" > "$S/r.tmp" && mv "$S/r.tmp" "$S/docs/guards/registry.json"
$C 2>&1 | grep -E '^VIOLATION R1' | cut -c1-200; echo "exit=$($C >/dev/null 2>&1; echo $?)"
reset
} > "$EV/remedy-lint-S3.txt" 2>&1
