#!/usr/bin/env bash
# Literal lock-interval audit: forbidden work, local wrappers, baselines, and
# slow work outside ownership. No fixture executes its forbidden commands.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

"$ROOT/bin/fm-proc-budget.sh" 128 -- python3 - "$ROOT/bin/fm-lock-audit.py" <<'PY' || fail "locked-section lint behavior failed"
import os, pathlib, subprocess, sys, tempfile

audit = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="fm-lock-audit-") as d:
    root = pathlib.Path(d)
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=d, text=True).strip()
    git("init", "-q")
    git("config", "user.name", "Fixture")
    git("config", "user.email", "fixture@example.invalid")
    (root / "bin").mkdir()
    script = root / "bin/fixture.sh"
    safe = 'fm_lock_acquire_wait "$lock"\nprintf ok\nfm_lock_release "$lock"\n'
    script.write_text(safe)
    git("add", "."); git("commit", "-qm", "safe fixture")
    base = git("rev-parse", "HEAD")
    def check(source, expected):
        script.write_text(source)
        result = subprocess.run(["python3", audit, "--base", base, "bin/fixture.sh"], cwd=d, text=True, capture_output=True, timeout=30)
        assert result.returncode == expected, (source, result.returncode, result.stdout, result.stderr)
        return result.stdout
    for bad in ["gh api /user", "gh-axi pr list", "curl https://example.invalid", "git fetch origin", "git -C repo push", "git -c color.ui=never fetch origin", "git --git-dir=repo push", "no-mistakes axi run", '"$BIN/fm-send.sh" task text', "sleep 1", "provider_call request", "model_request prompt"]:
        output = check(safe.replace("printf ok", bad), 1)
        assert "bin/fixture.sh:2:" in output, output
    check('slow() {\n curl https://example.invalid\n}\n' + safe.replace("printf ok", "slow"), 1)
    check('curl before\n' + safe + '\nsleep 1\n', 0)
    check(safe.replace("printf ok", "# curl is documentation\nprintf '%s' 'gh api /user'"), 0)
    check('while ! fm_lock_try_acquire "$lock"; do\n sleep .1\ndone\nfm_lock_release "$lock"\n', 0)
    check(safe.replace("printf ok", "git -C repo log --grep push"), 0)
    check(safe.replace("printf ok", '''case "$harness" in
 '' | claude | "codex" | pi ) printf ready ;;
 *) : ;;
esac'''), 0)
    check(safe.replace("printf ok", '''case "$harness" in
 claude ) sleep 1 ;;
esac'''), 1)
    check(safe.replace("printf ok", '(\n "claude" )'), 1)
    # A long ordinary body word must not trigger exponential case-label
    # backtracking while the auditor searches for a closing parenthesis.
    check(safe.replace("printf ok", 'case "$harness" in\n claude)\n  cached_' + 'x' * 256 + '=yes\n ;;\nesac'), 0)
    check(safe.replace("printf ok", "sleep 1"), 1)
    git("add", "."); git("commit", "-qm", "existing violation fixture")
    base = git("rev-parse", "HEAD")
    output = check(script.read_text(), 0)
    assert "existing follow-up" in output, output
    # Moving unchanged legacy work does not make it new, but adding another
    # invocation is a regression and cannot consume one baseline twice.
    check("# shifted\n" + script.read_text(), 0)
    check(script.read_text().replace("sleep 1", "sleep 1\nsleep 1"), 1)
PY
pass "locked-section lint rejects new slow work and exposes existing follow-ups"
