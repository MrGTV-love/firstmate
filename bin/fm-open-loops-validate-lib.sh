#!/usr/bin/env bash
# fm-open-loops-validate-lib.sh - canonical validator and overdue-row projector
# for state/open-loops.json.
#
# Owned as a standalone library so both bin/fm-watch.sh and direct contract
# tests exercise the exact same jq schema check without spinning live watcher
# daemons for every malformed-JSON variant.

# Validate <ledger-path> as a single fm-open-loops.v1 JSON object and emit one
# canonical JSON array per overdue row, sorted deterministically. Returns
# non-zero and prints nothing on any schema or JSON violation.
fm_open_loops_extract_overdue_ids() {  # <ledger-path>
  local ledger=$1
  jq -rs '
    if length == 1 then .[0] else error("expected one open-loop ledger") end
    | if type == "object" and .schema == "fm-open-loops.v1"
        and (.generated_epoch | type) == "number"
        and (.home | type) == "string" and (.home | length) > 0
        and (.complete | type) == "boolean" and (.rows | type) == "array"
        and all(.rows[]; type == "object" and (.id | type) == "string"
          and (.id | length) > 0 and (.overdue | type) == "boolean"
          and (if has("current_identity") then
            (.current_identity | type == "string" and test("^[0-9a-f]{24}$")) else true end))
      then [.rows[] | select(.overdue) | [.id, .category, .subject, .owner, .next_action, .evidence]
        + (if has("current_identity") then [.current_identity] else [] end)]
        | sort | .[] | @json
      else error("invalid open-loop ledger") end
  ' "$ledger" 2>/dev/null
}
