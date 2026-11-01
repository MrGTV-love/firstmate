#!/usr/bin/env python3
"""Execute a worker through the shared destination-side environment boundary.

Usage: python3 bin/fm-worker-env.py [--keep NAME ...] [--startup] -- COMMAND [ARG ...]
       python3 bin/fm-worker-env.py --shell-prefix [--harness ID] [--keep NAME ...]

The default is the launch-env-allowlist operational floor. --keep adds
validated names, never values. --harness, valid only with --shell-prefix, adds
the non-secret WORK plumbing, the TOOLCHAIN home paths and that harness's own
HARNESS_ROUTES store selectors; fm-spawn passes it on every launch without
config/launch-env-allowlist, and an allowlist file replaces it with exactly the
listed names. No secret-valued name is kept by default: a
credential kept through --keep or the allowlist still reaches that harness's
tools; it is not credential-isolated.
Main-run readers use the default.
--shell-prefix emits the equivalent names-only shell expansion used by
fm-spawn, preserving listed non-exported destination variables without reading
or serializing their values. fm-spawn adds the destination pane's numbered
GIT_CONFIG entries as env arguments for the default launch. The new process does
not inherit readonly exports or names outside the explicit set. --startup
installs the existing confinement
owner's shell-startup read rules on Darwin for direct readers. Linux has no
corresponding OS guarantee. No credential file is read by this helper.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import time

FLOOR = frozenset("""
HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE
TMPDIR TMP TEMP GOTMPDIR TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH
HERDR_PANE_ID CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID
CMUX_SOCKET_PATH ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID FM_ZELLIJ_SESSION
FM_TASK_ID COMPACT_ADVISER_DISABLE FM_COMPACT_ADVISER_HOOKS LAVISH_AXI_HOST
""".split())
# Non-secret plumbing that ordinary worker Git, no-mistakes, networks and native
# stores use.
WORK = frozenset("""
SSH_AUTH_SOCK SSH_ASKPASS GIT_SSH_COMMAND GIT_CONFIG_GLOBAL NM_HOME
XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
SSL_CERT_FILE SSL_CERT_DIR NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE
CLAUDE_CODE_ENABLE_FUNCTION_HOOKS DISABLE_AUTOUPDATER TRACEPARENT
""".split())
# Non-secret toolchain home paths a worker build may need.
TOOLCHAIN = frozenset("""
JAVA_HOME GOROOT GOPATH CARGO_HOME RUSTUP_HOME PNPM_HOME BUN_INSTALL NVM_DIR
""".split())
# Each harness's non-secret store selectors. Provider API keys and tokens are
# never named here: fm-spawn adds Claude's provider names from
# bin/fm-worker-account-lib.sh and DSH's key name from bin/fm-dsh.py.
HARNESS_ROUTES = {
    "claude": ("CLAUDE_CONFIG_DIR",),
    "codex": ("CODEX_HOME",),
    "grok": ("GROK_HOME",),
    "omp": ("PI_CONFIG_DIR", "PI_CODING_AGENT_DIR", "OMP_PROFILE", "PI_PROFILE"),
    "pi": ("PI_CODING_AGENT_DIR",),
    "pi-signed": ("PI_CODING_AGENT_DIR",),
}
NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def startup_event(decision, started):
    try:
        subprocess.run([str(Path(__file__).with_name("fm-guard-event.sh")),
                        "spawn-shell-startup-confinement", decision,
                        "--source-ok", "true" if decision == "allow" else "false",
                        "--elapsed-ms", str(int((time.monotonic() - started) * 1000)),
                        "--cleared-by", "proceed" if decision == "allow" else "none"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except OSError:
        pass  # Match the launch owner's best-effort audit; never weaken confinement.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="append", default=[])
    parser.add_argument("--harness", help="with --shell-prefix, also keep the work plumbing, toolchain home paths and this harness's store selectors")
    parser.add_argument("--startup", action="store_true")
    parser.add_argument("--shell-prefix", action="store_true", help="emit a names-only clean-env shell prefix for fm-spawn")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if any(not NAME.fullmatch(name) for name in args.keep):
        parser.error("--keep requires an environment name, not a value or shell expression")
    if args.harness is not None and not args.shell_prefix:
        parser.error("--harness requires --shell-prefix")
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    names = FLOOR.union(args.keep)
    if args.harness is not None:
        names |= WORK.union(TOOLCHAIN, HARNESS_ROUTES.get(args.harness, ()))
    if args.shell_prefix:
        if command or args.startup:
            parser.error("--shell-prefix accepts names only, without a command or --startup")
        # Preserve the launch owner's shell-variable semantics, including a
        # listed non-exported variable. This reads no environment values here.
        print("/usr/bin/env -i " + " ".join('${%s+"%s=$%s"}' % (name, name, name) for name in sorted(names)))
        return 0
    if not command:
        parser.error("a worker command is required after --")
    environment = {name: value for name, value in os.environ.items() if name in names}
    if args.startup:
        started = time.monotonic()
        try:
            if sys.platform != "darwin" or not os.access("/usr/bin/sandbox-exec", os.X_OK):
                raise ValueError("--startup requires Darwin Seatbelt")
            sys.dont_write_bytecode = True
            spec = importlib.util.spec_from_file_location("fm_confinement", Path(__file__).with_name("fm-write-confinement.py"))
            owner = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(owner)
            profile = "\n".join(["(version 1)", "(allow default)", *owner.startup_read_rules(Path.home())])
        except (OSError, ValueError) as error:
            startup_event("deny", started)
            parser.error(f"worker startup confinement refused: {error}; preserve the task and ask Main to repair the supported startup boundary before retrying")
        startup_event("allow", started)
        command = ["/usr/bin/sandbox-exec", "-p", profile, *command]
    try:
        os.execvpe(command[0], command, environment)
    except OSError as error:
        print(f"worker launch failed: {error.strerror}", file=sys.stderr)
        return 126
    return 0


if __name__ == "__main__":
    sys.exit(main())
