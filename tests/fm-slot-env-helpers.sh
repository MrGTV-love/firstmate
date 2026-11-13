#!/usr/bin/env bash
# tests/fm-slot-env-helpers.sh - scratch worlds for the copy-environment tests.
#
# Sourced by tests/fm-slot-provision-env.test.sh, tests/fm-spawn-slot-env.test.sh
# and tests/fm-copy-env-sites.test.sh. A world is a scratch directory holding a
# nested project clone (project/), a provisioned copy of it (copy/), recording
# stubs for pip, uv and python -m venv (stubs/), a working python3 (pybin/), and
# the files a run leaves (env-record.json, report.json, stub-calls.log).
# The copy ignores .venv (the pattern without a trailing slash, so a symlinked
# .venv is ignored too) because fm_slot_check_copy refuses a dirty tree. A
# venv is placed only in the world's own scratch copy, before the run.
# shellcheck disable=SC2034 # SLOT_ENV_* are read by the sourcing suites.
# shellcheck disable=SC2016 # Fixture scripts and child-shell programs are written in single quotes on purpose.

# The ambient interpreter variables the owner scrubs, polluted with markers.
SLOT_ENV_POLLUTION=(
  "PYTHONPATH=/polluted/pythonpath" "PYTHONHOME=/polluted/pythonhome"
  "PYTHONUSERBASE=/polluted/userbase" "PYTHONSTARTUP=/polluted/startup.py"
  "__PYVENV_LAUNCHER__=/polluted/launcher" "UV_PROJECT_ENVIRONMENT=/polluted/uv-env"
  "CONDA_PREFIX=/polluted/conda"
)

SLOT_ENV_BASE_PY=
# Finds a real, working interpreter once. Its own sys.executable is used, so a
# shim or a pyenv wrapper is never what a venv links to.
slot_env_setup_base_python() {
  SLOT_ENV_BASE_PY=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null) || SLOT_ENV_BASE_PY=
  [ -n "$SLOT_ENV_BASE_PY" ] && [ -x "$SLOT_ENV_BASE_PY" ] || fail 'no working base python3 for the fixture'
  "$SLOT_ENV_BASE_PY" -c 'import venv' 2>/dev/null || fail 'the base python3 cannot build a venv for the fixture'
  # A PYTHONHOME that is polluted yet valid: a bogus one would stop the base
  # interpreter before it could record anything, hiding the pollution it proves.
  SLOT_ENV_POLLUTION[1]="PYTHONHOME=$("$SLOT_ENV_BASE_PY" -c 'import sys; print(sys.base_prefix)')"
}

# The fixture provisioner records what it saw first, then imports the module only
# a copy's venv can import, then attests like the project's real provisioner.
slot_env_write_provisioner() { # <repo>
  mkdir -p "$1/scripts/git-stability"
  cat > "$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import argparse
import json
import os
import sys
from pathlib import Path

NAMES = ("VIRTUAL_ENV", "PYTHONPATH", "PYTHONHOME", "PYTHONUSERBASE", "PYTHONSTARTUP",
         "__PYVENV_LAUNCHER__", "UV_PROJECT_ENVIRONMENT", "CONDA_PREFIX", "FM_SENTINEL", "HOME",
         "TMPDIR", "CODEX_HOOK_STATE_DIR", "WORKTREE_LIFECYCLE_STORE_DIR", "GIT_AUTHOR_NAME")
record = {name: os.environ.get(name) for name in NAMES}
path = os.environ.get("PATH", "")
record.update(sys_executable=sys.executable, sys_prefix=sys.prefix, path=path,
              path_head=path.split(":")[0], cwd=os.getcwd(), sys_path0=sys.path[0],
              argv=sys.argv[1:])
Path(os.environ["FM_TEST_ENV_RECORD"]).write_text(json.dumps(record), encoding="utf-8")
if os.environ.get("FM_TEST_TOOL_NAME"):
    import shutil
    found = shutil.which(os.environ["FM_TEST_TOOL_NAME"])
    if found:
        Path(os.environ["FM_TEST_TOOL_LOG"]).write_text(found, encoding="utf-8")
import fm_fixture_env_mod  # noqa: E402,F401 only the copy's venv can import this
p = argparse.ArgumentParser()
for flag in ("repo-root", "worktree-path", "owner-id", "branch", "base-sha"):
    p.add_argument("--" + flag, required=True)
p.add_argument("--owned-path", action="append", required=True)
p.add_argument("--base-source")
a = p.parse_args()
rec = dict(worktree_path=os.path.realpath(a.worktree_path), owner_id=a.owner_id, branch=a.branch,
           base_sha=a.base_sha, owned_paths=a.owned_path, lifecycle_state="worktree_active")
manifest = Path(os.environ["FM_TEST_SLOT_RECORD"])
manifest.write_text(json.dumps(rec), encoding="utf-8")
print(json.dumps(dict(state="PASS", manifest_path=str(manifest), **rec)))
PY
}

# Recording stubs: any pip, uv or python -m venv call is logged, never run.
slot_env_write_stubs() { # <dir>
  local dir=$1 tool
  mkdir -p "$dir/stubs" "$dir/pybin"
  for tool in pip pip3 uv; do
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "$FM_STUB_LOG"\nexit 0\n' "$tool" > "$dir/stubs/$tool"
    chmod +x "$dir/stubs/$tool"
  done
  # python: a -m venv call is only recorded; anything else passes to the base python.
  printf '#!/bin/sh\nif [ "$1" = -m ] && [ "$2" = venv ]; then printf "%%s\\n" "python $*" >> "$FM_STUB_LOG"; exit 0; fi\nexec "%s" "$@"\n' "$SLOT_ENV_BASE_PY" > "$dir/stubs/python"
  chmod +x "$dir/stubs/python"
  ln -s "$SLOT_ENV_BASE_PY" "$dir/pybin/python3"
}

# slot_env_make_world <name> <copies|symlinks|none>: prints the world directory.
slot_env_make_world() {
  local name=$1 mode=$2 dir project origin copy exclude site
  dir="$TMP_ROOT/$name"
  project="$dir/project" origin="$dir/origin.git" copy="$dir/copy"
  mkdir -p "$dir/home" "$dir/tmp" "$dir/codex-hooks" "$dir/lifecycle"
  : > "$dir/stub-calls.log"
  slot_env_write_stubs "$dir"
  fm_git_init_commit "$project"
  slot_env_write_provisioner "$project"
  git -C "$project" add scripts
  git -C "$project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm 'fixture provisioner'
  fm_git_add_origin "$project" "$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" worktree add --quiet --detach "$copy" HEAD
  exclude="$(git -C "$project" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$exclude")"
  printf '.venv\n' >> "$exclude"
  case "$mode" in
    none) ;;
    copies|symlinks)
      if [ "$mode" = copies ]; then
        "$SLOT_ENV_BASE_PY" -m venv --without-pip --copies "$copy/.venv" || fail 'fixture venv build failed'
        rm -f "$copy/.venv/bin/python3" "$copy"/.venv/bin/python3.[0-9]*
      else
        "$SLOT_ENV_BASE_PY" -m venv --without-pip "$copy/.venv" || fail 'fixture venv build failed'
      fi
      site=$("$copy/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
      printf 'MARK = "copy-venv"\n' > "$site/fm_fixture_env_mod.py"
      ;;
  esac
  printf '%s\n' "$dir"
}

# A clone .venv and a decoy venv hold both python and python3, each logging a
# distinct marker, so a borrowed interpreter shows even when PATH finds python3.
slot_env_marker_interpreter() { # <path> <marker> <log>
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$1" >> "%s"\nexec "%s" "$@"\n' "$2" "$3" "$SLOT_ENV_BASE_PY" > "$1"
  chmod +x "$1"
}

slot_env_add_clone_venv() { # <dir>
  local dir=$1
  mkdir -p "$dir/project/.venv/bin"
  slot_env_marker_interpreter "$dir/project/.venv/bin/python" clone-python "$dir/borrowed.log"
  slot_env_marker_interpreter "$dir/project/.venv/bin/python3" clone-python3 "$dir/borrowed.log"
  printf '#!/bin/sh\nprintf "clone-tool\\n" >> "%s"\n' "$dir/tool.log" > "$dir/project/.venv/bin/fm-env-tool"
  chmod +x "$dir/project/.venv/bin/fm-env-tool"
  printf 'MARK = "clone-venv"\n' > "$dir/project/.venv/clone_marker.py"
}

# The decoy is a venv-shaped tree whose editable pointer leads to another tree.
slot_env_add_decoy_venv() { # <dir>
  local dir=$1
  mkdir -p "$dir/decoy/bin" "$dir/decoy/lib/site-packages" "$dir/elsewhere"
  : > "$dir/borrowed.log"
  slot_env_marker_interpreter "$dir/decoy/bin/python" decoy-python "$dir/borrowed.log"
  slot_env_marker_interpreter "$dir/decoy/bin/python3" decoy-python3 "$dir/borrowed.log"
  printf '#!/bin/sh\nprintf "decoy-tool\\n" >> "%s"\n' "$dir/tool.log" > "$dir/decoy/bin/fm-env-tool"
  chmod +x "$dir/decoy/bin/fm-env-tool"
  printf 'home = %s\ninclude-system-site-packages = false\n' "$(dirname "$SLOT_ENV_BASE_PY")" > "$dir/decoy/pyvenv.cfg"
  printf '%s\n' "$dir/elsewhere" > "$dir/decoy/lib/site-packages/editable.pth"
  : > "$dir/tool.log"
}

slot_env_snapshot_decoy() { # <dir> <before|after>
  (cd "$1" && find decoy elsewhere -type f -o -type l | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$f" "$(shasum -a 256 < "$f" | cut -d' ' -f1)"
  done) > "$1/decoy-$2.txt"
}

# Entry names of the copy and the clone, ignored files included; no sizes, no times.
slot_env_listing() { # <dir>
  (cd "$1" && find copy project -print | LC_ALL=C sort)
}

slot_env_break_copy_env() { # <dir> <missing|notexec|venv-outside|bin-outside>
  local dir=$1 shape=$2 copy py
  copy="$dir/copy"
  py=$SLOT_ENV_BASE_PY
  case "$shape" in
    missing) mkdir -p "$copy/.venv/bin" ;;
    notexec)
      mkdir -p "$copy/.venv/bin"
      printf '#!/bin/sh\nexit 0\n' > "$copy/.venv/bin/python"
      chmod 644 "$copy/.venv/bin/python"
      ;;
    venv-outside)
      mkdir -p "$dir/outside-venv/bin"
      ln -s "$py" "$dir/outside-venv/bin/python"
      ln -s "$dir/outside-venv" "$copy/.venv"
      ;;
    bin-outside)
      mkdir -p "$dir/outside-bin" "$copy/.venv"
      ln -s "$py" "$dir/outside-bin/python"
      ln -s "$dir/outside-bin" "$copy/.venv/bin"
      ;;
    *) fail "unknown broken-environment shape: $shape" ;;
  esac
}

slot_env_field() { # <dir> <key>; empty for null or absent
  python3 - "$1/env-record.json" "$2" <<'PY'
import json, sys
value = json.load(open(sys.argv[1])).get(sys.argv[2])
print("" if value is None else value)
PY
}

slot_env_assert_under() { # <path> <root> <msg>
  case "$1/" in "$2"/*) ;; *) fail "$3 ($1 is not under $2)" ;; esac
}

slot_env_tail() { # <dir>
  { cat "$1/refusal.txt" 2>/dev/null; cat "$1/report.json" 2>/dev/null; } | tail -n 12
}

# Base environment of every library-level run: nothing is inherited, PATH is a
# minimal explicit one, and the pass-through sentinels are set. Later NAME=value
# arguments override earlier ones (the last assignment wins).
slot_env_base_assignments() { # <dir>
  local dir=$1
  printf '%s\n' "PATH=$dir/stubs:$dir/pybin:/usr/bin:/bin" "HOME=$dir/home" "TMPDIR=$dir/tmp" \
    "FM_HOME=$dir/home" "FM_STATE_OVERRIDE=$dir/home/state" "FM_STUB_LOG=$dir/stub-calls.log" \
    "FM_TEST_ENV_RECORD=$dir/env-record.json" "FM_TEST_SLOT_RECORD=$dir/slot-record.json" \
    "FM_TEST_TOOL_NAME=fm-env-tool" "FM_TEST_TOOL_LOG=$dir/tool.log" \
    "FM_SENTINEL=sentinel" "CODEX_HOOK_STATE_DIR=$dir/codex-hooks" \
    "WORKTREE_LIFECYCLE_STORE_DIR=$dir/lifecycle" "GIT_AUTHOR_NAME=Fixture" \
    "GIT_AUTHOR_EMAIL=fixture@example.invalid" "GIT_COMMITTER_NAME=Fixture" \
    "GIT_COMMITTER_EMAIL=fixture@example.invalid" "FM_ROOT_DIR=$ROOT"
}

# slot_env_run_provision <dir> <runner> [NAME=value...]: runs fm_slot_provision
# in a clean environment. Exit status is the provision status; the stderr of the
# call is in <dir>/refusal.txt and the project's report in <dir>/report.json.
slot_env_run_provision() {
  local dir=$1 runner=$2 line copy
  local -a assign=()
  shift 2
  while IFS= read -r line; do assign+=("$line"); done < <(slot_env_base_assignments "$dir")
  copy=${SLOT_ENV_COPY_ARG:-$dir/copy}
  env -i "${assign[@]}" "$@" "$SLOT_ENV_BASH" -c '
    . "$FM_ROOT_DIR/bin/fm-wake-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-secondmate-parent-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-secondmate-registry-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-task-copy-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-slot-provision-lib.sh"
    fm_slot_provision "$1" "$2" "$3" "$4" "fm/$4" "$5" "" "" scripts
  ' bash "$runner" "$dir/project" "$copy" "slot-env-task" "$dir/report.json" \
    >"$dir/provision.out" 2>"$dir/refusal.txt"
}
SLOT_ENV_BASH=$(command -v bash)

slot_env_run_check_copy() { # <dir>
  local dir=$1 line
  local -a assign=()
  while IFS= read -r line; do assign+=("$line"); done < <(slot_env_base_assignments "$dir")
  env -i "${assign[@]}" "$SLOT_ENV_BASH" -c '
    . "$FM_ROOT_DIR/bin/fm-wake-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-secondmate-parent-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-secondmate-registry-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-task-copy-lib.sh"
    . "$FM_ROOT_DIR/bin/fm-slot-provision-lib.sh"
    fm_slot_check_copy "$1" "$2"
  ' bash "$dir/project" "$dir/copy"
}

# Prints the VIRTUAL_ENV and PATH the owner gives its child. <tree> <explicit
# python or empty> [NAME=value...] set the inherited environment.
slot_env_owner_probe() { # <dir> <tree> <python-or-empty> [NAME=value...]
  local tree=$2 py=$3
  shift 3
  env -i "FM_ROOT_DIR=$ROOT" "$@" "$SLOT_ENV_BASH" -c '
    . "$FM_ROOT_DIR/bin/fm-copy-env-lib.sh"
    fm_copy_env_build "$1" "$2"
    n=$(( ${#FM_COPY_ENV_CMD[@]} - 1 ))
    "${FM_COPY_ENV_CMD[@]:0:$n}" /bin/sh -c "printf \"VIRTUAL_ENV=%s\\nPATH=%s\\n\" \"\${VIRTUAL_ENV-}\" \"\$PATH\""
  ' bash "$tree" "$py"
}
