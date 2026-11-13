#!/usr/bin/env bash
# shellcheck disable=SC2034 # FM_COPY_ENV_* are output globals for sourcing callers.
# The one owner of the interpreter environment for a script that lives in a task
# copy or a clone. The rule: an environment follows the tree that owns the script.
# The script's own tree supplies the interpreter (<tree>/.venv/bin/python, run by
# its absolute path) and the venv; a nested clone, another clone and an inherited
# ambient environment never do. Callers: provisioning (bin/fm-slot-provision-lib.sh,
# both runners), Vernant's closeout driver (bin/fm-teardown-nested-lib.sh, which
# bin/fm-copy-sweep.sh reaches), and the slot-record retirement
# (bin/fm-slot-manifest-retire.py, through bin/fm-copy-env.sh).
#
# fm_copy_env_check <tree> says whether a tree can run a script of its own. It is
# usable only when <tree>/.venv/bin/python is an executable file and the real
# paths of <tree>/.venv and <tree>/.venv/bin stay inside the real path of <tree>
# (the interpreter binary itself is not resolved: a real venv's python links to a
# base interpreter). On refusal it sets FM_COPY_ENV_REASON, a named reason that
# names the tree. Nothing is installed, created or changed, and nothing falls back
# to another environment.
#
# fm_copy_env_build <tree> [<explicit-python>] builds FM_COPY_ENV_CMD, an env
# prefix argv that runs the interpreter by absolute path with this environment:
#   - VIRTUAL_ENV is the tree's own .venv, and <tree>/.venv/bin is first on PATH,
#     followed by the inherited PATH in its original order minus every foreign
#     venv bin ($VIRTUAL_ENV/bin, any other .venv/bin, and any entry whose parent
#     holds a pyvenv.cfg), so git still resolves and a tool only a foreign venv
#     holds does not;
#   - PYTHONPATH, PYTHONHOME, PYTHONUSERBASE, PYTHONSTARTUP, __PYVENV_LAUNCHER__,
#     UV_PROJECT_ENVIRONMENT and CONDA_PREFIX are unset;
#   - every other variable passes through unchanged (a named unset and a PATH
#     filter, never a rebuild from a whitelist), and the working directory stays.
# An explicit interpreter (an operator choice such as FM_TEARDOWN_VERNANT_PYTHON)
# replaces only the interpreter choice: under <tree>/.venv it gets the tree's own
# venv as above; anywhere else VIRTUAL_ENV is unset, no venv bin leads PATH, and
# the interpreter's own bin directory is not put on PATH.
# fm_copy_env_run <tree> <explicit-python-or-empty> <arg>... runs it.
# bin/fm-copy-env.sh is the command-line entry for callers outside bash.

FM_COPY_ENV_REASON=
FM_COPY_ENV_PATH=
FM_COPY_ENV_CMD=()
FM_COPY_ENV_UNSET=(PYTHONPATH PYTHONHOME PYTHONUSERBASE PYTHONSTARTUP __PYVENV_LAUNCHER__ UV_PROJECT_ENVIRONMENT CONDA_PREFIX)

fm_copy_env_realdir() { # <dir>; prints the physical path, fails when it is not a directory
  (cd -P -- "$1" 2>/dev/null && pwd -P)
}

fm_copy_env_check() { # <tree>
  local tree=${1%/} venv py root real_venv real_bin
  FM_COPY_ENV_REASON=
  venv=$tree/.venv
  py=$venv/bin/python
  if [ ! -f "$py" ] || [ ! -x "$py" ]; then
    FM_COPY_ENV_REASON="copy_environment_missing: $py is not an executable file; $tree has no usable environment of its own, so nothing was changed, installed or created (give the copy its own .venv, then retry)"
    return 1
  fi
  root=$(fm_copy_env_realdir "$tree") || root=
  real_venv=$(fm_copy_env_realdir "$venv") || real_venv=
  real_bin=$(fm_copy_env_realdir "$venv/bin") || real_bin=
  if [ -z "$root" ] || [ -z "$real_venv" ] || [ -z "$real_bin" ]; then
    FM_COPY_ENV_REASON="copy_environment_unreadable: the real paths of $venv and $venv/bin cannot be read; nothing was changed, installed or created"
    return 1
  fi
  case "$real_venv/" in "$root"/*) ;; *)
    FM_COPY_ENV_REASON="copy_environment_outside_copy: $venv resolves to $real_venv, outside the copy $tree; another tree's environment is never used, and nothing was changed, installed or created"
    return 1 ;;
  esac
  case "$real_bin/" in "$root"/*) ;; *)
    FM_COPY_ENV_REASON="copy_environment_outside_copy: $venv/bin resolves to $real_bin, outside the copy $tree; another tree's environment is never used, and nothing was changed, installed or created"
    return 1 ;;
  esac
}

fm_copy_env_path() { # <own-bin-or-empty>; sets FM_COPY_ENV_PATH
  local lead=$1 entry out='' parts=()
  IFS=: read -r -a parts <<<"${PATH-}"
  out=$lead
  for entry in ${parts[@]+"${parts[@]}"}; do
    [ -z "$lead" ] || [ "$entry" != "$lead" ] || continue
    [ -z "${VIRTUAL_ENV:-}" ] || [ "$entry" != "${VIRTUAL_ENV%/}/bin" ] || continue
    case "$entry" in
      */.venv/bin) continue ;;
      */*) [ ! -f "${entry%/*}/pyvenv.cfg" ] || continue ;;
    esac
    out=${out:+$out:}$entry
  done
  FM_COPY_ENV_PATH=$out
}

fm_copy_env_build() { # <tree> [<explicit-python>]
  local tree=${1%/} py=${2:-} venv lead='' var
  venv=$tree/.venv
  [ -n "$py" ] || py=$venv/bin/python
  case "$py" in "$venv"/*) lead=$venv/bin ;; esac
  fm_copy_env_path "$lead"
  FM_COPY_ENV_CMD=(/usr/bin/env -u VIRTUAL_ENV)
  for var in "${FM_COPY_ENV_UNSET[@]}"; do FM_COPY_ENV_CMD+=(-u "$var"); done
  [ -z "$lead" ] || FM_COPY_ENV_CMD+=("VIRTUAL_ENV=$venv")
  FM_COPY_ENV_CMD+=("PATH=$FM_COPY_ENV_PATH" "$py")
}

fm_copy_env_run() { # <tree> <explicit-python-or-empty> <arg>...
  local tree=$1 py=$2
  shift 2
  fm_copy_env_build "$tree" "$py"
  "${FM_COPY_ENV_CMD[@]}" "$@"
}
