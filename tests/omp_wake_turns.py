import argparse
import json
import sys


def classify_turn(turn):
    if "FIRSTMATE WATCHER WAKE" not in turn.get("last", ""):
        return "non-wake"
    drain = turn.get("drain")
    if not isinstance(drain, dict):
        return "unmeasured"
    if drain.get("returncode") != 0:
        return "failed"
    for line in drain.get("stdout", "").splitlines():
        fields = line.split("\t")
        if (len(fields) >= 5 and fields[0].isdigit() and fields[1].isdigit()
                and fields[2] in ("signal", "stale", "check", "heartbeat")):
            return "owed"
    return "empty"


def summarize(turns):
    counts = {kind: 0 for kind in ("owed", "empty", "failed", "unmeasured")}
    for turn in turns:
        kind = classify_turn(turn)
        if kind in counts:
            counts[kind] += 1
    measured = counts["owed"] + counts["empty"]
    return dict(counts, measured=measured,
                empty_percent=100 * counts["empty"] / measured if measured else 0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("turns", help="JSONL turn records containing last and drain returncode/stdout/stderr")
    parser.add_argument("--max-empty-percent", type=float, default=5)
    args = parser.parse_args()
    with open(args.turns) as handle:
        report = summarize(json.loads(line) for line in handle if line.strip())
    print(json.dumps(report, sort_keys=True))
    return int(bool(report["failed"] or report["unmeasured"]
                    or report["empty_percent"] > args.max_empty_percent))


if __name__ == "__main__":
    sys.exit(main())
