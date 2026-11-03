# Adversarial parity check: for many crafted intents with an expired stamp,
# the prune's fm_mp_commit_intent_spent must never say "spent" for a payload
# that Vernant's reader static checks refuse. Reader functions below are copied
# verbatim from scripts/hooks/commit_intent.py (slot 93, read only); the git
# binding and the "expired => refuse" rule are left out on purpose.
import json, os, subprocess, sys, tempfile, random, itertools
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

class CommitIntentError(ValueError): pass

def _normalize_repo_path(path):
    raw = Path(path).as_posix()
    if raw.startswith("./"): raw = raw[2:]
    pure = PurePosixPath(raw)
    if pure.is_absolute() or any(part == ".." for part in pure.parts):
        raise CommitIntentError("not repo-relative")
    normalized = pure.as_posix()
    if normalized in ("", "."): raise CommitIntentError("empty")
    return normalized

def _coerce_string_list(payload, field):
    value = payload.get(field)
    if not isinstance(value, list) or not value: raise CommitIntentError(field)
    if not all(isinstance(item, str) and item.strip() for item in value): raise CommitIntentError(field)
    return tuple(item.strip() for item in value)

def _parse_expiry(value):
    if not isinstance(value, str) or not value.strip(): raise CommitIntentError("exp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None: raise CommitIntentError("tz")
    return parsed.astimezone(UTC)

def reader_static_ok(payload):
    try:
        if not isinstance(payload, dict): return False
        if payload.get("artifacttype") != "CommitIntent": return False
        for k in ("schemaversion", "branch", "head_sha"):
            v = payload.get(k)
            if not isinstance(v, str) or not v.strip(): return False
        tuple(_normalize_repo_path(i) for i in _coerce_string_list(payload, "owned_paths"))
        _coerce_string_list(payload, "validators")
        _parse_expiry(payload.get("expires_at_iso"))
        return True
    except (CommitIntentError, ValueError, TypeError):
        return False

base = {"artifacttype": "CommitIntent", "schemaversion": "1", "branch": "fm/x", "head_sha": "abc",
        "owned_paths": ["src/a.py"], "validators": ["pytest"], "expires_at_iso": "2000-01-01T00:00:00+00:00"}
values = {
  "artifacttype": ["CommitIntent", "commitintent", "", None, 1],
  "schemaversion": ["1", "", " ", None, 2],
  "branch": ["fm/x", "", "  ", None, ["fm/x"]],
  "head_sha": ["abc", "", " ", None],
  "owned_paths": [["src/a.py"], [], [" "], [""], ["/etc"], ["../x"], ["a/../b"], ["./"], ["."], ["./src"], [1], "src", None, ["ok", "/abs"], ["ok", ""]],
  "validators": [["pytest"], [], [""], [" "], [None], "pytest", None, ["a", 3]],
  "expires_at_iso": ["2000-01-01T00:00:00+00:00", "2000-01-01 00:00:00+00:00", "2000-01-01T00:00:00Z",
                     "2000-01-01T00:00:00", "2000-01-01", "2000-01-01T00:00+00:00", "2000-01-01T00:00:00+0000",
                     "2000-01-01T00:00:00.123456+05:30", "2000-13-01T00:00:00+00:00", "nope", "", None, 946684800],
}
lib = sys.argv[1]
rows = []
for key, vals in values.items():
    for v in vals:
        p = dict(base); p[key] = v
        rows.append((f"{key}={json.dumps(v)}", p))
for key in values:  # missing key
    p = dict(base); del p[key]; rows.append((f"{key} missing", p))
rows += [("array", [base]), ("string", "x"), ("null", None)]
random.seed(7)
for i in range(150):  # random mixes
    p = {k: random.choice(v) for k, v in values.items()}
    rows.append((f"mix{i}", p))
bad = 0; agree = 0; narrower = 0
d = tempfile.mkdtemp()
for label, payload in rows:
    f = os.path.join(d, "commit-intent.json")
    with open(f, "w") as h: json.dump(payload, h)
    r = subprocess.run(["bash", "-c", '. "$1" >/dev/null 2>&1; FM_MP_TASK_BRANCH= fm_mp_commit_intent_spent "$2"', "_", lib, f])
    prune_spent = r.returncode == 0
    reader = reader_static_ok(payload)
    if prune_spent and not reader:
        bad += 1; print(f"VIOLATION prune=spent reader=refuse {label}")
    elif prune_spent == reader:
        agree += 1
    else:
        narrower += 1; print(f"narrower prune=keep reader=valid {label}")
print(f"cases={len(rows)} agree={agree} prune-narrower={narrower} violations={bad}")
sys.exit(1 if bad else 0)
