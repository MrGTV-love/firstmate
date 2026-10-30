#!/usr/bin/env bash
# Confinement probe: run from inside the worker's own worktree.
C=/Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo/.git
echo "FM_WRITE_CONFINEMENT=$FM_WRITE_CONFINEMENT"
echo "effective fetch.prune=$(git config --get fetch.prune)"
echo "before: fm/other -> $(git -C /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo rev-parse fm/other)"
printf '# pack-refs with: peeled fully-peeled sorted \n%s refs/heads/fm/other\n' "$(git -C /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo rev-parse main)" > "$C/packed-refs" && echo "attack1 packed-refs write: exit 0" || echo "attack1 packed-refs write: refused"
{ printf '# pack-refs with: peeled fully-peeled sorted \n%s refs/heads/fm/other\n' "$(git -C /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo rev-parse main)" > "$C/packed-refs.lock" && mv -f "$C/packed-refs.lock" "$C/packed-refs"; } && echo "attack2 rename-over: exit 0" || echo "attack2 rename-over: refused"
rm -f "$C/packed-refs.lock"
git pack-refs --all 2>&1 | head -2; echo "attack4 pack-refs exit=${PIPESTATUS[0]}"
echo "after: fm/other -> $(git -C /Users/charlesabrooker/tmp/fm-lab.0AkHQR/projects/demo rev-parse fm/other)"
echo work > probe-file && git add probe-file && git -c user.name=W -c user.email=w@example.invalid commit -q -m probe && echo "own commit: ok"
echo change > probe-file && git stash push -q -m probe && git stash pop -q && echo "stash push+pop: ok"
git fetch origin 2>&1; echo "fetch exit=$?"
