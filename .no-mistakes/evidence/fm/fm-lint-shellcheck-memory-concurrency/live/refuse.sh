#!/usr/bin/env bash
S=/tmp/nm-live-01M6; cd "$1"
run(){ echo; echo "\$ $LABEL"; out=$(env "$@" bin/fm-lint.sh $S/fx/clean.sh 2>&1); rc=$?; printf '%s\n' "$out" | grep -v '^fm-lint.sh: \(ShellCheck\|full ShellCheck\)\|^ledger:' | sed 's/\/Users\/charlesabrooker/~/g'; echo "exit=$rc"; }
echo "# Refusals, real ShellCheck $(shellcheck --version | sed -n 2p) at $(git rev-parse --short HEAD)"
LABEL='FM_LINT_SLOT_DIR=off (real ShellCheck)' run FM_LINT_SLOT_DIR=off
LABEL='FM_LINT_SLOT_DIR=<other dir> (real ShellCheck)' run FM_LINT_SLOT_DIR=$S/elsewhere
echo "other directory created: $([ -e $S/elsewhere ] && echo yes || echo no)"
LABEL='FM_LINT_HOST_RSS_KIB=zero' run FM_LINT_HOST_RSS_KIB=zero
LABEL='FM_LINT_HOST_RSS_KIB=0' run FM_LINT_HOST_RSS_KIB=0
LABEL='FM_LINT_HOST_SLOTS=08' run FM_LINT_HOST_SLOTS=08
LABEL='ShellCheck file with no #!, other pool dir' run PATH=$S/plain:$PATH FM_LINT_SLOT_DIR=$S/elsewhere
LABEL='ShellCheck that od cannot read (mode 111), other pool dir' run PATH=$S/unr:$PATH FM_LINT_SLOT_DIR=$S/elsewhere
LABEL='stand-in with an unusable pool path' run PATH=$S/sb:$PATH FM_LINT_SLOT_DIR=$S/fx/clean.sh/blocked
echo "stand-in ran on the unusable pool: $([ -e $S/sb/RAN ] && echo yes || echo no)"
