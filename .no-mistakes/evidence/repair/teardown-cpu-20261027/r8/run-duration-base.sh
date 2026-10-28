#!/bin/bash
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M60X7EHPFP3WC1T7VVP0W6VM/r8; S=$(cat $EV/trees.path)
T=$(mktemp -d "$HOME/tmp/nm-r8-duration-base.XXXXXX") || exit 1
(cd "$S/base" && TMPDIR=$T bash tests/fm-duration.test.sh) > "$EV/duration-base.out" 2>&1; rc=$?
sleep 5; echo "base(7c204105) fm-duration exit=$rc ok=$(grep -c '^ok' $EV/duration-base.out) leftover:" > "$EV/duration-base.receipt"; find "$T" -mindepth 1 >> "$EV/duration-base.receipt"; echo "root=$T" >> "$EV/duration-base.receipt"; cat "$EV/duration-base.receipt"
