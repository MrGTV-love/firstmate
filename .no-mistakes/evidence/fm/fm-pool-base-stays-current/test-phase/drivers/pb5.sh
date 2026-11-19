#!/usr/bin/env bash
# PB5: an EXISTING pool copy (cut earlier, still leased) is untouched when origin advances and the step runs.
. /tmp/pbdrive/lib.sh
newscenario pb5 >/dev/null
printf 'base_branch = "fm-pool-base"\n' > "$S/repo/treehouse.toml"
git -C "$S/repo" add treehouse.toml; git -C "$S/repo" commit -qm cfg
git -C "$S/repo" branch fm-pool-base "$(git -C "$S/repo" rev-parse origin/main)"
export TREEHOUSE_ROOT="$S/pool"; mkdir -p "$S/pool"
A=$(cd "$S/repo" && treehouse get --lease --lease-holder pb5-old 2>"$S/getA.err") || { echo "first get failed"; cat "$S/getA.err"; exit 1; }
echo "== existing copy A (leased earlier): $A  HEAD=$(git -C "$A" rev-parse HEAD)  status=[$(git -C "$A" status --porcelain)]"
advance_origin "$S"; git -C "$S/repo" fetch -q origin
TIP=$(git -C "$S/repo" rev-parse origin/main); MAIN0=$(git -C "$S/repo" rev-parse main)
A_BEFORE="$(git -C "$A" rev-parse HEAD) $(git -C "$A" diff-index --cached HEAD | wc -l) $(git -C "$A" status --porcelain | wc -l)"
echo "== origin default now $TIP; running the step (as spawn admission does under the lock)"
step "$S/repo" "$TIP"; echo "step rc=$?"
echo "== fm-pool-base now $(git -C "$S/repo" rev-parse fm-pool-base)"
echo "== copy A untouched (HEAD, staged, dirty counts): $([ "$(git -C "$A" rev-parse HEAD) $(git -C "$A" diff-index --cached HEAD | wc -l) $(git -C "$A" status --porcelain | wc -l)" = "$A_BEFORE" ] && echo YES || echo NO)  HEAD=$(git -C "$A" rev-parse HEAD)  status=[$(git -C "$A" status --porcelain)]"
echo "== local main unchanged: $([ "$(git -C "$S/repo" rev-parse main)" = "$MAIN0" ] && echo YES || echo NO)"
B=$(cd "$S/repo" && treehouse get --lease --lease-holder pb5-new 2>"$S/getB.err") || { echo "second get failed"; cat "$S/getB.err"; exit 1; }
echo "== second real get handed out a different copy: $([ "$B" != "$A" ] && echo YES || echo NO) ($B)"
echo "== second copy HEAD == origin default $TIP? $([ "$(git -C "$B" rev-parse HEAD)" = "$TIP" ] && echo YES || echo NO)"
echo "== copy A still at its old commit: $(git -C "$A" rev-parse HEAD)"
