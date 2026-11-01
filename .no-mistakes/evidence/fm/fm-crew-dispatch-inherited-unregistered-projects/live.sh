#!/usr/bin/env bash
# Live validation: real fm-config-push, fm-bootstrap and fm-dispatch-resolve
# from a given repo checkout against disposable parent/child homes.
# Usage: live.sh <repo-root> <label>
set -u
REPO=$1; LABEL=${2:-head}
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS TYPESAFE_API_KEY FM_HOME
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-live.XXXXXX")
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"; unset TMUX
trap 'rm -rf "$W"' EXIT
echo "### repo=$REPO label=$LABEL head=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo archive)"
mk_home() { mkdir -p "$1/config" "$1/data" "$1/state"; printf '%s\n' manual > "$1/config/backlog-backend"; }
P="$W/parent"; mk_home "$P"
printf '%s\n' 'TYPESAFE_API_KEY=synthetic-live-key' > "$P/.env"
printf '%s\n' '# Projects' '- parent-app - Parent-only fleet project' '- local-app - Shared project' > "$P/data/projects.md"
cat > "$P/config/crew-dispatch.json" <<'JSON'
{"judgments":{"j_parent":{"type":"noul","instructions":"Does the task touch the parent app?","criteria":{"true":"It touches the parent app.","false":"It does not."}},"j_local":{"type":"noul","instructions":"Is the task a bounded local fix?","criteria":{"true":"It is a bounded local fix.","false":"It is not."}}},
 "rules":[
 {"when":"Parent-only project","match":{"projects":["parent-app"],"all":["j_parent"]},"use":{"harness":"claude"}},
 {"when":"Shared fleet project","match":{"projects":["local-app","parent-app"],"all":["j_local"]},"use":{"harness":"codex"}}
],"default":{"harness":"claude"}}
JSON
child() {  # <name> <registry-kind>
  local C="$W/$1"; mk_home "$C"; : > "$C/AGENTS.md"; mkdir -p "$C/bin"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$P" > "$C/.fm-secondmate-parent"
  printf '%s\n' "$1" > "$C/.fm-secondmate-home"
  case "$2" in
    subset) printf '%s\n' '# Projects' '- local-app - Local project' > "$C/data/projects.md"; mkdir -p "$C/projects/local-app" ;;
    empty) printf '# Projects\n' > "$C/data/projects.md" ;;
    absent) ;;
    broken) printf '%s\n' '- local-app - Local project' '- local-app - Duplicate' > "$C/data/projects.md" ;;
  esac
  printf 'kind=secondmate\nhome=%s\n' "$C" > "$P/state/$1.meta"
}
for c in subset empty absent broken; do child "sm-$c" "$c"; done
boot() {  # <home>
  FM_HOME="$1" FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip "$REPO/bin/fm-bootstrap.sh" 2>&1 | grep -E 'CREW_DISPATCH' || echo "(no CREW_DISPATCH lines)"
}
echo; echo "== S1 propagation: real fm-config-push.sh from parent into live child homes"
FM_HOME="$P" "$REPO/bin/fm-config-push.sh" 2>&1 | grep -Ev '^\s*$' | sed 's/^/  /'
echo "  push exit=${PIPESTATUS[0]}"
for c in subset empty absent broken; do
  if cmp -s "$P/config/crew-dispatch.json" "$W/sm-$c/config/crew-dispatch.json"; then echo "  sm-$c: crew-dispatch.json identical to parent"; else echo "  sm-$c: crew-dispatch.json NOT present/identical"; cp "$P/config/crew-dispatch.json" "$W/sm-$c/config/crew-dispatch.json"; echo "  sm-$c: (copied for remaining checks)"; fi
done
echo; echo "== S0 parent primary home (owns policy, registers both projects): bootstrap"
boot "$P" | sed 's/^/  /'
for c in subset empty absent broken; do
  echo; echo "== bootstrap in secondmate home sm-$c (registry: $c)"
  boot "$W/sm-$c" | sed 's/^/  /'
done
echo; echo "== S5 adversarial: home-owned (no secondmate marker) policy with typo 'Local-app'"
O="$W/owned"; mk_home "$O"; printf '%s\n' 'TYPESAFE_API_KEY=synthetic-live-key' > "$O/.env"
printf '%s\n' '# Projects' '- local-app - Local project' > "$O/data/projects.md"
jq '.rules[1].match.projects=["Local-app"]' "$P/config/crew-dispatch.json" > "$O/config/crew-dispatch.json"
boot "$O" | sed 's/^/  /'
echo; echo "== S6 adversarial: forged secondmate marker (symlink) on home-owned policy naming parent-app"
F="$W/forged"; mk_home "$F"; printf '%s\n' 'TYPESAFE_API_KEY=synthetic-live-key' > "$F/.env"
printf '%s\n' '# Projects' '- local-app - Local project' > "$F/data/projects.md"
cp "$P/config/crew-dispatch.json" "$F/config/crew-dispatch.json"
printf '%s\n' forged > "$W/marker-target"; ln -s "$W/marker-target" "$F/.fm-secondmate-home"
boot "$F" | sed 's/^/  /'
echo "  (and invalid marker id 'bad id!')"; rm "$F/.fm-secondmate-home"; printf '%s\n' 'bad id!' > "$F/.fm-secondmate-home"
boot "$F" | sed 's/^/  /'
echo; echo "== S7 adversarial: malformed parent-only profile in secondmate sm-subset"
jq '.rules[0].use.harness="spaceship"' "$P/config/crew-dispatch.json" > "$W/sm-subset/config/crew-dispatch.json.tmp" && mv "$W/sm-subset/config/crew-dispatch.json.tmp" "$W/sm-subset/config/crew-dispatch.json"
boot "$W/sm-subset" | sed 's/^/  /'
jq '.rules[0].match.projects=[]' "$P/config/crew-dispatch.json" > "$W/sm-empty/config/crew-dispatch.json"
echo "  (and empty match.projects in sm-empty)"; boot "$W/sm-empty" | sed 's/^/  /'
echo "  (and malformed JSON in sm-absent)"; printf '{"rules":[' > "$W/sm-absent/config/crew-dispatch.json"; boot "$W/sm-absent" | sed 's/^/  /'
cp "$P/config/crew-dispatch.json" "$W/sm-subset/config/crew-dispatch.json"
cp "$P/config/crew-dispatch.json" "$W/sm-empty/config/crew-dispatch.json"
cp "$P/config/crew-dispatch.json" "$W/sm-absent/config/crew-dispatch.json"

echo; echo "== Resolver: real fm-dispatch-resolve.sh against a local loopback TypeSafe endpoint"
node "$(dirname "$0")/provider.mjs" "$W/calls.jsonl" "$W/port" &
SERVER=$!; trap 'kill $SERVER 2>/dev/null; rm -rf "$W"' EXIT
for _ in $(seq 1 100); do [ -f "$W/port" ] && break; sleep .05; done
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$W/port")"
brief() {  # <out> <project_path>
  printf 'FIRSTMATE_DISPATCH: {"project_path":"%s"}\n# Task\n## Captain'"'"'s intent\nFix a bounded bug with a known cause.\n## Firstmate spec\nUse the existing implementation.\n' "$2" > "$1"
}
calls() { [ -f "$W/calls.jsonl" ] && wc -l < "$W/calls.jsonl" | tr -d ' ' || echo 0; }
resolve() {  # <home> <brief>
  local out rc before; before=$(calls)
  out=$(FM_HOME="$1" bash "$REPO/bin/fm-dispatch-resolve.sh" "$2" 2>"$W/err"); rc=$?
  echo "  exit=$rc provider_calls=$(( $(calls) - before ))"
  printf '%s\n' "$out" | grep -E 'status:|choice|rule|reason|harness:' | head -12 | sed 's/^/    /'
  [ -s "$W/err" ] && sed 's/^/    stderr: /' "$W/err" | head -4
  [ "$(calls)" -gt "$before" ] && echo "    questions sent: $(tail -1 "$W/calls.jsonl" | jq -c '.questions | keys')"
  return 0
}
echo "-- S8 sm-subset: task bound to local clone $W/sm-subset/projects/local-app"
brief "$W/b1.md" "$W/sm-subset/projects/local-app"; resolve "$W/sm-subset" "$W/b1.md"
echo "-- S9 sm-subset: task bound to parent-only path (not a local clone)"
mkdir -p "$W/sm-subset/projects/parent-app"; brief "$W/b2.md" "$W/sm-subset/projects/parent-app"; resolve "$W/sm-subset" "$W/b2.md"
echo "-- S9b sm-subset: brief with no FIRSTMATE_DISPATCH binding"
tail -n +2 "$W/b1.md" > "$W/b3.md"; resolve "$W/sm-subset" "$W/b3.md"
echo "-- S10 sm-broken: duplicate-id registry, task bound to local clone"
mkdir -p "$W/sm-broken/projects/local-app"; brief "$W/b4.md" "$W/sm-broken/projects/local-app"; resolve "$W/sm-broken" "$W/b4.md"
echo "-- S11 owned home (no marker), policy names parent-app it does not register"
cp "$P/config/crew-dispatch.json" "$O/config/crew-dispatch.json"; mkdir -p "$O/projects/local-app"
brief "$W/b5.md" "$O/projects/local-app"; resolve "$O" "$W/b5.md"
echo "-- S12 sm-empty (project-less home): task bound to the home itself"
brief "$W/b6.md" "$W/sm-empty"; resolve "$W/sm-empty" "$W/b6.md"
echo; echo "== S13 adversarial: secondmate registry is a dangling symlink (unreadable)"
D="$W/sm-subset/data/projects.md"; rm -f "$D"; ln -s "$W/does-not-exist" "$D"
boot "$W/sm-subset" | sed 's/^/  /'
