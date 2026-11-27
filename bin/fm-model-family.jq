# Shared model identity parsing for current selection and freshness checks.
def variants: ["off","minimal","low","medium","high","xhigh","max","auto","thinking","preview","latest","exp","experimental"];
def parse:
  . as $raw
  | ($raw | sub(":(off|minimal|low|medium|high|xhigh|max|auto)$"; "")) as $noeffort
  | ($noeffort | capture("(?<ctx>\\[[^\\]]*\\])$").ctx // "") as $ctx
  | ($noeffort | sub("\\[[^\\]]*\\]$"; "") | ascii_downcase | split("/")) as $parts
  | ($parts | map(select(length > 0))) as $parts
  | ($parts | last // "") as $leaf
  | ($parts[:-1] | join("/")) as $prov
  | ($leaf | split("-")) as $all
  | ($all | map(test("^[0-9]{4,}$")) | index(true)) as $date
  | (if $date == null then $all else $all[:$date] end) as $tok
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
         unadorned: ($raw == ($parts | join("/")) and $date == null and ($name | length) == 1
           and all($run[1:][]; $tok[.] | startswith("v") | not) and all($after[]; test("^[0-9]+$") | not)),
         tier: ($tierparts | join("-")),
         variant: (($name[1:]) + $after | map(select(. as $t | variants | index($t))) | join("-"))}
    end;
