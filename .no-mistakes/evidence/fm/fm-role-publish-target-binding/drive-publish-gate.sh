#!/usr/bin/env bash
# Live driver for the publish-guard change (fm/fm-role-publish-target-binding).
# Runs the real entry points (bin/fm-role.sh, bin/fm-brief.sh, bin/fm-spawn.sh,
# bin/fm-promote.sh) from the HEAD worktree and from a clone at the BASE commit,
# each in a fresh marked lab home (bin/fm-lab-home.sh create), against fixture
# clones that share firstmate's history, and a disposable NM_HOME whose
# state.sqlite was created by the installed no-mistakes CLI itself.
# Usage: drive-publish-gate.sh <head-root> <base-root> <work-dir>
set -u
HEAD_ROOT=$1 BASE_ROOT=$2 W=$3
export NM_HOME="$W/nm"
# No network git: the fixture remotes name github.com repositories that exist
# only as strings. Spawn's base fetch fails fast and reports after the gate.
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0
A=github.com/fixture-a/firstmate B=github.com/fixture-b/firstmate
URL_A=https://github.com/fixture-a/firstmate URL_B=https://github.com/fixture-b/firstmate
STUB="$W/spawn-stub"   # fake tmux exits 1 so an authorized spawn stops at launch
mkdir -p "$STUB" "$W/labs" "$W/proj"
printf '#!/bin/sh\n[ -z "$FM_TMUX_CALL_LOG" ] || echo "tmux $*" >> "$FM_TMUX_CALL_LOG"\nexit 1\n' > "$STUB/tmux"; chmod +x "$STUB/tmux"
# Every lab home and task id comes from a counter file: the run_* helpers run in
# command substitutions, so a shell variable would not advance.
: > "$W/.counter"
next_n() { local c; c=$(( $(wc -l < "$W/.counter") + 1 )); echo x >> "$W/.counter"; printf '%s\n' "$c"; }

reg() { # <checkout> <upstream-url> - a registration row in the installed schema
  sqlite3 "$NM_HOME/state.sqlite" "INSERT OR REPLACE INTO repos (id, working_path, upstream_url, created_at) VALUES ('r$RANDOM$RANDOM', '$1', '$2', strftime('%s','now'));"
}
mkproj() { # <name> <origin|-> [upstream] [registration-url|none]
  local p="$W/proj/$1"
  git clone -q --shared "$HEAD_ROOT" "$p" 2>/dev/null
  git -C "$p" remote remove origin
  [ "$2" = - ] || git -C "$p" remote add origin "$2"
  [ -z "${3:-}" ] || git -C "$p" remote add upstream "$3"
  if [ "${4:-}" != none ]; then
    if [ -n "${4:-}" ]; then reg "$(cd "$p" && pwd -P)" "$4"; elif [ "$2" != - ]; then reg "$(cd "$p" && pwd -P)" "$2"; fi
  fi
  printf '%s\n' "$p"
}
lab() { # <role-file-content|-> - a fresh marked lab home
  local h k; k=$(next_n)
  h=$("$HEAD_ROOT/bin/fm-lab-home.sh" create "$W/labs/l$k") || return 1
  [ "$1" = - ] || printf '%s\n' "$1" > "$h/config/firstmate-role"
  printf '%s\n' "$h"
}
show() { # <label> <rc> <out>
  printf '\n### %s\nexit=%s\n%s\n' "$1" "$2" "$(printf '%s\n' "$3" | grep -E 'authorized|refused|error|denied|wrote|brief|promoted|LAB|FM_HOME|spawn log|reached tmux' | grep -v '^notice' | head -6)"
}
run_role() { # <root> <role> <proj> <args...>
  local root=$1 h; h=$(lab "$2") && [ -n "$h" ] || { echo "LAB HOME FAILED"; return 99; }; shift 2
  FM_HOME="$h" "$root/bin/fm-role.sh" check "$@" 2>&1
}
run_brief() { # <root> <role> <proj> <mode> [consent]
  local h; h=$(lab "$2") && [ -n "$h" ] || { echo "LAB HOME FAILED"; return 99; }
  echo "FM_HOME=$h"
  FM_HOME="$h" "$1/bin/fm-brief.sh" "t$(next_n)" some-proj --mode "$4" --project "$3" ${5:+--upstream-consent "$5"} 2>&1
}
run_spawn() { # <root> <role> <proj> <mode> [consent]
  local h id; h=$(lab "$2") && [ -n "$h" ] || { echo "LAB HOME FAILED"; return 99; }; id="t$(next_n)"
  mkdir -p "$h/data/$id"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the role gate.\n\n## Firstmate spec\nVerify the boundary.\n\n# Definition of done\nDelivery contract: mode=%s%s\nShip branch: fm/%s\n' \
    "$4" "${5:+ upstream-consent=$5}" "$id" > "$h/data/$id/brief.md"
  FM_HOME="$h" "$HEAD_ROOT/bin/fm-tasks-axi.sh" add "$id" "gate probe" --kind ship >/dev/null 2>&1
  FM_HOME="$h" FM_SPAWN_NO_GUARD=1  FM_TMUX_CALL_LOG="$W/tmux-$id.calls" FM_BACKEND=tmux PATH="$STUB:$PATH" perl -e 'alarm 120; exec @ARGV or die' \
    "$1/bin/fm-spawn.sh" "$id" "$3" claude --mode "$4" --yolo off ${5:+--upstream-consent "$5"} > "$W/spawn-$id.log" 2>&1
  local rc=$?
  echo "spawn log: $W/spawn-$id.log"; grep -v '^notice' "$W/spawn-$id.log" | head -4
  if [ -s "$W/tmux-$id.calls" ]; then echo "reached tmux launch step (stub, exit 1): $(grep -c 'new-window' "$W/tmux-$id.calls") new-window call(s)"; else echo "reached tmux launch step: no"; fi
  return $rc
}
run_promote() { # <root> <role> <proj> <mode> [consent]
  local h id; h=$(lab "$2") && [ -n "$h" ] || { echo "LAB HOME FAILED"; return 99; }; id="t$(next_n)"
  mkdir -p "$h/data/$id"
  printf 'project=%s\nkind=scout\nwindow=fm-%s\nworktree=/tmp/wt\n' "$3" "$id" > "$h/state/$id.meta"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nInvestigate.\n\n## Firstmate spec\nReport.\n' > "$h/data/$id/brief.md"
  FM_HOME="$h" "$1/bin/fm-promote.sh" "$id" --mode "$4" --yolo off ${5:+--upstream-consent "$5"} 2>&1
}
both() { # <label> <fn> <args...> - run on HEAD and on BASE
  local label=$1 fn=$2 out rc; shift 2
  out=$($fn "$HEAD_ROOT" "$@"); rc=$?; show "HEAD | $label" "$rc" "$out"
  out=$($fn "$BASE_ROOT" "$@"); rc=$?; show "BASE | $label" "$rc" "$out"
}
head_only() {
  local label=$1 fn=$2 out rc; shift 2
  out=$($fn "$HEAD_ROOT" "$@"); rc=$?; show "HEAD | $label" "$rc" "$out"
}

P_AB=$(mkproj ab "$URL_A" "$URL_B")                  # origin A, upstream B, registered A
P_EV=$(mkproj evidence https://github.com/MrGTV-love/firstmate https://github.com/kunchenguid/firstmate)
P_REGB=$(mkproj ab-regB "$URL_A" "$URL_B" "$URL_B")   # registration disagrees with origin
P_NONE=$(mkproj ab-unreg "$URL_A" "$URL_B" none)      # unregistered
P_NOORIG=$(mkproj no-origin - "$URL_B" none)          # only an upstream remote
P_ORIGONLY=$(mkproj origin-only "$URL_A")              # only an origin remote
P_SSH=$(mkproj ab-ssh "$URL_A" "$URL_B" git@github.com:fixture-a/firstmate.git)
git -C "$P_REGB" worktree add -q --detach "$W/proj/ab-regB-wt" 2>/dev/null
ln -s "$P_REGB" "$W/proj/ab-regB-link"
DB_SUM_BEFORE=$(shasum -a 256 "$NM_HOME/state.sqlite" | cut -d' ' -f1)

echo "## Fixture remotes"
for p in "$P_AB" "$P_EV" "$P_REGB" "$P_NONE" "$P_NOORIG" "$P_ORIGONLY"; do
  printf '%s: %s\n' "${p##*/}" "$(git -C "$p" remote -v | awk '/fetch/{printf "%s=%s ", $1, $2}')"
done
echo "## Registry rows (installed no-mistakes schema, disposable NM_HOME)"
sqlite3 "$NM_HOME/state.sqlite" "SELECT replace(working_path,'$W/',''), upstream_url FROM repos;"

echo; echo "## S1 reported bug, exact evidence literals (fm-brief.sh, consent MrGTV-love)"
both "brief evidence layout consent=github.com/mrgtv-love/firstmate" run_brief - "$P_EV" no-mistakes github.com/MrGTV-love/firstmate

echo; echo "## S2 G1: origin consent passes every entry point (origin A, upstream B)"
both "fm-role.sh check consent A mode no-mistakes" run_role - "$P_AB" upstream-consent "$A" mode no-mistakes
both "fm-brief.sh consent A" run_brief - "$P_AB" no-mistakes "$A"
both "fm-spawn.sh consent A (launch stubbed after gate)" run_spawn - "$P_AB" no-mistakes "$A"
both "fm-promote.sh consent A" run_promote - "$P_AB" no-mistakes "$A"

echo; echo "## S3 G2: refusals the guard must keep (HEAD)"
head_only "role consent B" run_role - "$P_AB" upstream-consent "$B" mode no-mistakes
head_only "brief consent B" run_brief - "$P_AB" no-mistakes "$B"
head_only "role no consent (user/operator)" run_role - "$P_AB" mode no-mistakes
head_only "brief no consent (user/operator)" run_brief - "$P_AB" no-mistakes
head_only "spawn no consent (user/operator)" run_spawn - "$P_AB" no-mistakes
head_only "role maintainer B" run_role "maintainer $B" "$P_AB" mode no-mistakes
head_only "brief maintainer B" run_brief "maintainer $B" "$P_AB" no-mistakes
head_only "role maintainer A" run_role "maintainer $A" "$P_AB" mode no-mistakes
head_only "brief maintainer A" run_brief "maintainer $A" "$P_AB" no-mistakes
head_only "role no origin remote, consent B" run_role - "$P_NOORIG" upstream-consent "$B" mode no-mistakes
head_only "brief no origin remote, consent B" run_brief - "$P_NOORIG" no-mistakes "$B"

echo; echo "## S4 adversarial: registration names B while origin is A"
head_only "role consent A, registered B" run_role - "$P_REGB" upstream-consent "$A" mode no-mistakes
head_only "brief consent A, registered B" run_brief - "$P_REGB" no-mistakes "$A"
head_only "spawn consent A, registered B" run_spawn - "$P_REGB" no-mistakes "$A"
head_only "promote consent A, registered B" run_promote - "$P_REGB" no-mistakes "$A"
head_only "brief maintainer A, registered B" run_brief "maintainer $A" "$P_REGB" no-mistakes
head_only "role consent A, linked worktree of a checkout registered B" run_role - "$W/proj/ab-regB-wt" upstream-consent "$A" mode no-mistakes
head_only "role consent A, symlinked path to checkout registered B" run_role - "$W/proj/ab-regB-link" upstream-consent "$A" mode no-mistakes
head_only "role consent A, registered as ssh spelling of A" run_role - "$P_SSH" upstream-consent "$A" mode no-mistakes

echo; echo "## S5 unregistered and unreadable registry"
head_only "role consent A, unregistered project" run_role - "$P_NONE" upstream-consent "$A" mode no-mistakes
NM_HOME_SAVE=$NM_HOME
export NM_HOME="$W/nm-empty"; mkdir -p "$NM_HOME"
head_only "role consent A, no registry database" run_role - "$P_AB" upstream-consent "$A" mode no-mistakes
export NM_HOME="$W/nm-garbage"; mkdir -p "$NM_HOME"; printf 'not a database\n' > "$NM_HOME/state.sqlite"
head_only "role consent A, corrupt registry file" run_role - "$P_AB" upstream-consent "$A" mode no-mistakes
head_only "brief consent A, corrupt registry file" run_brief - "$P_AB" no-mistakes "$A"
export NM_HOME="$W/nm-notable"; mkdir -p "$NM_HOME"; sqlite3 "$NM_HOME/state.sqlite" 'CREATE TABLE other (x);'
head_only "role consent A, registry without repos table" run_role - "$P_AB" upstream-consent "$A" mode no-mistakes
export NM_HOME="$W/nm-blank"; mkdir -p "$NM_HOME"; sqlite3 "$NM_HOME/state.sqlite" "$(sqlite3 "$NM_HOME_SAVE/state.sqlite" '.schema repos')"
sqlite3 "$NM_HOME/state.sqlite" "INSERT INTO repos (id, working_path, upstream_url, created_at) VALUES ('x', '$(cd "$P_AB" && pwd -P)', '', 0);"
head_only "role consent A, registration with blank destination" run_role - "$P_AB" upstream-consent "$A" mode no-mistakes
export NM_HOME=$NM_HOME_SAVE

echo; echo "## S6 G3: gh delivery paths unchanged (HEAD vs BASE)"
both "role direct-PR consent A (gh target is upstream B)" run_role - "$P_AB" upstream-consent "$A" mode direct-PR
both "brief direct-PR consent A" run_brief - "$P_AB" direct-PR "$A"
both "brief direct-PR consent B" run_brief - "$P_AB" direct-PR "$B"
both "spawn direct-PR consent B" run_spawn - "$P_AB" direct-PR "$B"
both "role no mode consent A" run_role - "$P_AB" upstream-consent "$A"
both "role no mode consent B" run_role - "$P_AB" upstream-consent "$B"
both "origin-only: brief no-mistakes consent A" run_brief - "$P_ORIGONLY" no-mistakes "$A"
both "origin-only: brief direct-PR consent A" run_brief - "$P_ORIGONLY" direct-PR "$A"
both "origin-only: brief no-mistakes consent B" run_brief - "$P_ORIGONLY" no-mistakes "$B"
both "origin-only: brief local-only no consent" run_brief - "$P_ORIGONLY" local-only

echo; echo "## S7 G4: fm-role.sh mode argument is checked, never a repository"
head_only "role mode names a repository" run_role - "$P_AB" upstream-consent "$A" mode "$A"
head_only "role mode without value" run_role - "$P_AB" upstream-consent "$A" mode

echo; echo "## S8 registry is read, never written"
DB_SUM_AFTER=$(shasum -a 256 "$NM_HOME/state.sqlite" | cut -d' ' -f1)
echo "state.sqlite sha256 before=$DB_SUM_BEFORE after=$DB_SUM_AFTER"
[ "$DB_SUM_BEFORE" = "$DB_SUM_AFTER" ] && echo "unchanged: yes" || echo "unchanged: NO"
