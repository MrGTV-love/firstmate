#!/bin/bash
# dd2.sh <lib-root>: paired dedup cases through the real writer. Prints one block per case.
set -u
L=$1; S=/tmp/fmlive
mk(){ # <file> <body> [ff]
  mkdir -p "$(dirname "$1")"
  if [ "${3:-}" = ff ]; then printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\ndelivery=fire-and-forget\n--\n%s' "$2" > "$1"
  else printf 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n--\n%s' "$2" > "$1"; fi
}
case_run(){ # <name> <mode-seed-spec> <text> [delivery]
  name=$1; seedfn=$2; text=$3; mode=${4:-}
  st=$(mktemp -d /tmp/fmlive/dd2.XXXX); inbox=$st/t.inbox; mkdir -p "$inbox/handled"
  $seedfn "$inbox"
  out=$(bash "$S/call.sh" "$L" "$st" t "$text" "$mode" 2>"$st/err"); rc=$?
  echo "### $name"
  echo "rc=$rc printed=${out#$inbox/}"
  [ ! -s "$st/err" ] || echo "stderr: $(head -c 300 "$st/err")"
  (cd "$inbox" && for f in *.msg handled/*.msg; do [ -e "$f" ] || continue; echo "-- $f"; sed -e '/^at=/d' "$f" | cut -c1-120; echo; done)
  ls -A "$inbox" | grep -v '\.msg$\|^handled$' | sed 's/^/leftover: /' || true
  echo
}
nothing(){ :; }
s_unh(){ mk "$1/001.msg" "$SEEDTEXT"; }
s_hnd(){ mk "$1/handled/001.msg" "$SEEDTEXT"; }
s_unh_ff(){ mk "$1/001.msg" "$SEEDTEXT" ff; }
s_hnd_ff(){ mk "$1/handled/001.msg" "$SEEDTEXT" ff; }
SEEDTEXT='steer alpha
line two'; case_run exact_unhandled_match s_unh "$SEEDTEXT"
SEEDTEXT='steer beta'; case_run exact_handled_match s_hnd "$SEEDTEXT"
SEEDTEXT='steer gamma'; case_run ff_new_vs_ordinary_record s_unh "$SEEDTEXT" fire-and-forget
SEEDTEXT='steer delta'; case_run ordinary_new_vs_ff_record s_unh_ff "$SEEDTEXT"
SEEDTEXT='steer eps'; case_run ff_exact_match_ff_record s_hnd_ff "$SEEDTEXT" fire-and-forget
SEEDTEXT='shared first
old tail'; case_run near_miss_same_first_line s_unh "shared first
new tail"
SEEDTEXT='a
b
c'; case_run multiline_exact_handled s_hnd "a
b
c"
SEEDTEXT=$'\n\nhello world'; case_run leading_blank_lines_exact s_unh "$SEEDTEXT"
SEEDTEXT='a.*[b]^$\(x) y'; case_run regex_first_line_exact s_unh "$SEEDTEXT"
SEEDTEXT='-n foo: bar'; case_run leading_dash_colon_exact s_hnd "$SEEDTEXT"
SEEDTEXT='-n foo: bar'; case_run leading_dash_near_miss s_hnd "-n foo: baz"
SEEDTEXT='key: value one'; case_run colon_first_line_exact s_unh "$SEEDTEXT"
SEEDTEXT=$(printf 'x%.0s' $(seq 1 6000))'END'; case_run six_thousand_char_first_line_exact s_unh "$SEEDTEXT"
SEEDTEXT='steer zeta'; case_run empty_text_vs_nonempty_record s_unh ""
SEEDTEXT=''; case_run empty_text_vs_empty_record s_unh ""
SEEDTEXT='steer eta extended tail'; case_run prefix_new_shorter_than_record s_unh "steer eta"
SEEDTEXT='steer theta'; case_run prefix_record_shorter_than_new s_unh "steer theta extra"
SEEDTEXT='steer iota'; case_run trailing_newline_new_vs_record s_unh "steer iota
"
