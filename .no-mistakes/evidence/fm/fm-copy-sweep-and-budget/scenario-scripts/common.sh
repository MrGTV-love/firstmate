# shared helpers for the live copy-sweep scenarios (real git, real du, real lsof, real uptime)
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M58728MK8Q605TAN6ZCZGFHM
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M58728MK8Q605TAN6ZCZGFHM
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

# new_world <lab> : sets LAB TH ORIGIN and empties/creates a pool layout
new_world() {
  LAB=$1
  TH=$LAB/th
  rm -rf "$TH" "$LAB/state" "$LAB/config" "$LAB/data" "$LAB/origin"*
  mkdir -p "$TH" "$LAB/state" "$LAB/config" "$LAB/data"
}

# make_slot <pool> <n> : a pool slot clone with a bare origin; appends to treehouse-state.json
make_slot() {
  local pool=$1 n=$2 slot origin
  slot=$TH/$pool/$n/repo
  origin=$LAB/origin-$pool-$n.git
  mkdir -p "$slot"
  git -C "$slot" init -q -b main
  printf '# %s-%s\n' "$pool" "$n" > "$slot/README.md"
  git -C "$slot" add README.md
  git -C "$slot" commit -qm initial
  git clone -q --bare "$slot" "$origin"
  git -C "$slot" remote add origin "file://$origin"
  git -C "$slot" fetch -q origin
  git -C "$slot" branch -q --set-upstream-to=origin/main main
  SLOT=$slot
  local f=$TH/$pool/treehouse-state.json
  if [ -f "$f" ]; then
    jq --arg p "$slot" --arg n "$n" '.worktrees += [{"name":$n,"path":$p}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  else
    printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$n" "$slot" > "$f"
  fi
}

# add_copy <slot> <name> [mb] : pushed, clean nested copy (optionally mb MiB of tracked payload)
add_copy() {
  local slot=$1 name=$2 mb=${3:-0} copy
  copy=$slot/.claude/worktrees/$name
  git -C "$slot" worktree add -q -b "fm/$name" "$copy"
  printf '%s\n' "$name" > "$copy/$name.txt"
  if [ "$mb" -gt 0 ]; then dd if=/dev/urandom of="$copy/payload.bin" bs=1048576 count="$mb" 2>/dev/null; git -C "$copy" add payload.bin; fi
  git -C "$copy" add "$name.txt"
  git -C "$copy" commit -qm "$name"
  git -C "$copy" push -q origin "fm/$name"
}

sweep() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$LAB" FM_COPY_SWEEP_TREEHOUSE_ROOT="$TH" "$@"
}

snap() { ( cd "$1" && find . -print | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 ); }
