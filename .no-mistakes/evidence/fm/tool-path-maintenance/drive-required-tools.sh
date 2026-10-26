#!/usr/bin/env bash
# Live driver: real bin/fm-bootstrap.sh, disposable lab FM_HOME, disposable HOME
# with spaces, real no-mistakes/treehouse binaries behind exec-logging launchers.
set -u
ROOT=$1
cd "$ROOT"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pathmiss.XXXXXX")
U="$SCR/operator home with spaces"; UB="$U/.local/bin"; LOG="$SCR/exec.log"
mkdir -p "$UB" "$SCR/launchers"
REAL_NM=/Users/charlesabrooker/.local/bin/no-mistakes
REAL_TH=/Users/charlesabrooker/.local/bin/treehouse
printf '#!/usr/bin/env bash\necho "no-mistakes $*" >> "%s"\nexec "%s" "$@"\n' "$LOG" "$REAL_NM" > "$UB/no-mistakes"
printf '#!/usr/bin/env bash\necho "treehouse $*" >> "%s"\nexec "%s" "$@"\n' "$LOG" "$REAL_TH" > "$SCR/launchers/treehouse"
chmod +x "$UB/no-mistakes" "$SCR/launchers/treehouse"
ln -s "$SCR/launchers/treehouse" "$UB/treehouse"
BASE=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u FM_CREW_STATE_META_OVERRIDE -u FM_CREW_STATE_STATUS_OVERRIDE \
  HOME="$U" PATH="$1" FM_HOME="$FM_HOME" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip bin/fm-bootstrap.sh; echo "[exit=$?]"; }
echo "FM_HOME=$FM_HOME"; echo "HOME=$U"; echo "PATH(base)=$BASE"; ls -la "$UB"
echo; echo "=== S1/S2: tools only in \$HOME/.local/bin (one is a symlinked launcher), PATH excludes it ==="
run "$BASE" | tee "$SCR/s1.out"
echo "--- exec log after S1 (must be absent):"; [ -e "$LOG" ] && cat "$LOG" || echo "(no exec log - candidates were not executed)"
echo "--- HOME contents after S1 (no shell config written):"; find "$U" -maxdepth 3 | sed "s#$SCR#<scr>#"
echo; echo "=== S3: operator adds \$HOME/.local/bin to PATH and reruns ==="
run "$UB:$BASE" | tee "$SCR/s3.out"
echo "--- exec log after S3 (normal version/lease checks ran through PATH):"; cat "$LOG" 2>/dev/null || echo "(none)"
echo; echo "=== S4: selected on-PATH no-mistakes is v1.45.0, newer copy also in \$HOME/.local/bin ==="
mkdir -p "$SCR/oldbin"; printf '#!/usr/bin/env bash\necho "no-mistakes version v1.45.0"\n' > "$SCR/oldbin/no-mistakes"; chmod +x "$SCR/oldbin/no-mistakes"
run "$SCR/oldbin:$BASE:$UB" | grep -E 'no-mistakes|PATH_MISSING|exit=' 
echo; echo "=== S5: unusable candidate shapes in \$HOME/.local/bin ==="
cp "$UB/no-mistakes" "$SCR/nm-body"
for shape in absent nonexecutable directory broken-symlink; do
  rm -rf "$UB/no-mistakes"
  case $shape in
    absent) ;;
    nonexecutable) cp "$SCR/nm-body" "$UB/no-mistakes"; chmod -x "$UB/no-mistakes" ;;
    directory) mkdir "$UB/no-mistakes" ;;
    broken-symlink) ln -s "$SCR/does-not-exist" "$UB/no-mistakes" ;;
  esac
  echo "--- shape=$shape: $(ls -ld "$UB/no-mistakes" 2>&1 | sed "s#$SCR#<scr>#")"
  run "$BASE" | grep -E 'no-mistakes|exit='
done
echo; echo "=== teardown ==="
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME" && rm -rf "$SCR" && echo "lab + scratch removed"
