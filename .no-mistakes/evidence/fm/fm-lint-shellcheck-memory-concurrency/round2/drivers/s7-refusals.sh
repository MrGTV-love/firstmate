#!/usr/bin/env bash
# Every way to leave the bound or use failed state: refused, never run unbounded.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-live-01M6; rm -rf "$S/fx" "$S/plain" "$S/unr" "$S/sb" "$S/elsewhere"; mkdir -p "$S/fx" "$S/plain" "$S/unr" "$S/sb"
root "$S/fx/clean.sh"
printf 'exit 0\n' > "$S/plain/shellcheck"; chmod +x "$S/plain/shellcheck"
cp "$(command -v shellcheck)" "$S/unr/shellcheck" 2>/dev/null; chmod 111 "$S/unr/shellcheck"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo "version: 0.11.0"; exit 0; }\n: > "%s/sb/RAN"\nexit 0\n' "$S" > "$S/sb/shellcheck"; chmod +x "$S/sb/shellcheck"
bash "$(dirname "$0")/../../live/refuse.sh" "$WT"
echo; echo '$ stand-in, pool whose slot.0 has mode 000'
P=$S/badslot; rm -rf "$P"; mkdir -p "$P"; : > "$P/slot.0"; chmod 000 "$P/slot.0"; rm -f "$S/sb/RAN"
out=$(cd "$WT" && env -u NO_MISTAKES_GATE PATH="$S/sb:$PATH" FM_LINT_SLOT_DIR="$P" FM_LINT_HOST_SLOTS=1 FM_LINT_CACHE_DIR=off bin/fm-lint.sh --jobs 1 "$S/fx/clean.sh" 2>&1); rc=$?
printf '%s\n' "$out" | grep -v '^fm-lint.sh: \(ShellCheck\|full ShellCheck\)\|^ledger:' | sed 's/\/Users\/charlesabrooker/~/g' | head -5; echo "exit=$rc"
echo "stand-in ran on the unusable slot: $([ -e "$S/sb/RAN" ] && echo yes || echo no)"; chmod 600 "$P/slot.0"
echo; echo '$ control: real ShellCheck, nothing set, clean root'
out=$(cd "$WT" && env -u NO_MISTAKES_GATE -u FM_LINT_SLOT_DIR FM_LINT_CACHE_DIR=off bin/fm-lint.sh --jobs 1 "$S/fx/clean.sh" 2>&1); echo "exit=$?"
rm -f "/var/tmp/firstmate-lint-$(id -u)/lint-slots/history/$(hkey "full:$S/fx/clean.sh")"
