#!/usr/bin/env python3
"""Validate and execute machine-checkable task criteria.

Usage:
  fm-dod-check.py plan --dod FILE --repo DIR --base SHA --head SHA --output DIR
  fm-dod-check.py exec --task JSON --repo DIR --head SHA --output DIR
  fm-dod-check.py record --plan DIR --legs DIR --execute-result RESULT --output DIR
  fm-dod-check.py run --dod FILE --repo DIR --base SHA --head SHA --output DIR
  fm-dod-check.py freeze --brief FILE --state DIR --task ID
  fm-dod-check.py dispatch --meta FILE --pr URL
  fm-dod-check.py claims --meta FILE --run RUN_ID > CLAIMS.json
  fm-dod-check.py verify --meta FILE --pr URL --base SHA --head SHA < CLAIMS.json

The item format and parser are owned by fm_dod_item_shape in bin/fm-dod-lib.sh.
Check is a single-line bash command, optionally enclosed in one pair of backticks.
freeze records exact selected criteria bytes at state/<task>.dod.<sha256>.md;
spawn records dod_file and dod_sha256 before launching the worker and preserves
both on relaunch. Existing tasks without a dispatch snapshot cannot claim one
retroactively; bin/fm-review-record.py verify --machine-checked reports them as
not machine-checked and keeps the existing merge contract.
dispatch submits only those frozen bytes and the exact PR head to
dod-evidence.yml on the repository default branch through gh-axi, so the
workflow, this checker and the weakened-test detector run from code the PR
cannot change; the candidate tree is checked out only as data to test. A
default branch without that workflow is reported, never bootstrapped.
verify refuses a run whose workflow ref is not the default branch or whose
workflow commit is not in that branch's history.
The workflow splits evidence across process and machine boundaries: plan runs
trusted code over the candidate as data, lists one task per gate command and
per fail-first phase, and runs the weakened-test detector; exec runs exactly one
task's command in its own matrix runner; record, on a runner that executes no
candidate command, takes only each leg's exit code and log, writes command,
commit and digests itself, and fails unless every leg job succeeded. run is the
same plan, exec and record in one local process: smoke evidence only.
The base is the PR base GitHub reported at dispatch, recorded by plan. Changed
tests, the fail-first base tree and the weakened-test diff use the merge base of
that base and the head. verify accepts that recorded base while it is in the
live base's history, so an unrelated base advance never invalidates evidence.
claims prints the minimal claims JSON for a finished run: one id/run_id pointer
per frozen mandatory item. The reviewer adds an accept ruling with a reason for
each weakened-test flag that verify names.
verify accepts JSON copied into the independent PASS record by --dod-evidence:
  {"items":[{"id":"C1","run_id":"123","commit":"<exact head>",
    "file":"bin/example.sh","line":7,"log":"gate-C1.log",
    "log_sha256":"<sha256>"}],
   "rulings":[{"id":"<flag digest>","decision":"accept","reason":"<reviewer ruling>"}]}
Every mandatory id needs exactly one pointer, and every pointer names its own
run_id; the minimal pointer is id/run_id. Supplied commit, file/line or log
digest refinements must all resolve; omitted commit and log are derived from
the exact-head manifest, never from mutable branch refs.
Gate pointers name their exact command log; other authorities may point at a passing test log or summary.log,
which proves automated execution, not design quality. The reviewer still grades
semantic adequacy. Each weakened-test flag needs an explicit accept with a reason.
CI's exact-head artifact, run attempt, successful default-branch run,
DoD digest, all gate commands, fail-first results, logs and file:line must resolve.
The resolver requires GitHub's successful default-branch run record and its
exact-head artifact, not a model's statement of success. verify exits 3 when
hosted or local evidence cannot be reached and 1 when evidence was read and
does not resolve.
Test paths named anywhere in an item's fields use tests/<name>.test.sh.
For changed named tests, the HEAD test is overlaid onto an exported merge-base
tree: absence of a new test on base is not fail-first proof. Other files stay
at base. Trees are git archives of exact full commits, never the caller's dirty
tree. Output directories must not exist; record's holds command logs and
results.json, bound to the DoD digest, commits and GitHub run. Logs include
exit codes and SHA-256 digests. Commands run without forge credentials.
A nonzero base exit and zero head exit are required for every changed named test.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile


class CheckError(Exception):
    """Invalid criteria or unavailable commit evidence."""


class Unavailable(CheckError):
    """Hosted evidence could not be reached; nothing was read to judge."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


BIN = Path(__file__).resolve().parent


def owner(*args):
    result = subprocess.run(["bash", str(BIN / "fm-dod-lib.sh"), *map(str, args)],
                            capture_output=True, check=False)
    if result.returncode:
        raise CheckError(result.stderr.decode(errors="replace").strip() or "criteria owner refused input")
    return result.stdout


def items_from(text):
    # The dispatch/plan format owner is also the sole parser for CI and merge.
    with tempfile.TemporaryDirectory(prefix="fm-dod-parse-") as directory:
        path = Path(directory) / "dod.md"
        path.write_bytes(text.encode())
        items = json.loads(owner("--items", path))
    for item in items:
        fields = item["fields"]
        item["tests"] = named_tests("\n".join(fields.values()))
        command = fields.get("Check", "")
        if command.startswith("`") and command.endswith("`"):
            command = command[1:-1]
        item["command"] = command
    return items


def named_tests(text):
    paths = sorted(set(re.findall(r"(?<![\w/.-])(tests/[A-Za-z0-9_./-]+\.test\.sh)(?![\w/.-])", text)))
    if any(".." in PurePosixPath(path).parts for path in paths):
        raise CheckError("unsafe named test path")
    return paths


def freeze(args):
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}", args.task):
        raise CheckError("invalid task id")
    raw = owner("--criteria", args.brief)
    items_from(raw.decode())
    sha = digest(raw)
    state = args.state.resolve(strict=True)
    path = state / f"{args.task}.dod.{sha}.md"
    try:
        with path.open("xb") as stream:
            stream.write(raw)
        path.chmod(0o444)
    except FileExistsError:
        if path.is_symlink() or not path.is_file() or path.read_bytes() != raw:
            raise CheckError("dispatch DoD snapshot collision")
    print(json.dumps({"dod_file": str(path), "dod_sha256": sha}))
    return 0


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=False,
                            env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"))
    if result.returncode:
        raise CheckError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def commit(repo, value):
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value):
        raise CheckError("base and head must be exact full commit shas")
    resolved = git(repo, "rev-parse", "--verify", f"{value}^{{commit}}").decode().strip()
    if resolved != value:
        raise CheckError(f"commit did not resolve exactly: {value}")
    return resolved


def export(repo, sha, destination):
    destination.mkdir()
    with tarfile.open(fileobj=io.BytesIO(git(repo, "archive", sha))) as archive:
        # Git archives can contain repository-controlled symlinks. The data
        # filter rejects links escaping the exported tree before any execution.
        archive.extractall(destination, filter="data")


def execute(command, cwd, output, name, sha):
    log = output / f"{name}.log"
    # No token, credentials, or Actions control-file paths go to PR commands.
    environment = {key: value for key, value in os.environ.items()
                   if key in ("PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "SYSTEMROOT")}
    print(f"command: {json.dumps(command)}", flush=True)
    with log.open("wb") as stream:
        stream.write(f"command: {command}\ncommit: {sha}\n".encode())
        stream.flush()
        invocation = ["bash", "-o", "pipefail", "-c", command]
        result = subprocess.run(invocation, cwd=cwd, env=environment,
                                stdout=stream, stderr=subprocess.STDOUT, check=False)
        stream.write(f"\nexit: {result.returncode}\n".encode())
    print(f"exit: {result.returncode}\nlog: {json.dumps(log.name)}", flush=True)
    return {"command": command, "commit": sha, "exit": result.returncode,
            "log": log.name, "sha256": digest(log.read_bytes())}


def plan_into(repo, base, head, raw, items, output):
    repo = repo.resolve()
    base, head = commit(repo, base), commit(repo, head)
    merge_base = git(repo, "merge-base", base, head).decode().strip()
    output.mkdir(parents=True, exist_ok=False)
    changed = set(git(repo, "diff", "--name-only", "-z", merge_base, head, "--", "tests").decode().split("\0"))
    tasks = [{"name": f"gate-{item['id']}", "kind": "gate", "id": item["id"],
              "command": item["command"], "commit": head}
             for item in items if item["mandatory"] and item["fields"]["Authority"] == "gate"]
    for index, path in enumerate(sorted(set(named_tests(raw.decode())) & changed)):
        for phase, sha in (("base", merge_base), ("head", head)):
            tasks.append({"name": f"test-{index}-{phase}", "kind": "test", "path": path,
                          "phase": phase, "command": f"bash {path}", "commit": sha})
    detected = subprocess.run([sys.executable, str(BIN / "fm-test-weakening.py"), "--repo", str(repo),
                               "--base", base, "--head", head, "--output", str(output / "weakening.json")],
                              capture_output=True, text=True, check=False)
    if detected.returncode not in (0, 1):
        raise CheckError(f"weakened-test detector failed: {detected.stdout.strip()}")
    print(detected.stdout, end="", flush=True)
    (output / "plan.json").write_text(json.dumps({"schema": "fm-dod-plan.v1", "head": head, "base": base,
                                                  "merge_base": merge_base, "dod_sha256": digest(raw),
                                                  "tasks": tasks}, indent=2) + "\n")
    (output / "dod.md").write_bytes(raw)
    print(f"head: {head}\nbase: {base}\nmerge_base: {merge_base}\ntasks: {len(tasks)}", flush=True)
    return tasks


def exec_into(repo, head, task, output):
    repo = repo.resolve()
    head = commit(repo, head)
    sha = commit(repo, task["commit"])
    name = task["name"]
    if not re.fullmatch(r"(gate|test)-[A-Za-z0-9_.-]+", name) or task["kind"] not in ("gate", "test"):
        raise CheckError("invalid evidence task")
    output.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="fm-dod-") as scratch:
        # Each command receives a fresh exact-commit export of its own.
        tree = Path(scratch) / "tree"
        export(repo, sha, tree)
        if task["kind"] == "test":
            # The HEAD test is overlaid onto the base tree; other files stay at base.
            path = task["path"]
            if named_tests(path) != [path]:
                raise CheckError(f"invalid named test path: {path}")
            mode = git(repo, "ls-tree", head, "--", path).decode().split(" ", 1)[0]
            if mode not in ("100644", "100755"):
                raise CheckError(f"changed named test is absent or a symlink at head: {path}")
            target = tree / path
            if target.is_symlink() or any(parent.is_symlink() for parent in target.parents):
                raise CheckError(f"test path traverses a symlink: {path}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(git(repo, "show", f"{head}:{path}"))
        result = execute(task["command"], tree, output, name, sha)
    (output / f"{name}.json").write_text(json.dumps({**result, "name": name}) + "\n")
    return result


def record_into(plan_dir, legs, execute_result, output):
    plan = json.loads(safe_artifact(plan_dir, "plan.json"))
    raw = safe_artifact(plan_dir, "dod.md")
    weakening_bytes = safe_artifact(plan_dir, "weakening.json")
    weakening = json.loads(weakening_bytes)
    head, base, tasks = plan.get("head"), plan.get("base"), plan.get("tasks")
    if (plan.get("schema") != "fm-dod-plan.v1" or plan.get("dod_sha256") != digest(raw)
            or not isinstance(tasks, list) or weakening.get("schema") != "fm-test-weakening.v1"
            or weakening.get("head") != head or weakening.get("base") != base):
        raise CheckError("plan artifact does not bind this DoD, base and head")
    output.mkdir(parents=True, exist_ok=False)
    rows = {}
    for task in tasks:
        # Only the leg's exit and log come from its isolated runner; the
        # command, commit and digest are this trusted recorder's own.
        directory = legs / f"leg-{task['name']}"
        result = json.loads(safe_artifact(directory, f"{task['name']}.json"))
        if result.get("name") != task["name"] or type(result.get("exit")) is not int or result.get("log") != f"{task['name']}.log":
            raise CheckError(f"isolated leg result does not match its planned task: {task['name']}")
        log = safe_artifact(directory, result["log"])
        (output / result["log"]).write_bytes(log)
        rows[task["name"]] = {"command": task["command"], "commit": task["commit"], "exit": result["exit"],
                              "log": result["log"], "sha256": digest(log)}
        print(f"command: {json.dumps(task['command'])}\ncommit: {task['commit']}\nexit: {result['exit']}", flush=True)
    passed = execute_result == "success" or (execute_result == "skipped" and not tasks)
    manifest = {"schema": "fm-dod-evidence.v1", "head": head, "base": base, "merge_base": plan.get("merge_base"),
                "dod_sha256": digest(raw), "run_id": os.environ.get("GITHUB_RUN_ID", ""),
                "run_attempt": os.environ.get("GITHUB_RUN_ATTEMPT", ""), "items": [], "tests": []}
    for task in tasks:
        row = rows[task["name"]]
        if task["kind"] == "gate":
            manifest["items"].append({**row, "id": task["id"]})
            passed = row["exit"] == 0 and passed
        elif task["phase"] == "head":
            base_row = rows[task["name"].removesuffix("-head") + "-base"]
            test = {"path": task["path"], "base": base_row, "head": row,
                    "passed": base_row["exit"] != 0 and row["exit"] == 0}
            passed = test["passed"] and passed
            manifest["tests"].append(test)
            print(f"test: {json.dumps(task['path'])}\nfail_first: {'pass' if test['passed'] else 'fail'}", flush=True)
    manifest["passed"] = passed
    (output / "results.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (output / "summary.log").write_text(f"head: {head}\nbase: {base}\ndod_sha256: {digest(raw)}\nresult: {'pass' if passed else 'fail'}\n")
    (output / "dod.md").write_bytes(raw)
    (output / "weakening.json").write_bytes(weakening_bytes)
    print(f"head: {head}\nbase: {base}\ndod_sha256: {digest(raw)}\nresult: {'pass' if passed else 'fail'}", flush=True)
    return 0 if passed else 1


def run(args, raw, items):
    output = args.output.resolve()
    if output.exists() or output.is_symlink():
        raise CheckError("output directory must not exist")
    with tempfile.TemporaryDirectory(prefix="fm-dod-local-") as scratch:
        scratch = Path(scratch)
        tasks = plan_into(args.repo, args.base, args.head, raw, items, scratch / "plan")
        for task in tasks:
            exec_into(args.repo, args.head, task, scratch / "legs" / f"leg-{task['name']}")
        return record_into(scratch / "plan", scratch / "legs", "success", output)


def forge_api(endpoint):
    # gh-axi formats JSON as TOON; base64 preserves the complete JSON document
    # in its scalar body without depending on a parallel JSON CLI.
    import base64
    result = subprocess.run(["gh-axi", "api", endpoint, "--jq", "tojson | @base64", "--full"],
                            capture_output=True, text=True, check=False)
    match = re.search(r"^  body: ([A-Za-z0-9+/=]+)$", result.stdout, re.M)
    if result.returncode or not match or "  truncated: false" not in result.stdout:
        raise Unavailable(f"cannot resolve GitHub evidence: {endpoint}: {result.stderr.strip()}")
    return json.loads(base64.b64decode(match[1], validate=True))


def github_pr(url):
    match = re.fullmatch(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)", url)
    if not match:
        raise CheckError("machine-checked DoD evidence currently requires a github.com pull request")
    return match.groups()


def frozen(meta_path):
    fields = dict(line.split("=", 1) for line in meta_path.read_text().splitlines() if "=" in line)
    sha = fields.get("dod_sha256", "")
    if not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise CheckError("task has no dispatch-time DoD digest; do not adopt mutable worker criteria")
    path = meta_path.parent / f"{meta_path.stem}.dod.{sha}.md"
    if fields.get("dod_file") != str(path) or path.is_symlink():
        raise CheckError("frozen DoD path does not match the task's protected state record")
    raw = path.read_bytes()
    if digest(raw) != sha:
        raise CheckError("frozen DoD digest changed")
    return fields, raw, items_from(raw.decode())


def default_branch(repo):
    branch = forge_api(f"/repos/{repo}").get("default_branch")
    if not isinstance(branch, str) or not branch:
        raise CheckError("cannot resolve the repository default branch")
    return branch


def dispatch(args):
    _, raw, _ = frozen(args.meta.resolve(strict=True))
    repo, number = github_pr(args.pr)
    pr = forge_api(f"/repos/{repo}/pulls/{number}")
    if pr.get("state") != "open":
        raise CheckError("PR must be open")
    result = subprocess.run(["gh-axi", "workflow", "run", "dod-evidence.yml", "--repo", repo,
                             "--ref", default_branch(repo), "--field", f"pr={number}",
                             "--field", f"head={pr['head']['sha']}", "--field", f"dod={raw.decode()}"],
                            capture_output=True, text=True, check=False)
    if result.returncode:
        raise CheckError(f"DoD CI dispatch refused: {result.stdout} {result.stderr}")
    print(result.stdout, end="")
    print(f"head: {pr['head']['sha']}\ndod_sha256: {digest(raw)}")
    return 0


def emit_claims(args):
    _, _, items = frozen(args.meta.resolve(strict=True))
    if not re.fullmatch(r"[1-9][0-9]*", args.run):
        raise CheckError("run must be a GitHub Actions run id")
    print(json.dumps({"items": [{"id": item["id"], "run_id": args.run} for item in items]}))
    return 0


def safe_artifact(directory, name):
    if not isinstance(name, str) or not name or PurePosixPath(name).name != name:
        raise CheckError("evidence log must name an artifact file, not a path")
    path = directory / name
    if path.is_symlink() or not path.is_file():
        raise CheckError(f"missing ordinary artifact file: {name}")
    return path.read_bytes()


def verify_evidence(args, claims):
    meta, raw, items = frozen(args.meta.resolve(strict=True))
    repo, number = github_pr(args.pr)
    worktree = Path(meta["worktree"])
    base, head = commit(worktree, args.base), commit(worktree, args.head)
    pointers = claims.get("items") if isinstance(claims, dict) else None
    if not isinstance(pointers, list) or {p.get("id") for p in pointers if isinstance(p, dict)} != {i['id'] for i in items} or len(pointers) != len(items):
        raise CheckError("PASS must carry exactly one resolving pointer for mandatory ids: " + ",".join(item['id'] for item in items))
    by_id = {item['id']: item for item in items}
    trusted_ref = default_branch(repo)
    runs = {}
    with tempfile.TemporaryDirectory(prefix="fm-dod-resolve-") as scratch:
        for pointer in pointers:
            item = by_id[pointer['id']]
            run_id = str(pointer.get("run_id", ""))
            if not re.fullmatch(r"[1-9][0-9]*", run_id) or pointer.get("commit", head) != head:
                raise CheckError(f"{item['id']}: evidence needs a CI run id at the exact PR head")
            if run_id not in runs:
                run = forge_api(f"/repos/{repo}/actions/runs/{run_id}")
                if (str(run.get("id")) != run_id or run.get("event") != "workflow_dispatch"
                        or run.get("path") != ".github/workflows/dod-evidence.yml"
                        or run.get("status") != "completed" or run.get("conclusion") != "success"
                        or run.get("repository", {}).get("full_name") != repo):
                    raise CheckError(f"{item['id']}: CI run is missing, unfinished, failed, or not the DoD workflow")
                if run.get("head_branch") != trusted_ref:
                    raise CheckError(f"{item['id']}: CI workflow ref is not the default branch {trusted_ref}")
                workflow_sha = str(run.get("head_sha", ""))
                if (not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", workflow_sha)
                        or forge_api(f"/repos/{repo}/compare/{workflow_sha}...{trusted_ref}").get("status") not in ("identical", "ahead")):
                    raise CheckError(f"{item['id']}: CI workflow commit is not in default branch {trusted_ref} history")
                artifacts = forge_api(f"/repos/{repo}/actions/runs/{run_id}/artifacts?per_page=100")
                name = f"fm-dod-evidence-{head}"
                matches = [a for a in artifacts.get("artifacts", []) if a.get("name") == name and not a.get("expired")]
                if len(matches) != 1 or artifacts.get("total_count", 0) > 100:
                    raise CheckError("exact-head CI evidence artifact missing, expired, or ambiguous")
                directory = Path(scratch) / run_id
                downloaded = subprocess.run(["gh-axi", "run", "download", run_id, "--repo", repo,
                                             "--name", name, "--dir", str(directory)], capture_output=True, text=True, check=False)
                if downloaded.returncode:
                    raise Unavailable("cannot download recorded CI evidence artifact")
                manifest = json.loads(safe_artifact(directory, "results.json"))
                recorded = commit(worktree, str(manifest.get("base", "")))
                ancestry = subprocess.run(["git", "-C", str(worktree), "merge-base", "--is-ancestor", recorded, base],
                                          capture_output=True, check=False, env=dict(os.environ, GIT_NO_REPLACE_OBJECTS="1"))
                if ancestry.returncode:
                    raise CheckError("CI evidence base is not in the live PR base history")
                merge_base = git(worktree, "merge-base", recorded, head).decode().strip()
                if (manifest.get("schema") != "fm-dod-evidence.v1" or manifest.get("head") != head
                        or manifest.get("merge_base") != merge_base or manifest.get("dod_sha256") != digest(raw)
                        or str(manifest.get("run_id")) != run_id
                        or str(manifest.get("run_attempt")) != str(run.get("run_attempt"))
                        or manifest.get("passed") is not True
                        or safe_artifact(directory, "dod.md") != raw):
                    raise CheckError("CI artifact does not prove this frozen DoD at this dispatch base/head/run attempt")
                gates = {row.get('id'): row for row in manifest.get('items', [])}
                required_gates = {i['id'] for i in items if i['fields']['Authority'] == 'gate'}
                if set(gates) != required_gates:
                    raise CheckError("CI did not run every mandatory gate command")
                logs = {}
                for gate_id, row in gates.items():
                    if row.get('command') != by_id[gate_id]['command'] or row.get('commit') != head or row.get('exit') != 0:
                        raise CheckError("CI gate command/result does not match frozen criteria")
                    logs[row['log']] = row['sha256']
                expected_tests = set(named_tests(raw.decode())) & set(git(worktree, 'diff', '--name-only', merge_base, head, '--', 'tests').decode().splitlines())
                tests = manifest.get('tests', [])
                if {row.get('path') for row in tests} != expected_tests or len(tests) != len(expected_tests):
                    raise CheckError("CI fail-first evidence omits a changed named test")
                for test in tests:
                    if (test.get('passed') is not True or test['base'].get('exit') == 0
                            or test['base'].get('commit') != merge_base or test['head'].get('exit') != 0
                            or test['head'].get('commit') != head):
                        raise CheckError("CI fail-first proof did not fail on base and pass on head")
                    for phase in ('base', 'head'):
                        row = test[phase]
                        if digest(safe_artifact(directory, row['log'])) != row['sha256']:
                            raise CheckError("CI fail-first log digest does not resolve")
                    logs[test['head']['log']] = test['head']['sha256']
                for name, sha in logs.items():
                    if digest(safe_artifact(directory, name)) != sha:
                        raise CheckError("CI log digest does not resolve")
                summary = safe_artifact(directory, 'summary.log')
                logs['summary.log'] = digest(summary)
                weakening = json.loads(safe_artifact(directory, 'weakening.json'))
                if weakening.get('schema') != 'fm-test-weakening.v1' or weakening.get('head') != head or weakening.get('base') != recorded:
                    raise CheckError("weakened-test evidence does not match this PR diff")
                # Recompute flags with trusted local detector too: the reviewer
                # must explicitly accept each exact removed/raised line.
                detected = subprocess.run([sys.executable, str(BIN / 'fm-test-weakening.py'), '--repo', str(worktree),
                                           '--base', recorded, '--head', head, '--output', str(Path(scratch) / 'weakening.json')],
                                          capture_output=True, check=False)
                if detected.returncode not in (0, 1) or json.loads((Path(scratch) / 'weakening.json').read_text()) != weakening:
                    raise CheckError("CI weakened-test flags do not resolve against the exact diff")
                rulings = claims.get('rulings', [])
                if not isinstance(rulings, list) or any(not isinstance(r, dict) for r in rulings):
                    raise CheckError("reviewer rulings must be a list")
                ruling_ids = [r.get('id') for r in rulings]
                if any(not isinstance(value, str) for value in ruling_ids) or len(set(ruling_ids)) != len(ruling_ids):
                    raise CheckError("each flagged line needs one unambiguous reviewer ruling")
                accepted = {r.get('id') for r in rulings if r.get('decision') == 'accept' and isinstance(r.get('reason'), str) and r['reason'].strip()}
                for flag in weakening['flags']:
                    if flag['id'] not in accepted:
                        raise CheckError(f"{flag['file']}:{flag['line']} ({flag['id']}): weakened-test line needs an explicit accept ruling and reason in the independent PASS record")
                runs[run_id] = (gates, logs)
            gates, logs = runs[run_id]
            default_log = gates[item['id']]['log'] if item['fields']['Authority'] == 'gate' else 'summary.log'
            log = pointer.get('log', default_log)
            if log not in logs or pointer.get('log_sha256', logs[log]) != logs[log]:
                raise CheckError(f"{item['id']}: PASS log pointer does not resolve")
            if item['fields']['Authority'] == 'gate' and log != default_log:
                raise CheckError(f"{item['id']}: gate pointer does not name its exact command log")
            if 'file' in pointer or 'line' in pointer:
                file, line = pointer.get('file'), pointer.get('line')
                if (not isinstance(file, str) or not file or PurePosixPath(file).is_absolute()
                        or '..' in PurePosixPath(file).parts or type(line) is not int or line < 1):
                    raise CheckError(f"{item['id']}: invalid commit file:line pointer")
                mode = git(worktree, 'ls-tree', head, '--', file).decode().split(' ', 1)[0]
                if mode not in ('100644', '100755') or line > len(git(worktree, 'show', f'{head}:{file}').splitlines()):
                    raise CheckError(f"{item['id']}: file:line does not exist at the exact PR head")
    print(f"evidence: resolved head={head} items={len(items)}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="action", required=True)
    for action in ("plan", "run"):
        command = sub.add_parser(action)
        command.add_argument("--dod", type=Path, required=True)
        command.add_argument("--repo", type=Path, required=True)
        command.add_argument("--base", required=True)
        command.add_argument("--head", required=True)
        command.add_argument("--output", type=Path, required=True)
    command = sub.add_parser("exec")
    command.add_argument("--task", required=True)
    command.add_argument("--repo", type=Path, required=True)
    command.add_argument("--head", required=True)
    command.add_argument("--output", type=Path, required=True)
    command = sub.add_parser("record")
    command.add_argument("--plan", type=Path, required=True)
    command.add_argument("--legs", type=Path, required=True)
    command.add_argument("--execute-result", required=True)
    command.add_argument("--output", type=Path, required=True)
    for action in ("dispatch", "claims", "verify"):
        command = sub.add_parser(action)
        command.add_argument("--meta", type=Path, required=True)
        if action == "claims":
            command.add_argument("--run", required=True)
            continue
        command.add_argument("--pr", required=True)
        if action == "verify":
            command.add_argument("--base", required=True)
            command.add_argument("--head", required=True)
    command = sub.add_parser("freeze")
    command.add_argument("--brief", type=Path, required=True)
    command.add_argument("--state", type=Path, required=True)
    command.add_argument("--task", required=True)
    args = parser.parse_args()
    try:
        if args.action == "freeze":
            return freeze(args)
        if args.action == "dispatch":
            return dispatch(args)
        if args.action == "claims":
            return emit_claims(args)
        if args.action == "verify":
            return verify_evidence(args, json.load(sys.stdin))
        if args.action == "exec":
            exec_into(args.repo, args.head, json.loads(args.task), args.output.resolve())
            return 0
        if args.action == "record":
            return record_into(args.plan.resolve(), args.legs.resolve(), args.execute_result, args.output.resolve())
        raw = args.dod.read_bytes()
        items = items_from(raw.decode())
        if args.action == "plan":
            plan_into(args.repo, args.base, args.head, raw, items, args.output.resolve())
            return 0
        return run(args, raw, items)
    except (Unavailable, OSError) as exc:
        print(f"error: {json.dumps(str(exc))}\nhelp: Hosted or local evidence is unreachable; retry when it can be read.")
        return 3
    except (CheckError, ValueError, KeyError, TypeError, tarfile.TarError) as exc:
        print(f"error: {json.dumps(str(exc))}\nhelp: Supply filled criteria with Verify and an exact Check for each gate item.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
