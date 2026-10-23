#!/usr/bin/env bash
# Drives the real bin/fm-pr-merge.sh against the real GitHub API (real gh, the
# machine's existing read login) for an open PR, inside a disposable lab
# FM_HOME. A guard shim in front of gh refuses every write: `pr merge`, any
# `api` call with a non-GET method, and any gh-axi merge. An optional
# FM_INJECT_REVIEW rewrites only the live view's reviewDecision, because no
# open PR in reach is REVIEW_REQUIRED and making one would change repo rules.
# Usage: real-github-lab.sh <script-root> <pr-url> <label> [inject-review]
set -u
ROOT_UNDER_TEST=$1 PR_URL=$2 LABEL=$3 INJECT=${4:-}
REAL_GH=$(command -v gh) REAL_GH_AXI=$(command -v gh-axi || true)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT_UNDER_TEST/../01M5N9VADY0SSAVFNEHX6A7CNE/bin/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 \
  || /Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M5N9VADY0SSAVFNEHX6A7CNE/bin/fm-lab-home.sh create "$LAB" >/dev/null
SHIM=$LAB/shim; mkdir -p "$SHIM" "$LAB/wt"
LOG=$LAB/forge-calls.log; : > "$LOG"
cat > "$SHIM/gh" <<SH
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$LOG"
case "\${1:-} \${2:-}" in
  "pr merge") echo "GUARD: blocked gh pr merge" >> "$LOG"; echo "test guard: merge blocked" >&2; exit 1 ;;
esac
if [ "\${1:-}" = api ]; then
  case " \$* " in *" -X "*|*" --method "*|*" -f "*|*" --field "*|*" --raw-field "*)
    case " \$* " in *" graphql "*) ;; *) echo "GUARD: blocked api write" >> "$LOG"; exit 1 ;; esac ;;
  esac
  case " \$* " in *" graphql "*) case "\$*" in *mutation*) echo "GUARD: blocked graphql mutation" >> "$LOG"; exit 1 ;; esac ;; esac
fi
if [ "\${1:-} \${2:-}" = "pr view" ] && [ -n "$INJECT" ]; then
  case " \$* " in *mergeStateStatus*)
    out=\$("$REAL_GH" "\$@") || exit \$?
    printf 'REAL VIEW: %s\n' "\$out" >> "$LOG"
    printf '%s' "\$out" | jq -c --arg r "$INJECT" '.reviewDecision = \$r' | tee -a "$LOG"
    exit 0 ;;
  esac
fi
if [ "\${1:-} \${2:-}" = "pr view" ]; then
  out=\$("$REAL_GH" "\$@"); rc=\$?
  printf 'REAL VIEW: %s\n' "\$out" >> "$LOG"; printf '%s\n' "\$out"; exit \$rc
fi
exec "$REAL_GH" "\$@"
SH
cat > "$SHIM/gh-axi" <<SH
#!/usr/bin/env bash
printf 'gh-axi %s\n' "\$*" >> "$LOG"
case "\${1:-} \${2:-}" in "pr merge") echo "GUARD: blocked gh-axi pr merge" >> "$LOG"; exit 1 ;; esac
exec "$REAL_GH_AXI" "\$@"
SH
chmod +x "$SHIM/gh" "$SHIM/gh-axi"
git -C "$LAB/wt" init -q && git -C "$LAB/wt" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m lab
git -C "$LAB/wt" update-ref refs/remotes/origin/main "$(git -C "$LAB/wt" rev-parse HEAD)"
printf '%s\n' window=fm-task-x1 "worktree=$LAB/wt" "project=$LAB/projects/none" kind=ship mode=no-mistakes > "$LAB/state/task-x1.meta"
set +e
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 PATH="$SHIM:$PATH" \
  "$ROOT_UNDER_TEST/bin/fm-pr-merge.sh" task-x1 "$PR_URL" > "$LAB/stdout" 2> "$LAB/stderr"
rc=$?
echo "=================================================================="
echo "LIVE GITHUB SCENARIO: $LABEL"
echo "script: $ROOT_UNDER_TEST/bin/fm-pr-merge.sh"
echo "pr: $PR_URL   injected reviewDecision: ${INJECT:-(none, real value)}"
echo "exit code: $rc"
echo "--- stdout"; cat "$LAB/stdout"
echo "--- stderr (supervision banner removed)"; grep -v '^●' "$LAB/stderr"
echo "--- real gh live view(s) seen by the script:"; grep '^REAL VIEW' "$LOG" | sort -u
echo "--- merge attempts:"; grep -E 'pr merge|GUARD' "$LOG" || echo "(none: no merge was attempted)"
echo "--- lab task meta:"; cat "$LAB/state/task-x1.meta"
rm -rf "$LAB"
echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
