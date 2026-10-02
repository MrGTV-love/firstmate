#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-resolve.sh against a disposable lab FM_HOME.
# curl and quota-axi on PATH are tripwires: they only record that they ran.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
TRIP="$LAB/tripwire-bin"; mkdir -p "$TRIP"
for c in curl quota-axi; do
  printf '#!/usr/bin/env bash\necho "%s CALLED" >> "%s/tripwire.log"\nexit 99\n' "$c" "$LAB" > "$TRIP/$c"; chmod +x "$TRIP/$c"
done
cat > "$LAB/config/crew-dispatch.json" <<'JSON'
{ "rules": [ { "when": "A simple bug fix with a stated root cause.", "use": { "harness": "claude", "model": "sonnet" } } ],
  "default": [ { "harness": "claude", "model": "opus" } ] }
JSON
BRIEF="$LAB/private-brief.md"
printf '# Task\n## Captain'"'"'s intent\nFix the pager for the Acme-Ledger account 4417-2290.\n\n## Firstmate spec\n- Keep the change small.\n' > "$BRIEF"
KEY='live-lab-fake-key-0000-never-print'
NS="$LAB/config/dispatch-never-send"
drive() {
  local label=$1 out err code
  rm -f "$LAB/tripwire.log"
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        PATH="$TRIP:$PATH" FM_HOME="$LAB" TYPESAFE_API_KEY="$KEY" "$WT/bin/fm-dispatch-resolve.sh" "$BRIEF" --project pager 2>"$LAB/err")
  code=$?; err=$(cat "$LAB/err")
  echo "=== $label"
  echo "exit: $code"
  echo "stdout: [${out}]"
  echo "stderr (raw, every line):"; sed 's/^/  | /' "$LAB/err"
  echo "tripwire: $( [ -f "$LAB/tripwire.log" ] && cat "$LAB/tripwire.log" || echo 'curl and quota-axi never ran')"
  for s in "$KEY" Acme-Ledger acme-ledger 4417-2290; do
    case "$err$out" in *"$s"*) echo "LEAK: $s printed";; *) echo "no leak: $s";; esac
  done
  echo
}
printf '%s\n' '# private values' '' '  acme-ledger  ' > "$NS"; drive "case-insensitive literal match"
rm -f "$NS"; mkdir "$NS"; drive "directory at the list path"
rmdir "$NS"; ln -s "$LAB/missing-never-send" "$NS"; drive "broken symlink at the list path"
rm -f "$NS"
echo "lab removed on exit: $LAB"
