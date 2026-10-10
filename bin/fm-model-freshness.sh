#!/usr/bin/env bash
# fm-model-freshness.sh - report a worker or reviewer model that a newer model of
# the same family has passed in its own harness's catalog.
# Usage: fm-model-freshness.sh scan
#          Check every model named in this home's config/crew-dispatch.json.
#          Silent when that file is absent or every model is current.
#        fm-model-freshness.sh check <harness> <model>
#          Check one requested model; bin/fm-spawn.sh calls it for the model it
#          is about to launch.
# Output: one line on stdout per stale model, nothing else:
#   MODEL_FRESHNESS: <model> on <harness> is older than <newer> in the <harness> catalog[ (other tier: <tier>)]
# Notices (a catalog that could not be read) go to stderr as
#   model-freshness: notice: <detail>
# The check is advisory. It exits 0 whatever it finds, refuses nothing, and
# writes no config file; the supervisor decides. Exit 2 is a malformed call.
#
# What stale means. The model id is split into a family (its leading name, such
# as gemini, gpt, claude, glm), a version (the first run of numeric parts, so
# 3.1, 6.1 and the claude-sonnet-5-5 spelling of 5.5 all compare as numbers), a
# tier (pro, flash, sonnet, sol, ...) and an effort variant (high, low, ...).
# A model is stale when its own harness catalog lists a model of the same
# family, from the same provider prefix, whose version is higher. The newer
# model named is the same tier when one exists, otherwise the highest version
# of any tier, because a newer generation of a family replaces an older one
# across tiers (gemini-3.8-flash-high is newer than gemini-3.1-pro-high).
# Never inferred from a name: the catalog is read from the harness's own
# discovery command (bin/fm-model-catalog-lib.sh owns them and their time
# limits), and an id the harness keeps current - an alias with no version in
# it, such as opus - is current by definition. A harness without a readable
# catalog is reported as a notice, never guessed.
#
# Catalogs are read in the caller's environment. bin/fm-spawn.sh runs the check
# under the worker account pin, so a pinned Claude account answers for itself;
# a session-start scan reads the supervisor's own account.
# FM_MODEL_CATALOG_DIR supplies catalog exports (and test fixtures) exactly as
# for bin/fm-model-index.sh. FM_HOME / FM_CONFIG_OVERRIDE select the config.
# FM_MODEL_FRESHNESS=0 turns the check off (tests that run no catalog).
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-model-catalog-lib.sh
. "$SCRIPT_DIR/fm-model-catalog-lib.sh"

usage() { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; }
notice() { printf 'model-freshness: notice: %s\n' "$*" >&2; }
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
case "${1:-}:$#" in scan:1|check:3) ;; *) usage >&2; exit 2 ;; esac
[ "${FM_MODEL_FRESHNESS:-1}" != 0 ] || exit 0
command -v jq >/dev/null 2>&1 || { notice 'jq is required; nothing checked'; exit 0; }
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-freshness.XXXXXX") || { notice 'mktemp failed; nothing checked'; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# <harness>\t<model> pairs to check, unique, one per line, in $TMP/pairs.
if [ "$1" = check ]; then
  printf '%s\t%s\n' "$2" "$3" > "$TMP/pairs"
else
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || exit 0
  # Role references resolve offline through the model index; a file the index
  # refuses (or a home without an index) still yields its literal models.
  resolved=$("$SCRIPT_DIR/fm-model-index.sh" profiles "$file" 2>/dev/null) || resolved=$(cat "$file")
  jq -r '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    [ ((.rules // [])[]? | profiles(.use?)[]?), (if has("default") then profiles(.default)[]? else empty end) ]
    | map(select(type == "object" and (.harness | type) == "string" and (.model | type) == "string" and (.model | length) > 0))
    | map([.harness, .model] | @tsv) | unique[]' <<< "$resolved" > "$TMP/pairs" 2>/dev/null \
    || { notice "could not read models from $file; nothing checked"; exit 0; }
fi
[ -s "$TMP/pairs" ] || exit 0

# One catalog per harness, read concurrently so the slowest one sets the wall
# clock instead of their sum.
cut -f1 "$TMP/pairs" | sort -u > "$TMP/harnesses"
while IFS= read -r harness; do
  (
    if fm_model_catalog "$harness" "$TMP" > "$TMP/catalog-$harness.json" 2>/dev/null </dev/null \
      && fm_model_catalog_valid "$TMP/catalog-$harness.json"; then
      :
    else
      rm -f "$TMP/catalog-$harness.json"
    fi
  ) &
done < "$TMP/harnesses"
wait

# shellcheck disable=SC2016 # jq program: $-names are jq variables.
FRESHNESS_JQ='
  def variants: ["off","minimal","low","medium","high","xhigh","max","auto","thinking","preview","latest","exp","experimental"];
  def parse:
    . as $raw
    | ($raw | sub(":(off|minimal|low|medium|high|xhigh|max|auto)$"; "")) as $noeffort
    | ($noeffort | capture("(?<ctx>\\[[^\\]]*\\])$").ctx // "") as $ctx
    | ($noeffort | sub("\\[[^\\]]*\\]$"; "") | ascii_downcase | split("/")) as $parts
    | ($parts | map(select(length > 0))) as $parts
    | ($parts | last // "") as $leaf
    | ($parts[:-1] | join("/")) as $prov
    | ($leaf | split("-")) as $tok
    | ($tok | map(test("^v?[0-9]{1,3}(\\.[0-9]{1,3})*$"))) as $isv
    | ($isv | index(true)) as $first
    | if $first == null then {raw: $raw, version: [], prov: $prov}
      else
        (reduce range($first; ($tok | length)) as $i ({run: [], open: true};
            if .open and $isv[$i] then .run += [$i] else .open = false end) | .run) as $run
        | ($run | map($tok[.] | ltrimstr("v") | split(".") | map(tonumber)) | add) as $version
        | ($tok[:$first]) as $name
        | ($tok[($run | last) + 1:]) as $after
        | (($name[1:]) + $after | map(select((. as $t | variants | index($t) | not) and (test("^[0-9]+$") | not)))) as $tierparts
        | {raw: $raw, version: $version, prov: $prov, family: ($name[0] // ""), ctx: $ctx,
           tier: ($tierparts | join("-")),
           variant: (($name[1:]) + $after | map(select(. as $t | variants | index($t))) | join("-"))}
      end;
  ($cfg | parse) as $c
  | if ($c.version | length) == 0 or ($c.family // "") == "" then empty
    else
      [ .models[] | .id | select(type == "string") | parse
        | select(.family == $c.family and .prov == $c.prov and (.version | length) > 0 and .version > $c.version) ] as $newer
      | if ($newer | length) == 0 then empty
        else
          ([ $newer[] | select(.tier == $c.tier) ]) as $same
          | (if ($same | length) > 0 then $same else $newer end) as $pool
          | ($pool | map(.version) | max) as $best
          | ($pool | map(select(.version == $best))
              | sort_by([(.variant != $c.variant), (.ctx != $c.ctx)]) | .[0]) as $pick
          | [$pick.raw, (if $pick.tier != $c.tier then $pick.tier else "" end)] | @tsv
        end
    end'

while IFS=$'\t' read -r harness model; do
  [ -n "$harness" ] && [ -n "$model" ] || continue
  if [ ! -f "$TMP/catalog-$harness.json" ]; then
    notice "$harness catalog unavailable (no readable listing or FM_MODEL_CATALOG_DIR export); '$model' not checked"
    continue
  fi
  found=$(jq -r --arg cfg "$model" "$FRESHNESS_JQ" "$TMP/catalog-$harness.json" 2>/dev/null) || {
    notice "$harness catalog could not be compared; '$model' not checked"
    continue
  }
  [ -n "$found" ] || continue
  newer=${found%%$'\t'*}
  tier=${found#*$'\t'}
  [ -z "$tier" ] || tier=" (other tier: $tier)"
  printf 'MODEL_FRESHNESS: %s on %s is older than %s in the %s catalog%s\n' "$model" "$harness" "$newer" "$harness" "$tier"
done < "$TMP/pairs"
exit 0
