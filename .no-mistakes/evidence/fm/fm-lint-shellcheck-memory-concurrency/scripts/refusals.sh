#!/usr/bin/env bash
# refusals.sh <repo> <workdir>: drive bin/fm-lint.sh with bad settings and unusable slot dirs.
H2=$1; W=$2; mkdir -p "$W/bin"
cat > "$W/bin/shellcheck" <<SH
#!/bin/sh
if [ "\$1" = --version ]; then printf "version: 0.11.0\n"; exit 0; fi
echo "\$*" >> $W/analysis.log; exit 0
SH
chmod +x "$W/bin/shellcheck"; printf '#!/usr/bin/env bash\nexit 0\n' > "$W/a.sh"; : > "$W/plainfile"
run() { local label=$1; shift; : > "$W/analysis.log"; echo "### $label"; (cd "$H2" && env GITHUB_ACTIONS= CI= PATH="$W/bin:$PATH" "$@" bin/fm-lint.sh "$W/a.sh" 2>&1 | grep -v -E "^(calibration|fallback|ledger):"; echo "exit=${PIPESTATUS[0]}"); echo "analyses_started=$(wc -l < "$W/analysis.log" | tr -d ' ')"; echo; }
run "control: valid private slot dir" FM_LINT_SLOT_DIR="$W/slots"
run "FM_LINT_HOST_SLOTS=abc (invalid)" FM_LINT_SLOT_DIR="$W/slots" FM_LINT_HOST_SLOTS=abc
run "FM_LINT_HOST_SLOTS=0 (invalid)" FM_LINT_SLOT_DIR="$W/slots" FM_LINT_HOST_SLOTS=0
run "FM_LINT_ROOT_RSS_KIB=12x (invalid)" FM_LINT_SLOT_DIR="$W/slots" FM_LINT_ROOT_RSS_KIB=12x
run "FM_LINT_SLOT_DIR=off (pool cannot be disabled)" FM_LINT_SLOT_DIR=off
run "FM_LINT_SLOT_DIR is a plain file (unusable)" FM_LINT_SLOT_DIR="$W/plainfile"
mkdir -p "$W/ro"; chmod 500 "$W/ro"
run "FM_LINT_SLOT_DIR inside a read-only dir (unusable)" FM_LINT_SLOT_DIR="$W/ro/slots"
chmod 700 "$W/ro"
