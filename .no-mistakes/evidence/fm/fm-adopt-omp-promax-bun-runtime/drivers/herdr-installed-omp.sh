#!/usr/bin/env bash
# Usage: herdr-installed-omp.sh <repo> - start the INSTALLED omp-promax launcher bare (env -i, scratch HOME, no session,
# no prompt) as the foreground of a real Herdr lab pane; judge it with the identity helper and the pane walk.
REPO=$1; LAB=$REPO/bin/fm-herdr-lab.sh; L=$HOME/.local/share/omp-promax-fix/omp-promax
NAME=$("$LAB" name instomp) || exit 1
"$LAB" prepare "$NAME" >/dev/null || { echo "prepare refused"; exit 1; }
S=$(mktemp -d /tmp/fm-instomp.XXXXXX); S=$(cd "$S" && pwd -P); mkdir -p "$S/home" "$S/wt"
trap '"$LAB" teardown "$NAME" >/dev/null 2>&1 && echo "# teardown ok: $NAME" || echo "# TEARDOWN FAILED: $NAME"; [ -n "${FG:-}" ] && { kill -0 "$FG" 2>/dev/null && echo "# omp $FG still alive after teardown" || echo "# omp $FG gone after teardown"; }; rm -rf "$S"' EXIT
"$LAB" provision "$NAME" >/dev/null || { echo "provision failed"; exit 1; }
"$LAB" run "$NAME" workspace create --cwd "$S/wt" --label instomp --no-focus >/dev/null 2>&1
PANE=$("$LAB" run "$NAME" pane list 2>/dev/null | jq -r '.. | objects | select(has("pane_id")) | .pane_id' | head -1)
echo "# herdr $(herdr --version | head -1); lab $NAME; pane $PANE; repo $(git -C "$REPO" rev-parse --short HEAD); $(date -u +%FT%TZ)"
. "$REPO/bin/fm-backend.sh"; . "$REPO/bin/backends/herdr.sh"
sleep 5
echo "case: empty shell: walk=$(fm_backend_herdr_pane_process_state_sample "$NAME" "$PANE")"
CMD="env -i PATH=\"\$PATH\" HOME=$S/home TERM=xterm-256color OMP_SKIP_SETUP=1 $L --no-session --no-extensions --no-skills --no-rules --no-title"
"$LAB" run "$NAME" pane run "$PANE" "$CMD" >/dev/null 2>&1
sleep 8
INFO=$("$LAB" run "$NAME" pane process-info --pane "$PANE" 2>/dev/null)
echo "case: installed omp-promax (bare, no prompt) in the pane foreground"
echo "  typed: $CMD"
echo "  herdr process-info foreground: $(printf '%s' "$INFO" | jq -c '[.result.process_info.foreground_processes[]?|{pid,name,argv}]')"
FG=$(printf '%s' "$INFO" | jq -r '.result.process_info.foreground_processes[0].pid')
echo "  kernel exe: $(python3 -I "$REPO/bin/fm-proc-info.py" exe "$FG")"
w=0; wo=$(python3 -I "$REPO/bin/fm-omp-identity.py" writer "$FG" 2>&1) || w=$?
i=0; io=$(python3 -I "$REPO/bin/fm-omp-identity.py" interactive "$FG" 2>&1) || i=$?
echo "  identity writer exit=$w : $wo"; echo "  identity interactive exit=$i : $io"
echo "  walk (fm_backend_herdr_pane_process_state_sample): $(fm_backend_herdr_pane_process_state_sample "$NAME" "$PANE")"
