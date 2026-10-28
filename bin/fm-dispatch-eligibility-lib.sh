#!/usr/bin/env bash
# fm-dispatch-eligibility-lib.sh - explicit hard project eligibility for
# dispatch rules.
#
# A rule may declare `"projects": {"allow": [...], "exclude": [...]}` beside
# `when`. It is then eligible only for a project named in `allow` (when that
# list is present) and absent from `exclude` (when that list is present).
# Names are exact registered names from data/projects.md: this library never
# folds case, trims, aliases, or otherwise normalizes an identity. The launch
# identity is the project directory's basename, matched against those names;
# the registry holds names, not origin-to-name mappings, so a clone whose
# directory name differs from its registered name cannot satisfy a restricted
# rule and is reported as unregistered. A rule without `projects` is
# unrestricted, which keeps every existing configuration byte-for-byte
# compatible.
# docs/configuration.md "Crew dispatch profiles" owns the declared field; this
# file owns the verdict and the identity rules every consumer applies.
#
# `when` remains natural-language judgment about task suitability. It is never
# parsed for a project restriction: a captain who needs a hard restriction
# declares it here, where the model cannot waive it.
#
# Consumers:
#   bin/fm-dispatch-resolve.sh - removes ineligible rules from the choice the
#     model sees and rejects a provider answer that still names one.
#   bin/fm-spawn.sh - rebinds the selected rule to the actual project being
#     launched, before any worktree, endpoint, or task record exists.
#   bin/fm-control.sh relaunch - rechecks a recorded rule against the actual
#     project before the old agent is stopped.
#
# Functions:
#   fm_dispatch_projects_configured <rules-file>
#     exit 0 when at least one rule declares `projects`.
#   fm_dispatch_project_identity_problem <data-dir> <name>
#     prints one problem line when the name is malformed or not registered in
#     <data-dir>/projects.md, and prints nothing when it resolves.
#   fm_dispatch_projects_config_problem <data-dir> <rules-file>
#     prints one problem line for a malformed `projects` field or an
#     unregistered declared name, and prints nothing when every declaration is
#     valid. Registry names come from bin/fm-project-mode.sh --names, the
#     registry format owner, so this library never parses data/projects.md.
#   fm_dispatch_rule_project_verdict <data-dir> <rules-file> <rule> <project>
#     exit 0 eligible, 1 ineligible, 2 configuration/identity error, 3 rule
#     absent or the rules file missing. A consumer that was given an identity
#     must refuse 3: an absent rule cannot prove the restriction it may have
#     carried. FM_DISPATCH_ELIGIBILITY_ERROR carries the one-line diagnostic.
#   fm_dispatch_rule_restricted <rules-file> <rule>
#     exit 0 when that rule exists and declares `projects`, so a caller can
#     carry the identifier through a fallback decision that would otherwise
#     clear it.
#   fm_dispatch_eligible_rules <data-dir> <rules-file> <project>
#     prints the JSON array of eligible rule ids; a configuration or identity
#     error makes it exit 2 with FM_DISPATCH_ELIGIBILITY_ERROR set.
# The verdict reads the rules file the caller has already frozen for its own
# decision, so a live edit cannot disagree with what the caller checked.
# Requires jq for every path that reads a rules file.

FM_DISPATCH_ELIGIBILITY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC2034 # Read by the sourcing resolver, spawn, and control scripts.
FM_DISPATCH_ELIGIBILITY_ERROR=''

# The one schema and matching definition, shared by every function here.
# shellcheck disable=SC2016 # jq source, not shell expansions.
FM_DISPATCH_PROJECTS_JQ='
  def project_name:
    type == "string" and length > 0 and
    (test("[[:cntrl:]]") | not) and
    . == (sub("^ +"; "") | sub(" +$"; ""));
  def name_list($value):
    ($value | type) == "array" and ($value | length) > 0 and all($value[]; project_name);
  def projects_ok:
    type == "object" and
    ((keys - ["allow", "exclude"]) | length) == 0 and
    (has("allow") or has("exclude")) and
    ((has("allow") | not) or name_list(.allow)) and
    ((has("exclude") | not) or name_list(.exclude));
  def projects_eligible($name):
    ((has("allow") | not) or (.allow | index($name) != null)) and
    ((has("exclude") | not) or (.exclude | index($name) == null));
'

fm_dispatch_projects_configured() {  # <rules-file>
  local file=$1
  [ -f "$file" ] || [ -L "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e 'any((.rules // [])[]; (type == "object") and has("projects"))' "$file" >/dev/null 2>&1
}

fm_dispatch_registered_projects() {  # <data-dir>
  local data=$1
  FM_DATA_OVERRIDE="$data" "$FM_DISPATCH_ELIGIBILITY_DIR/fm-project-mode.sh" --names 2>/dev/null
}

fm_dispatch_project_registered() {  # <data-dir> <name>
  local data=$1 name=$2 existing
  while IFS= read -r existing; do
    [ "$existing" = "$name" ] && return 0
  done < <(fm_dispatch_registered_projects "$data")
  return 1
}

fm_dispatch_project_identity_problem() {  # <data-dir> <name>
  local data=$1 name=$2
  if [ -z "$name" ]; then
    printf 'the project name is empty'
    return 0
  fi
  case "$name" in
    *[[:cntrl:]]*)
      printf 'the project name contains a control character'
      return 0
      ;;
  esac
  case "$name" in
    ' '* | *' ')
      printf 'the project name has leading or trailing whitespace'
      return 0
      ;;
  esac
  if ! fm_dispatch_project_registered "$data" "$name"; then
    printf 'project "%s" is not registered in %s/projects.md' "$name" "$data"
    return 0
  fi
  return 0
}

fm_dispatch_projects_config_problem() {  # <data-dir> <rules-file>
  local data=$1 file=$2 problem declared rule name registered found
  [ -f "$file" ] || [ -L "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || {
    printf 'jq is required to read the projects field'
    return 0
  }
  problem=$(jq -r "$FM_DISPATCH_PROJECTS_JQ"'
    [.rules // [] | to_entries[] |
      select((.value | type) == "object" and (.value | has("projects"))) |
      select((.value.projects | projects_ok) | not) |
      "rule_\(.key + 1) projects must be an object with a non-empty allow and/or exclude array of well-formed names, and no other keys"] |
    first // empty
  ' "$file" 2>/dev/null) || problem='the projects field cannot be read'
  if [ -n "$problem" ]; then
    printf '%s' "$problem"
    return 0
  fi
  declared=$(jq -r "$FM_DISPATCH_PROJECTS_JQ"'
    [.rules // [] | to_entries[] |
      select((.value | type) == "object" and (.value | has("projects"))) |
      .key as $index | .value.projects |
      ((.allow // [])[], (.exclude // [])[]) | "rule_\($index + 1)\t\(.)"] |
    .[]
  ' "$file" 2>/dev/null) || {
    printf 'the projects field cannot be read'
    return 0
  }
  [ -n "$declared" ] || return 0
  registered=$(fm_dispatch_registered_projects "$data")
  while IFS=$'\t' read -r rule name; do
    [ -n "$name" ] || continue
    found=0
    while IFS= read -r existing; do
      [ "$existing" = "$name" ] && {
        found=1
        break
      }
    done <<<"$registered"
    if [ "$found" -eq 0 ]; then
      printf '%s projects name "%s", which is not registered in %s/projects.md' "$rule" "$name" "$data"
      return 0
    fi
  done <<<"$declared"
  return 0
}

fm_dispatch_rule_project_verdict() {  # <data-dir> <rules-file> <rule> <project>
  local data=$1 file=$2 rule=$3 project=$4 state problem
  FM_DISPATCH_ELIGIBILITY_ERROR=''
  case "$rule" in
    '' | default) return 0 ;;
    rule_[1-9]*)
      case "${rule#rule_}" in
        *[!0-9]*)
          FM_DISPATCH_ELIGIBILITY_ERROR="invalid dispatch rule identity: $rule"
          return 2
          ;;
      esac
      ;;
    *)
      FM_DISPATCH_ELIGIBILITY_ERROR="invalid dispatch rule identity: $rule"
      return 2
      ;;
  esac
  [ -f "$file" ] || [ -L "$file" ] || {
    FM_DISPATCH_ELIGIBILITY_ERROR="dispatch rule $rule cannot be verified because $file is missing"
    return 3
  }
  command -v jq >/dev/null 2>&1 || {
    FM_DISPATCH_ELIGIBILITY_ERROR='jq is required to read dispatch project eligibility'
    return 2
  }
  state=$(jq -r --arg rule "$rule" "$FM_DISPATCH_PROJECTS_JQ"'
    (.rules // []) as $rules |
    ($rule | ltrimstr("rule_") | tonumber) as $index |
    if $index < 1 or $index > ($rules | length) then "absent"
    elif (($rules[$index - 1] | type) != "object") then "invalid"
    elif ($rules[$index - 1] | has("projects") | not) then "unrestricted"
    elif (($rules[$index - 1].projects | projects_ok) | not) then "invalid"
    else "restricted" end
  ' "$file" 2>/dev/null) || {
    FM_DISPATCH_ELIGIBILITY_ERROR="could not read dispatch rule project eligibility from $file"
    return 2
  }
  case "$state" in
    unrestricted) return 0 ;;
    absent)
      FM_DISPATCH_ELIGIBILITY_ERROR="dispatch rule $rule is not present in $file"
      return 3
      ;;
    invalid)
      FM_DISPATCH_ELIGIBILITY_ERROR="rule $rule declares a malformed projects field"
      return 2
      ;;
  esac
  # A restricted rule is only meaningful against a resolved identity; a typo or
  # an unregistered clone name refuses instead of matching nothing silently.
  problem=$(fm_dispatch_project_identity_problem "$data" "$project")
  if [ -n "$problem" ]; then
    FM_DISPATCH_ELIGIBILITY_ERROR=$problem
    return 2
  fi
  state=$(jq -r --arg rule "$rule" --arg project "$project" "$FM_DISPATCH_PROJECTS_JQ"'
    (.rules // []) as $rules |
    ($rule | ltrimstr("rule_") | tonumber) as $index |
    if ($rules[$index - 1].projects | projects_eligible($project)) then "eligible"
    else "ineligible" end
  ' "$file" 2>/dev/null) || {
    FM_DISPATCH_ELIGIBILITY_ERROR="could not read dispatch rule project eligibility from $file"
    return 2
  }
  if [ "$state" = eligible ]; then
    return 0
  fi
  FM_DISPATCH_ELIGIBILITY_ERROR="rule $rule is not eligible for project $project"
  return 1
}

fm_dispatch_rule_restricted() {  # <rules-file> <rule>
  local file=$1 rule=$2
  case "$rule" in
    rule_[1-9]*)
      case "${rule#rule_}" in
        *[!0-9]*) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  [ -f "$file" ] || [ -L "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e --arg rule "$rule" '
    (.rules // []) as $rules |
    ($rule | ltrimstr("rule_") | tonumber) as $index |
    $index >= 1 and $index <= ($rules | length) and
    (($rules[$index - 1] | type) == "object") and
    ($rules[$index - 1] | has("projects"))
  ' "$file" >/dev/null 2>&1
}

fm_dispatch_eligible_rules() {  # <data-dir> <rules-file> <project>
  local data=$1 file=$2 project=$3 out='[]' count index rule rc
  FM_DISPATCH_ELIGIBILITY_ERROR=''
  command -v jq >/dev/null 2>&1 || {
    FM_DISPATCH_ELIGIBILITY_ERROR='jq is required to read dispatch project eligibility'
    return 2
  }
  count=$(jq -r '(.rules // []) | length' "$file" 2>/dev/null) || {
    # shellcheck disable=SC2034 # Read by the sourcing resolver after this call.
    FM_DISPATCH_ELIGIBILITY_ERROR="could not read $file"
    return 2
  }
  for ((index = 1; index <= count; index++)); do
    rule="rule_$index"
    rc=0
    fm_dispatch_rule_project_verdict "$data" "$file" "$rule" "$project" || rc=$?
    case "$rc" in
      0) out=$(jq -c --arg rule "$rule" '. + [$rule]' <<<"$out") || return 2 ;;
      1) ;;
      *) return "$rc" ;;
    esac
  done
  printf '%s\n' "$out"
}
