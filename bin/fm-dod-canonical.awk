# Validate the defining skill's tiered Markdown criteria without rewriting them.
# action=legacy detects a legacy item; detect selects the tiered format;
# check prints every structural problem in that format.
# The caller limits input to the contract's criteria, not its grading or history.

BEGIN {
  required_count = split("Basis|Expected|Verify|Edge/negative|Evidence|Authority", required, "|")
  split(authorities, allowed, "|")
  legacy_re = "^(" legacy_id_pattern ")[ \t]+" legacy_lead ":"
  legacy_prose = legacy_prose_start
  for (i in required) known[required[i]] = 1
  for (i in allowed) allowed_set[allowed[i]] = 1
}

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

function clear_item(    k) {
  for (k in seen) delete seen[k]
  for (k in value) delete value[k]
  id = ""
  title = ""
  field = ""
  field_indent = -1
  item_indent = -1
  in_item = 0
}

function finish_item(    i, f, name, title_without_tier, mandatory, supporting, auth) {
  if (!in_item) return
  name = id == "" ? "<missing>" : id
  if (id == "") {
    print "canonical item " name " has an empty id"
    bad = 1
  } else if (id in seen_id) {
    print "canonical item id " id " is duplicated"
    bad = 1
  } else {
    seen_id[id] = 1
  }

  title_without_tier = title
  mandatory = gsub(/\*\(mandatory\)\*/, "", title_without_tier)
  supporting = gsub(/\*\(supporting\)\*/, "", title_without_tier)
  if (mandatory + supporting != 1) {
    print "canonical item " name " needs exactly one mandatory or supporting tier"
    bad = 1
  } else if (mandatory == 1) {
    mandatory_count++
  }
  if (trim(title_without_tier) == "") {
    print "canonical item " name " has an empty outcome"
    bad = 1
  }

  for (i = 1; i <= required_count; i++) {
    f = required[i]
    if (!(f in seen)) {
      print "canonical item " name " is missing " f
      bad = 1
    } else if (trim(value[f]) == "") {
      print "canonical item " name " has an empty " f
      bad = 1
    }
  }
  auth = trim(value["Authority"])
  gsub(/[.;,]+$/, "", auth)
  if (auth != "" && !(tolower(auth) in allowed_set)) {
    print "canonical item " name " has invalid Authority " auth
    bad = 1
  }
  clear_item()
}

{
  sub(/\r$/, "", $0)
  line = $0
  s = trim(line)
  indent = match(line, /[^ \t]/) - 1
  marker = substr(s, 1, 1)
  marker_len = 0
  if (marker == "`" || marker == "~") {
    while (substr(s, marker_len + 1, 1) == marker) marker_len++
  }
  if (marker_len >= 3) {
    rest = substr(s, marker_len + 1)
    if (!in_fence) {
      in_fence = 1
      fence_marker = marker
      fence_len = marker_len
    } else if (marker == fence_marker && marker_len >= fence_len && rest ~ /^[[:space:]]*$/) {
      in_fence = 0
    }
    next
  }
  if (in_fence) {
    if (action == "check" && in_item && field != "" && field != "Authority") value[field] = value[field] " " s
    next
  }
  if (s == "") next

  # Never count an example in grading, assumptions, or review history.
  if (indent <= 3 && s ~ /^##[ \t]/ && s != "## Definition Of Done" && s != "## Definition Of Done (task)") exit

  if (action == "legacy") {
    legacy_probe = s
    sub(/^[-+*][ \t]+/, "", legacy_probe)
    if (indent <= 3 && legacy_probe ~ legacy_re) {
      found = 1
      exit
    }
    next
  }
  if (action == "detect") {
    if (s == "### Mandatory items") {
      legacy_prose = 0
      legacy_item_open = 0
    } else if (s ~ /^###([ \t]|$)/) {
      legacy_prose = legacy_mode
      legacy_item_open = 0
    }
    legacy_probe = s
    sub(/^[-+*][ \t]+/, "", legacy_probe)
    if (legacy_mode && !legacy_prose && legacy_probe ~ legacy_re) {
      legacy_item_open = 1
      legacy_item_indent = indent
    }
    # Indented content inside a legacy item is not a sibling criterion.
    # A pending sibling's wrapped tier still belongs to that sibling.
    if (legacy_item_open && indent > legacy_item_indent \
        && !(pending_plain && indent > pending_indent && s ~ /^\*\(mandatory\)\*/)) next
  }

  # A wrapped tier on a non-bold sibling still denotes a malformed item.
  if (pending_plain && indent > pending_indent && s ~ /^\*\((mandatory|supporting)\)\*([ \t]|$)/) {
    if (action == "detect" && s ~ /^\*\(mandatory\)\*/) {
      found = 1
      exit
    }
    if (action == "check") {
      finish_item()
      print "canonical tiered item has no bold id"
      bad = 1
      pending_plain = 0
      next
    }
  }
  if (s ~ /^[-+*][ \t]+/ && s !~ /^[-+*][ \t]+\*\*/ && (action == "detect" || !in_item || indent <= item_indent)) {
    pending_plain = 1
    pending_indent = indent
  } else if (pending_plain && indent <= pending_indent) {
    pending_plain = 0
  }

  # Criterion items are siblings; deeper bold bullets are field content.
  if (s ~ /^[-+*][ \t]+\*\*/ && (action == "detect" || !in_item || indent <= item_indent)) {
    if (action == "detect") {
      detecting_item = 1
      detecting_indent = indent
      if (s ~ /\*\(mandatory\)\*/ || (s ~ /\*\(supporting\)\*/ && !legacy_prose)) {
        found = 1
        exit
      }
      next
    }
    finish_item()
    rest = s
    sub(/^[-+*][ \t]+\*\*/, "", rest)
    end_id = index(rest, "**")
    if (end_id == 0) {
      print "canonical item has an unterminated id"
      bad = 1
      next
    }
    id = trim(substr(rest, 1, end_id - 1))
    title = trim(substr(rest, end_id + 2))
    item_indent = indent
    in_item = 1
    next
  }
  if (action == "detect") {
    if (s ~ /^#{1,6}([ \t]|$)/ && indent <= detecting_indent) detecting_item = 0
    if (s ~ /^[-+*][ \t]+/ && s ~ /\*\(mandatory\)\*/) {
      found = 1
      exit
    }
    if (detecting_item) {
      probe = s
      sub(/^[-+*][ \t]+/, "", probe)
      colon = index(probe, ":")
      label = colon > 0 ? trim(substr(probe, 1, colon - 1)) : ""
      if (s ~ /\*\(mandatory\)\*/ || (!legacy_prose && (s ~ /\*\(supporting\)\*/ || label in known))) {
        found = 1
        exit
      }
    }
    next
  }

  if (s ~ /^[-+*][ \t]+/ && s ~ /\*\((mandatory|supporting)\)\*/ && (!in_item || indent <= item_indent)) {
    finish_item()
    print "canonical tiered item has no bold id"
    bad = 1
    pending_plain = 0
    next
  }

  # Mixing representations could otherwise let one parser ignore items.
  legacy = s
  sub(/^[-+*][ \t]+/, "", legacy)
  if (legacy ~ legacy_re && (!in_item || indent <= item_indent)) {
    finish_item()
    print "canonical and legacy criteria cannot be mixed in one contract"
    bad = 1
    next
  }
  if (s ~ /^#{1,6}([ \t]|$)/ && (!in_item || indent <= item_indent)) {
    finish_item()
    next
  }

  entry = s
  sub(/^[-+*][ \t]+/, "", entry)
  colon = index(entry, ":")
  label = colon > 0 ? trim(substr(entry, 1, colon - 1)) : ""
  if (label in known && (!in_item || field == "" || indent <= field_indent)) {
    if (!in_item) {
      print "canonical field " label " has no item"
      bad = 1
      next
    }
    if (label in seen) {
      print "canonical item " id " repeats " label
      bad = 1
    }
    seen[label] = 1
    value[label] = trim(substr(entry, colon + 1))
    field = label
    field_indent = indent
    next
  }
  if (in_item && field == "") title = title " " s
  else if (in_item && field != "Authority") value[field] = value[field] " " s
}

END {
  if (action == "detect" || action == "legacy") exit !found
  finish_item()
  if (mandatory_count == 0) {
    print "canonical contract has no mandatory item"
    bad = 1
  }
  exit !bad
}
