#!/usr/bin/env bash
# fm-reconciled-source-lib.sh - the declaration and approval-evidence half of a
# reconciled-successor local-only source (bin/fm-spawn.sh --reconciled-source).
# Sourced by bin/fm-spawn.sh and bin/fm-brief.sh; requires python3.
#
# A reconciled successor is an explicitly approved immutable commit S, on a
# direct non-default PROJECT branch, that contains BOTH the named local default
# and the freshly discovered remote default. bin/fm-spawn.sh owns discovery,
# containment, the PROJECT lock and both locked checkpoints; this library only
# reads and judges the declaration and its approval evidence, once per attempt,
# and re-proves at each checkpoint that the bytes it judged are still the bytes
# on disk. It keeps no state on disk: an interrupted or refused attempt leaves
# nothing for the next attempt to consume or trip over.
#
# Declaration (strict JSON, every key required, no other key, no duplicate key):
#   {"version": 1, "task": "<task-id>", "project": "<absolute project path>",
#    "source_ref": "refs/heads/<branch>", "source_sha": "<full commit id>",
#    "source_tree": "<full tree id>",
#    "proposal_path": "<absolute path>", "proposal_sha256": "<64 hex>",
#    "response_path": "<absolute path>", "response_sha256": "<64 hex>"}
# Proposal (strict JSON): {"schema": "fm-reconciled-source-proposal/1",
#    "grant": "reconciled-source-admission", "task", "project", "source_ref",
#    "source_sha", "source_tree", "text"}: the versioned question put to the
#    human, naming the exact S, tree, project, task and source branch.
# Response (strict JSON): {"schema": "fm-reconciled-source-response/1",
#    "proposal_sha256": "<the proposal's own hash>", "answer": "<verbatim human
#    answer>", "disposition": "affirmative|declined|unclear",
#    "recorded_by": "<who authenticated the channel>",
#    "conflicting_decisions": [<known unresolved conflicting or superseding
#    decisions in the current authority context; must be empty>]}
# The human answer is kept verbatim; no magic wording is required. Parent, who
# authenticated the channel, records the disposition. Only an affirmative
# disposition that answers this exact proposal, with no known conflicting
# decision, and whose proposal names the same S, tree, project, task and source
# branch as the declaration and the ACTUAL invocation, authorizes the source.
# This judges recorded authority; it does not resist deliberate forgery of the
# controller's own records.
#
# fm_reconciled_source_capture <declaration> <task-id> <project-dir>
#   Reads each file's bytes once, validates them from those same bytes and, on
#   success, sets FM_RS_DECL_SHA256 FM_RS_PROPOSAL_SHA256 FM_RS_RESPONSE_SHA256
#   FM_RS_EVIDENCE_SHA256 FM_RS_SOURCE_REF FM_RS_SOURCE_SHA FM_RS_SOURCE_TREE
#   FM_RS_DECL_PATH FM_RS_PROPOSAL_PATH FM_RS_RESPONSE_PATH. Returns 1 with
#   FM_RS_ERROR set to one line naming the refused mechanism (printed by the caller).
# fm_reconciled_source_recheck
#   Re-hashes the declaration, proposal and response paths captured above and
#   returns 1 unless every one still has its captured bytes.

# shellcheck disable=SC2034 # Output globals consumed by the sourcing entrypoints.
fm_reconciled_source_reset() {
  FM_RS_DECL_SHA256=''
  FM_RS_PROPOSAL_SHA256=''
  FM_RS_RESPONSE_SHA256=''
  FM_RS_EVIDENCE_SHA256=''
  FM_RS_SOURCE_REF=''
  FM_RS_SOURCE_SHA=''
  FM_RS_SOURCE_TREE=''
  FM_RS_DECL_PATH=''
  FM_RS_PROPOSAL_PATH=''
  FM_RS_RESPONSE_PATH=''
  FM_RS_ERROR=''
}
fm_reconciled_source_reset

# shellcheck disable=SC2034 # Output globals consumed by the sourcing entrypoints.
fm_reconciled_source_capture() { # <declaration> <task-id> <project-dir>
  local decl=$1 task=$2 project=$3 out line key value
  fm_reconciled_source_reset
  command -v python3 >/dev/null 2>&1 || {
    FM_RS_ERROR='reconciled source refused: python3 is needed to read the declaration'
    return 1
  }
  if ! out=$(python3 -I - "$decl" "$task" "$project" 2>&1 <<'PY'
import hashlib, json, os, re, sys

def refuse(msg):
    print("reconciled source refused: " + msg)
    sys.exit(1)

def strict(raw, what):
    def pairs(items):
        seen = {}
        for k, v in items:
            if k in seen:
                refuse(what + " repeats key " + json.dumps(k))
            seen[k] = v
        return seen
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        refuse(what + " is not UTF-8 text")
    try:
        value = json.loads(text, object_pairs_hook=pairs)
    except ValueError as exc:
        refuse(what + " is not valid JSON (" + str(exc) + ")")
    if not isinstance(value, dict):
        refuse(what + " must be one JSON object")
    return value

def read_once(path, what):
    if not isinstance(path, str) or not os.path.isabs(path):
        refuse(what + " path must be absolute")
    try:
        with open(path, "rb") as fh:
            raw = fh.read()
    except OSError as exc:
        refuse("cannot read " + what + " " + path + " (" + exc.strerror + ")")
    return raw, hashlib.sha256(raw).hexdigest()

def exact_keys(obj, keys, what):
    have = set(obj)
    missing = sorted(set(keys) - have)
    extra = sorted(have - set(keys))
    if missing:
        refuse(what + " is missing " + ", ".join(missing))
    if extra:
        refuse(what + " has unsupported key " + ", ".join(extra))

OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
REF = re.compile(r"^refs/heads/[^\s~^:?*\[\\]+$")

decl_path, task, project = sys.argv[1], sys.argv[2], sys.argv[3]
if not os.path.isabs(decl_path):
    decl_path = os.path.abspath(decl_path)
decl_raw, decl_sha = read_once(decl_path, "declaration")
d = strict(decl_raw, "declaration")
exact_keys(d, ["version", "task", "project", "source_ref", "source_sha", "source_tree",
               "proposal_path", "proposal_sha256", "response_path", "response_sha256"], "declaration")
if d["version"] != 1 or isinstance(d["version"], bool):
    refuse("declaration version " + json.dumps(d["version"]) + " is unsupported (expected 1)")
for k in ("task", "project", "source_ref", "source_sha", "source_tree",
          "proposal_path", "proposal_sha256", "response_path", "response_sha256"):
    if not isinstance(d[k], str) or not d[k]:
        refuse("declaration " + k + " must be a non-empty string")
for k in ("source_sha", "source_tree"):
    if not OID.match(d[k]):
        refuse("declaration " + k + " must be a full lowercase object id, not " + json.dumps(d[k]))
for k in ("proposal_sha256", "response_sha256"):
    if not HEX64.match(d[k]):
        refuse("declaration " + k + " must be a full sha256 digest")
if not REF.match(d["source_ref"]):
    refuse("declaration source_ref must be a direct refs/heads/<branch> name, not " + json.dumps(d["source_ref"]))
if not os.path.isabs(d["project"]):
    refuse("declaration project must be an absolute path")
actual_project = os.path.realpath(project)
if d["task"] != task:
    refuse("declaration names task " + json.dumps(d["task"]) + " but this invocation is task " + json.dumps(task))
if os.path.realpath(d["project"]) != actual_project:
    refuse("declaration names project " + d["project"] + " but this invocation's project resolves to " + actual_project)

p_raw, p_sha = read_once(d["proposal_path"], "proposal")
r_raw, r_sha = read_once(d["response_path"], "response")
if p_sha != d["proposal_sha256"]:
    refuse("proposal bytes do not match the declared proposal_sha256")
if r_sha != d["response_sha256"]:
    refuse("response bytes do not match the declared response_sha256")
p = strict(p_raw, "proposal")
exact_keys(p, ["schema", "grant", "task", "project", "source_ref", "source_sha", "source_tree", "text"], "proposal")
if p["schema"] != "fm-reconciled-source-proposal/1":
    refuse("proposal schema " + json.dumps(p["schema"]) + " is unsupported")
if p["grant"] != "reconciled-source-admission":
    refuse("proposal grants " + json.dumps(p["grant"]) + ", not reconciled-source admission of a named successor")
if not isinstance(p["text"], str) or not p["text"].strip():
    refuse("proposal carries no question text")
for k in ("task", "source_ref", "source_sha", "source_tree"):
    if p[k] != d[k]:
        refuse("approved proposal " + k + " " + json.dumps(p[k]) + " differs from the declaration's " + json.dumps(d[k]))
if not isinstance(p["project"], str) or os.path.realpath(p["project"]) != actual_project:
    refuse("approved proposal project does not resolve to this invocation's project " + actual_project)
r = strict(r_raw, "response")
exact_keys(r, ["schema", "proposal_sha256", "answer", "disposition", "recorded_by", "conflicting_decisions"], "response")
if r["schema"] != "fm-reconciled-source-response/1":
    refuse("response schema " + json.dumps(r["schema"]) + " is unsupported")
if r["proposal_sha256"] != p_sha:
    refuse("response does not answer this exact proposal (its proposal_sha256 names other bytes)")
if not isinstance(r["answer"], str) or not r["answer"].strip():
    refuse("response records no verbatim human answer")
if not isinstance(r["recorded_by"], str) or not r["recorded_by"].strip():
    refuse("response does not name who authenticated the answer's channel")
if r["disposition"] != "affirmative":
    refuse("recorded human disposition is " + json.dumps(r["disposition"]) + ", not an affirmative authorization")
if not isinstance(r["conflicting_decisions"], list):
    refuse("response conflicting_decisions must be a list")
if r["conflicting_decisions"]:
    refuse("the authority context records an unresolved conflicting or superseding decision; Parent must resolve it first")
evidence = hashlib.sha256((decl_sha + "\n" + p_sha + "\n" + r_sha + "\n").encode()).hexdigest()
for k, v in (("DECL_SHA256", decl_sha), ("PROPOSAL_SHA256", p_sha), ("RESPONSE_SHA256", r_sha),
             ("EVIDENCE_SHA256", evidence), ("SOURCE_REF", d["source_ref"]), ("SOURCE_SHA", d["source_sha"]),
             ("SOURCE_TREE", d["source_tree"]), ("DECL_PATH", decl_path),
             ("PROPOSAL_PATH", d["proposal_path"]), ("RESPONSE_PATH", d["response_path"])):
    if "\n" in v:
        refuse("declaration value for " + k + " contains a newline")
    print(k + "=" + v)
PY
  ); then
    FM_RS_ERROR=$(printf '%s\n' "$out" | tail -n 1)
    [ -n "$FM_RS_ERROR" ] || FM_RS_ERROR='reconciled source refused: the declaration could not be read'
    return 1
  fi
  while IFS= read -r line; do
    key=${line%%=*}
    value=${line#*=}
    case $key in
    DECL_SHA256) FM_RS_DECL_SHA256=$value ;;
    PROPOSAL_SHA256) FM_RS_PROPOSAL_SHA256=$value ;;
    RESPONSE_SHA256) FM_RS_RESPONSE_SHA256=$value ;;
    EVIDENCE_SHA256) FM_RS_EVIDENCE_SHA256=$value ;;
    SOURCE_REF) FM_RS_SOURCE_REF=$value ;;
    SOURCE_SHA) FM_RS_SOURCE_SHA=$value ;;
    SOURCE_TREE) FM_RS_SOURCE_TREE=$value ;;
    DECL_PATH) FM_RS_DECL_PATH=$value ;;
    PROPOSAL_PATH) FM_RS_PROPOSAL_PATH=$value ;;
    RESPONSE_PATH) FM_RS_RESPONSE_PATH=$value ;;
    esac
  done <<EOF
$out
EOF
  [ -n "$FM_RS_EVIDENCE_SHA256" ] && [ -n "$FM_RS_SOURCE_SHA" ] || {
    FM_RS_ERROR='reconciled source refused: the declaration capture was incomplete'
    return 1
  }
}

# fm_rs_file_sha256 <path> - sha256 of the file's current bytes, or nothing.
fm_rs_file_sha256() {
  [ -f "$1" ] || return 1
  shasum -a 256 <"$1" 2>/dev/null | awk '{print $1}'
}

fm_reconciled_source_recheck() {
  local now
  now=$(fm_rs_file_sha256 "$FM_RS_DECL_PATH") || now=
  [ -n "$now" ] && [ "$now" = "$FM_RS_DECL_SHA256" ] || {
    echo "error: reconciled source refused: the declaration changed after this attempt judged it" >&2
    return 1
  }
  now=$(fm_rs_file_sha256 "$FM_RS_PROPOSAL_PATH") || now=
  [ -n "$now" ] && [ "$now" = "$FM_RS_PROPOSAL_SHA256" ] || {
    echo "error: reconciled source refused: the approval proposal changed after this attempt judged it" >&2
    return 1
  }
  now=$(fm_rs_file_sha256 "$FM_RS_RESPONSE_PATH") || now=
  [ -n "$now" ] && [ "$now" = "$FM_RS_RESPONSE_SHA256" ] || {
    echo "error: reconciled source refused: the approval response changed after this attempt judged it" >&2
    return 1
  }
}
