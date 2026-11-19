#!/usr/bin/env bash
# usage: scenarios.sh <scenario-id>   (prints a transcript; each scenario in its own scratch dir)
. /tmp/pbdrive/lib.sh
TOML='base_branch = "fm-pool-base"'
case "$1" in
PB1)  # real treehouse copy cut at the origin default while local main is ahead (with the change)
  newscenario pb1 >/dev/null
  printf '%s\n' "$TOML" > "$S/repo/treehouse.toml"
  git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm treehouse-config
  git -C "$S/repo" branch fm-pool-base "$(git -C "$S/repo" rev-parse origin/main)"   # the stale pool base
  advance_origin "$S"; git -C "$S/repo" fetch -q origin
  TIP=$(git -C "$S/repo" rev-parse origin/main); MAIN0=$(git -C "$S/repo" rev-parse main)
  echo "== before: origin/main=$TIP local main=$MAIN0 fm-pool-base=$(git -C "$S/repo" rev-parse fm-pool-base)"
  echo "== step (what fm-spawn does under the lock, origin default = $TIP):"
  step "$S/repo" "$TIP"; echo "rc=$?"
  echo "== fm-pool-base after: $(git -C "$S/repo" rev-parse fm-pool-base) (origin default $TIP)"
  echo "== local main after: $(git -C "$S/repo" rev-parse main) (unchanged: $MAIN0)"
  export TREEHOUSE_ROOT="$S/pool"
  copy=$(cd "$S/repo" && treehouse get --lease --lease-holder pb1-task 2>"$S/get.err"); echo "treehouse get rc=$?"
  echo "== real treehouse handed out: $copy"
  echo "== copy HEAD: $(git -C "$copy" rev-parse HEAD)"
  echo "== copy HEAD == origin default? $([ "$(git -C "$copy" rev-parse HEAD)" = "$TIP" ] && echo YES || echo NO)"
  echo "== fm-pool-base reflog:"; git -C "$S/repo" reflog show --format='%gd %gs' refs/heads/fm-pool-base
  echo "$S" > /tmp/pbdrive/PB1.dir ;;
PB1BASE)  # paired red: same origin advance, NO lib step (the base commit behaviour) -> copy stays at old pool base
  newscenario pb1base >/dev/null
  printf '%s\n' "$TOML" > "$S/repo/treehouse.toml"
  git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm treehouse-config
  git -C "$S/repo" branch fm-pool-base "$(git -C "$S/repo" rev-parse origin/main)"
  OLD=$(git -C "$S/repo" rev-parse fm-pool-base)
  advance_origin "$S"; git -C "$S/repo" fetch -q origin
  TIP=$(git -C "$S/repo" rev-parse origin/main)
  echo "== no fm-pool-base step. origin default=$TIP fm-pool-base=$OLD"
  export TREEHOUSE_ROOT="$S/pool"
  copy=$(cd "$S/repo" && treehouse get --lease --lease-holder pb1base-task 2>"$S/get.err"); echo "treehouse get rc=$?"
  echo "== copy HEAD: $(git -C "$copy" rev-parse HEAD)"
  echo "== copy HEAD == origin default? $([ "$(git -C "$copy" rev-parse HEAD)" = "$TIP" ] && echo YES || echo NO)" ;;
PB2)  # fast-forward by compare-and-set, then a second run changes nothing
  newscenario pb2 >/dev/null
  printf '%s\n' "$TOML" > "$S/repo/treehouse.toml"
  git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm treehouse-config
  git -C "$S/repo" branch fm-pool-base "$(git -C "$S/repo" rev-parse origin/main)"
  advance_origin "$S"; git -C "$S/repo" fetch -q origin
  TIP=$(git -C "$S/repo" rev-parse origin/main)
  echo "== before: fm-pool-base=$(git -C "$S/repo" rev-parse fm-pool-base) origin default=$TIP"
  echo "== run 1:"; step "$S/repo" "$TIP"; echo "rc=$?"
  echo "== after run 1: fm-pool-base=$(git -C "$S/repo" rev-parse fm-pool-base)"
  git -C "$S/repo" reflog show --format='%gd %gs' refs/heads/fm-pool-base
  BEFORE=$(snap "$S/repo")
  echo "== run 2 (nothing new on origin):"; OUT=$(step "$S/repo" "$TIP"); echo "rc=$? out=[$OUT]"
  [ "$(snap "$S/repo")" = "$BEFORE" ] && echo "== refs unchanged by run 2: YES" || echo "== refs unchanged by run 2: NO"
  ( cd "$S/repo" && git rev-list --count fm-pool-base..origin/main ) | sed 's/^/commits origin has that fm-pool-base lacks: /' ;;
PB3)  # refusals: each must name its reason, print both commits, exit 1, and move no ref
  for case in diverged ahead origin_missing origin_unreadable config_unreadable checked_out; do
    newscenario "pb3-$case" >/dev/null
    printf '%s\n' "$TOML" > "$S/repo/treehouse.toml"
    git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm treehouse-config
    OLD0=$(git -C "$S/repo" rev-parse origin/main)
    git -C "$S/repo" branch fm-pool-base "$OLD0"
    advance_origin "$S"; git -C "$S/repo" fetch -q origin
    TIP=$(git -C "$S/repo" rev-parse origin/main)
    WHY=
    case "$case" in
      diverged)  git -C "$S/repo" checkout -q -b side "$OLD0"; echo s > "$S/repo/s"; git -C "$S/repo" add s; git -C "$S/repo" commit -qm side
                 git -C "$S/repo" checkout -q main; git -C "$S/repo" branch -f fm-pool-base side 2>/dev/null || { git -C "$S/repo" branch -D fm-pool-base >/dev/null; git -C "$S/repo" branch fm-pool-base side; } ;;
      ahead)     git -C "$S/repo" checkout -q -b ahead "$TIP"; echo x > "$S/repo/x"; git -C "$S/repo" add x; git -C "$S/repo" commit -qm ahead
                 git -C "$S/repo" checkout -q main; git -C "$S/repo" branch -D fm-pool-base >/dev/null; git -C "$S/repo" branch fm-pool-base ahead ;;
      origin_missing) git -C "$S/repo" remote remove origin; TIP=; WHY='no origin remote' ;;
      origin_unreadable) TIP=0000000000000000000000000000000000000001 ;;
      config_unreadable) printf 'base_branch = \n' > "$S/repo/treehouse.toml" ;;
      checked_out) git -C "$S/repo" worktree add -q "$S/holder" fm-pool-base ;;
    esac
    BEFORE=$(snap "$S/repo")
    echo "################ refusal case: $case  (origin default arg='${TIP:-<empty>}')"
    OUT=$(step "$S/repo" "$TIP" "$WHY"); RC=$?
    echo "$OUT"; echo "exit=$RC"
    [ "$(snap "$S/repo")" = "$BEFORE" ] && echo "refs and worktree HEADs byte-identical after refusal: YES" || echo "refs and worktree HEADs byte-identical after refusal: NO"
    echo
  done ;;
PB3M)  # missing fm-pool-base is created at the origin default ONLY when the config names it
  newscenario pb3m >/dev/null
  printf '%s\n' "$TOML" > "$S/repo/treehouse.toml"
  git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm treehouse-config
  git -C "$S/repo" fetch -q origin; TIP=$(git -C "$S/repo" rev-parse origin/main)
  echo "== config names fm-pool-base, branch absent:"; step "$S/repo" "$TIP"; echo "rc=$?"
  echo "== fm-pool-base now: $(git -C "$S/repo" rev-parse fm-pool-base) (origin default $TIP)" ;;
PB4)  # home that does not name fm-pool-base: step does nothing, every ref and copy unchanged
  for body in 'base_branch = "main"' 'max_trees = 4' ''; do
    newscenario pb4 >/dev/null
    printf '%s\n' "$body" > "$S/repo/treehouse.toml"
    git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm cfg
    advance_origin "$S"; git -C "$S/repo" fetch -q origin; TIP=$(git -C "$S/repo" rev-parse origin/main)
    export TREEHOUSE_ROOT="$S/pool"
    BEFORE=$(snap "$S/repo")
    echo "################ config: '${body:-<no treehouse.toml content: empty file>}'"
    OUT=$(step "$S/repo" "$TIP"); echo "rc=$? out=[$OUT]"
    [ "$(snap "$S/repo")" = "$BEFORE" ] && echo "all refs unchanged: YES" || echo "all refs unchanged: NO"
    git -C "$S/repo" show-ref --verify --quiet refs/heads/fm-pool-base && echo "fm-pool-base created: YES (unexpected)" || echo "fm-pool-base created: NO"
  done
  newscenario pb4none >/dev/null; rm -f "$S/repo/treehouse.toml"; advance_origin "$S"; git -C "$S/repo" fetch -q origin
  TIP=$(git -C "$S/repo" rev-parse origin/main); BEFORE=$(snap "$S/repo")
  echo "################ no treehouse config at all"; OUT=$(step "$S/repo" "$TIP"); echo "rc=$? out=[$OUT]"
  [ "$(snap "$S/repo")" = "$BEFORE" ] && echo "all refs unchanged: YES" || echo "all refs unchanged: NO" ;;
esac
