#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -B - "$ROOT" <<'PY'
import importlib.util, json, os, subprocess, sys, tempfile
root = sys.argv[1]
spec = importlib.util.spec_from_file_location("omp_wake_turns", os.path.join(root, "tests", "omp_wake_turns.py"))
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)
def turn(stdout="", stderr="", code=0):
    return {"last": "FIRSTMATE WATCHER WAKE", "drain": {"returncode": code, "stdout": stdout, "stderr": stderr}}
row = turn("100\t7\tcheck\tkey\tcheck: queued work\n")
assert classifier.classify_turn(row) == "owed"
assert classifier.classify_turn(turn(stderr="WAKE_ACK_REQUIRED: --ack-through 0 --recovery-generation recovery")) == "empty"
assert classifier.classify_turn(turn("OPEN DECISIONS\nBRANCH OUTCOMES\n")) == "empty"
assert classifier.classify_turn(turn(code=1)) == "failed"
assert classifier.classify_turn({"last": "FIRSTMATE WATCHER WAKE"}) == "unmeasured"
assert classifier.classify_turn({"last": "ordinary captain prompt"}) == "non-wake"
unmeasured = [{"last": "FIRSTMATE WATCHER WAKE", "drain": {"returncode": 0}}]
for stdout in (None, 0, False, [], {}):
    unmeasured.append(turn(stdout))
for item in unmeasured:
    assert classifier.classify_turn(item) == "unmeasured"
with tempfile.TemporaryDirectory(prefix="fm-omp-wake-turns.") as directory:
    records = os.path.join(directory, "turns.jsonl")
    def check(turns, status):
        with open(records, "w") as handle:
            for item in turns:
                handle.write(json.dumps(item) + "\n")
        result = subprocess.run([sys.executable, "-B", os.path.join(root, "tests", "omp_wake_turns.py"), records], capture_output=True, text=True)
        assert result.returncode == status, result.stderr + result.stdout
        return json.loads(result.stdout)
    assert check([row] * 19 + [turn()], 0)["empty_percent"] == 5
    assert check([row] * 18 + [turn()], 1)["empty_percent"] > 5
    assert check([row, turn(code=1)], 1)["failed"] == 1
    assert check([{"last": "FIRSTMATE WATCHER WAKE"}], 1)["unmeasured"] == 1
    for item in unmeasured:
        report = check([row] * 19 + [item], 1)
        assert report["unmeasured"] == 1
        assert report["measured"] == 19
        assert report["empty"] == 0
        assert report["empty_percent"] == 0
print("ok - omp empty turns require successful row-free drain evidence; the shared 5% monitor rejects missing or failed evidence")
PY
