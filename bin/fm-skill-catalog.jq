# Parse the repository's simple skill frontmatter without evaluating YAML.
# Reject unsupported scalar forms rather than guessing or shortening descriptions.
def scalar:
  if startswith("\"") then fromjson
  elif startswith("'") and endswith("'") then .[1:-1] | gsub("''"; "'")
  elif test("^[^\\[\\]{}&*!|>]+$") then .
  else error("unsupported frontmatter scalar") end;
gsub("\r\n"; "\n")
| capture("\\A---\\r?\\n(?<meta>[\\s\\S]*?)\\r?\\n---\\r?\\n(?<body>[\\s\\S]*)\\z") as $file
| ($file.meta | [scan("(?m)^name:[ \\t]*([^\\r\\n]+)$")] | if length == 1 then .[0][0] | scalar else error("ambiguous skill name") end) as $id
| if ($id | type) != "string" then error("invalid skill name")
  elif ($id | test("^[a-z0-9]+(-[a-z0-9]+)*$") | not) then error("invalid skill name")
  elif $ARGS.named.mode == "identity" then {id:$id,path:$path}
  else
  ($file.meta + "\n" | capture("(?m)^description:[ \\t]*(?<value>[^\\r\\n]*)\\r?\\n(?<continuation>(?:(?:[ \\t]*\\r?\\n)*[ \\t]+[^\\r\\n]*\\r?\\n)*)")) as $description
| ($description.value | sub("[ \\t]+$"; "")) as $value
| (if [">", ">-", "|", "|-"] | index($value) then
    $description.continuation | split("\n") | map(sub("^[ \\t]+"; "")) | join(if $value | startswith(">") then " " else "\n" end) | sub("\\s+$"; "")
  elif $description.continuation != "" then error("unsupported multiline scalar")
  else $value | scalar end) as $text
| if ($text | length) > 0 then
    {id: $id, description: $text, path: $path, body_hash: $ARGS.named.body_hash, excerpt: $file.body[0:700]}
  else error("invalid skill metadata") end
  end
