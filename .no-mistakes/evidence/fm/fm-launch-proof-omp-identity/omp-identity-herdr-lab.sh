#!/usr/bin/env bash
# Live probe: real processes in a named non-default Herdr lab pane.
# For each pane, resolve the foreground PID with the production
# fm_launch_proof_herdr_pid, then ask fm_launch_proof_pid_is_omp from the
# base commit and from the target commit. Prints one table row per pane.
# Usage: omp-identity-herdr-lab.sh <worktree-root> <base-commit>
set -u
ROOT=$1 BASE=$2
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr)
ORIG_PATH=$PATH
TMP=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-ident.XXXXXX")
mkdir -p "$TMP/fakebin" "$TMP/home/state" "$TMP/base" "$TMP/opt/omp/bin" "$TMP/.bun/bin" "$TMP/bin" "$TMP/wt"
git -C "$ROOT" archive "$BASE" bin | tar -x -C "$TMP/base"
# Real executables: one tiny compiled sleeper installed under each name under
# test (copied platform binaries are killed by macOS code signing).
printf '#include <unistd.h>\n#include <stdlib.h>\nint main(int c,char**v){sleep(c>1?atoi(v[1]):600);return 0;}\n' > "$TMP/sleeper.c"
cc -o "$TMP/sleeper" "$TMP/sleeper.c" || { echo 'cc failed'; exit 1; }
cp "$TMP/sleeper" "$TMP/opt/omp/bin/python3"
cp "$TMP/sleeper" "$TMP/.bun/bin/omp"
cp "$TMP/sleeper" "$TMP/bin/ompd"

SESSION=$("$HELPER" name omp-ident)
export SESSION HELPER REAL_HERDR ORIG_PATH
cleanup() {
  env PATH="$ORIG_PATH" "$HELPER" teardown "$SESSION" >/dev/null 2>&1 \
    && echo "teardown: $SESSION removed, default session tripwire matched" \
    || echo "teardown: FAILED for $SESSION"
  rm -rf "$TMP"
}
trap cleanup EXIT
"$HELPER" provision "$SESSION" >/dev/null || { echo 'provision failed'; exit 1; }

cat > "$TMP/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do case "$arg" in --session|--session=*) exit 9 ;; esac; done
exec env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"
SH
chmod +x "$TMP/fakebin/herdr"
lab() { env PATH="$ORIG_PATH" "$HELPER" run "$SESSION" "$@"; }

# label | exec command line (exec replaces the pane shell; argv[0] = path)
CASES=(
  "omp-dir-exec-path|exec $TMP/opt/omp/bin/python3 600"
  "omp-dir-argv0-only|exec -a $TMP/opt/omp/bin/python3 /bin/sleep 600"
  "bun-installed-omp-copy|exec $TMP/.bun/bin/omp 600"
  "ompd-near-miss|exec $TMP/bin/ompd 600"
  "real-omp-cli|exec omp"
)
probe() { # <bin-dir> <meta>
  FM_HOME="$TMP/home" FM_BACKEND=herdr HERDR_SESSION="$SESSION" PATH="$TMP/fakebin:$ORIG_PATH" \
    bash -c '. "$1/fm-backend.sh"; . "$1/fm-control-lib.sh"; . "$1/fm-launch-proof-lib.sh"; fm_backend_source herdr
      pid=$(fm_launch_proof_herdr_pid "$2") || { echo "nopid -"; exit 0; }
      if fm_launch_proof_pid_is_omp "$pid"; then echo "$pid accept"; else echo "$pid refuse"; fi' _ "$1" "$2"
}
printf '%-24s %-8s %-48s %-8s %-8s\n' case pid "ps comm / argv0" base target
for entry in "${CASES[@]}"; do
  label=${entry%%|*} cmd=${entry#*|}
  ws=$(lab workspace create --cwd "$TMP/wt" --label "$label" --no-focus) || { echo "$label: workspace create failed"; continue; }
  pane=$(printf '%s' "$ws" | jq -r '.result.root_pane.pane_id')
  sleep 4  # let the login shell finish its startup children
  lab pane run "$pane" "$cmd" >/dev/null || { echo "$label: pane run failed"; continue; }
  meta="$TMP/home/state/$label.meta"
  printf 'window=%s:%s\n' "$SESSION" "$pane" > "$meta"
  base_r='' target_r=''
  for _ in $(seq 1 60); do
    target_r=$(probe "$ROOT/bin" "$meta")
    case "$target_r" in nopid*) sleep 0.25 ;; *)
      p=${target_r% *}
      c=$(ps -p "$p" -o comm= 2>/dev/null); a=$(ps -p "$p" -o args= 2>/dev/null)
      case "$label" in real-omp-cli) [ "${c##*/}" = omp ] || { sleep 0.25; continue; } ;;
        *) case "$a" in *600*) ;; *) sleep 0.25; continue ;; esac ;; esac
      break ;;
    esac
  done
  base_r=$(probe "$TMP/base/bin" "$meta")
  pid=${target_r% *}
  printf '%-24s %-8s %-48s %-8s %-8s\n' "$label" "$pid" "$(ps -p "$pid" -o comm= 2>/dev/null | sed "s#$TMP#\$TMP#") / $(ps -p "$pid" -o args= 2>/dev/null | awk '{print $1}' | sed "s#$TMP#\$TMP#")" "${base_r#* }" "${target_r#* }"
done
