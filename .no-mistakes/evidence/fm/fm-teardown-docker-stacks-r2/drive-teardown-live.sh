#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh + real Docker daemon + real git + real tmux
# (private socket) inside a disposable marked lab home. Only the external fleet
# services (treehouse pool, GitHub, no-mistakes daemon) are stubbed so nothing
# shared is touched. Every Docker object carries fm.test=$RUN so the trap removes
# only what this run made.
#
# Usage: drive-teardown-live.sh <worktree> <scenario>
#   scenario: happy | daemon-down-clean | daemon-down-retained
set -u
SRC=$1 SCEN=$2
RUN="fmlive$$$(date +%s)"
ID="$RUN"                       # the task id
SIB="$RUN-v2"                   # a longer live sibling task in the same home
OTHER="other$RUN"               # another task, unrelated name
SHARED="vern$RUN"               # the shared Supabase project_id
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
FIX=$(mktemp -d "${TMPDIR:-/tmp}/fm-fix.XXXXXX")

cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true
  for kind in "ps -a" "network ls" "volume ls"; do
    ids=$(docker $kind -q --filter "label=fm.test=$RUN" 2>/dev/null)
    [ -z "$ids" ] && continue
    case $kind in
      ps*) echo "$ids" | xargs docker rm -f -v >/dev/null 2>&1 ;;
      network*) echo "$ids" | xargs docker network rm >/dev/null 2>&1 ;;
      volume*) echo "$ids" | xargs docker volume rm >/dev/null 2>&1 ;;
    esac
  done
  rm -rf "$LAB" "$FIX"
}
trap cleanup EXIT

"$SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 9; }
mkdir -p "$LAB/tmux" "$FIX/fakebin"
for f in treehouse gh; do printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr view") exit 1;; esac\nexit 0\n' > "$FIX/fakebin/$f"; done
printf '#!/usr/bin/env bash\ncase "${1:-} ${2:-}" in "pr list") printf "%%s\\n" "count: 0 (showing first 0)" "pull_requests[]: []";; "pr view") exit 1;; esac\nexit 0\n' > "$FIX/fakebin/gh-axi"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIX/fakebin/no-mistakes"
chmod +x "$FIX/fakebin"/*

# Real git: origin, project clone, task worktree with a pushed commit.
git init -q --bare "$FIX/origin.git"; git -C "$FIX/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$FIX/origin.git" "$FIX/seed" 2>/dev/null
git -C "$FIX/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$FIX/seed" push -q origin main; rm -rf "$FIX/seed"
git clone -q "$FIX/origin.git" "$FIX/project"; git -C "$FIX/project" remote set-head origin main
git -C "$FIX/project" worktree add -q -b "fm/$ID" "$FIX/wt" main
git -C "$FIX/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
git -C "$FIX/wt" push -q origin "fm/$ID"; git -C "$FIX/project" fetch -q origin
mkdir -p "$FIX/project/supabase"
printf 'project_id = "%s"\n' "$SHARED" > "$FIX/project/supabase/config.toml"
WT=$(cd "$FIX/wt" && pwd -P)

# Task records in the lab home.
cat > "$LAB/state/$ID.meta" <<EOF
window=firstmate:fm-$ID
endpoint_task_id=$ID
worktree=$FIX/wt
project=$FIX/project
kind=ship
mode=no-mistakes
spawn_gen=live-$ID
EOF
printf 'kind=ship\nmode=no-mistakes\nspawn_gen=live-%s\n' "$SIB" > "$LAB/state/$SIB.meta"
printf 'kind=ship\nmode=no-mistakes\nspawn_gen=live-%s\n' "$OTHER" > "$LAB/state/$OTHER.meta"
touch "$LAB/state/.last-watcher-beat"

# Real tmux on the lab's private socket, holding the task window.
TMUX_TMPDIR="$LAB/tmux" tmux new-session -d -s firstmate -n "fm-$ID" "sleep 600"

T="--label fm.test=$RUN"
if [ "$SCEN" = retry ]; then
  # A plain compose stack in the worktree. A first teardown already removed its
  # container (and retained its project identity) before failing; the network is left.
  O2=$(( (RANDOM % 250) + 1 ))
  mkdir -p "$FIX/wt/plain"
  cat > "$FIX/wt/plain/compose.yaml" <<EOF
services:
  db:
    image: redis:7-alpine
    labels: { fm.test: "$RUN" }
networks:
  default:
    labels: { fm.test: "$RUN" }
    ipam: { config: [ { subnet: "198.18.$O2.0/24" } ] }
EOF
  (cd "$FIX/wt/plain" && docker compose -p "plain$RUN" up -d >"$FIX/c2.log" 2>&1) || { cat "$FIX/c2.log"; exit 9; }
  docker rm -f "plain$RUN-db-1" >/dev/null
  printf 'docker_projects=%s\n' "plain$RUN" >> "$LAB/state/$ID.meta"
  git -C "$FIX/wt" add -A && git -C "$FIX/wt" -c user.email=t@t -c user.name=t commit -q -m "compose stack"
fi
if [ "$SCEN" = happy ]; then
  # --- The task's own stacks, shaped like the 2026-10-06 leak evidence ---
  # A stopped throwaway postgres named for the task (ran, then exited).
  docker run -d $T --name "$ID-throwaway-pg" -e POSTGRES_PASSWORD=x postgres:15-alpine >/dev/null
  docker stop "$ID-throwaway-pg" >/dev/null
  # A running marker-labelled container with an unrelated name.
  docker run -d $T --label "fm.task=$ID" --name "scratch-$RUN" redis:7-alpine >/dev/null
  # A real Compose project named for the task, run from the worktree, with a named volume and network.
  mkdir -p "$FIX/wt/stack"
  cat > "$FIX/wt/stack/compose.yaml" <<EOF
services:
  db:
    image: redis:7-alpine
    labels: { fm.test: "$RUN" }
    volumes: [ "data:/data" ]
volumes:
  data:
    labels: { fm.test: "$RUN" }
networks:
  default:
    labels: { fm.test: "$RUN" }
    ipam: { config: [ { subnet: "198.18.__OCT__.0/24" } ] }
EOF
  O1=$(( (RANDOM % 120) + 1 )); O2=$(( O1 + 121 )); O3=$(( (RANDOM % 250) + 1 ))
  sed -i '' "s/__OCT__/$O1/" "$FIX/wt/stack/compose.yaml"
  (cd "$FIX/wt/stack" && docker compose -p "$ID" up -d >"$FIX/c1.log" 2>&1) || { echo "compose -p up failed"; cat "$FIX/c1.log"; exit 9; }
  # A plain `docker compose up` in the worktree (default project name, path attribution).
  mkdir -p "$FIX/wt/plain"
  sed "s/198.18.$O1.0/198.18.$O2.0/" "$FIX/wt/stack/compose.yaml" > "$FIX/wt/plain/compose.yaml"
  (cd "$FIX/wt/plain" && docker compose -p "plain$RUN" up -d >"$FIX/c2.log" 2>&1) || { echo "compose plain up failed"; cat "$FIX/c2.log"; exit 9; }
  docker volume create $T --label "fm.task=$ID" "$ID-scratchvol" >/dev/null
  # The worker committed and pushed its compose files.
  git -C "$FIX/wt" add -A && git -C "$FIX/wt" -c user.email=t@t -c user.name=t commit -q -m "compose stacks"
  git -C "$FIX/wt" push -q origin "fm/$ID"; git -C "$FIX/project" fetch -q origin

  # --- Not the task's: must survive ---
  docker create $T --name "$SIB-pg" postgres:15-alpine >/dev/null                       # longer sibling's name
  docker create $T --label "fm.task=$OTHER" --name "$ID-claimed" postgres:15-alpine >/dev/null  # task-id name, other task's marker
  docker create $T --label "fm.task=$OTHER" --name "$OTHER-db" postgres:15-alpine >/dev/null
  docker create $T --name "gre-throwaway-$RUN" postgres:15-alpine >/dev/null             # unmarked stranger
  # The shared local Supabase stack.
  docker network create $T --subnet "198.19.$O3.0/24" --label "com.docker.compose.project=$SHARED" --label "com.supabase.cli.project=$SHARED" "supabase_network_$SHARED" >/dev/null
  docker volume create $T --label "com.supabase.cli.project=$SHARED" "supabase_db_$SHARED" >/dev/null
  docker create $T --label "com.docker.compose.project=$SHARED" --label "com.supabase.cli.project=$SHARED" \
    --network "supabase_network_$SHARED" -v "supabase_db_$SHARED:/var/lib/postgresql/data" --name "supabase_db_$SHARED" postgres:15-alpine >/dev/null
  # Named volumes the task did not create.
  docker volume create $T "$ID-unlabelled" >/dev/null
  docker volume create $T --label "fm.task=$OTHER" "$OTHER-vol" >/dev/null
fi

snapshot() {
  echo "## containers"; docker ps -a --filter "label=fm.test=$RUN" --format '{{.Names}}  [{{.Status}}]  fm.task={{.Label "fm.task"}} project={{.Label "com.docker.compose.project"}}' | sort
  echo "## networks"; docker network ls --filter "label=fm.test=$RUN" --format '{{.Name}}' | sort
  echo "## volumes"; docker volume ls --filter "label=fm.test=$RUN" --format '{{.Name}}' | sort
}

# The task's work landed on origin's default branch (merged).
git -C "$FIX/wt" push -q origin "fm/$ID:main"; git -C "$FIX/project" fetch -q origin
case $SCEN in
  happy) ;;
  daemon-down-clean) export DOCKER_HOST="unix://$FIX/no-such-docker.sock" ;;
  retry) export DOCKER_HOST="unix://$FIX/no-such-docker.sock" ;;
  daemon-down-retained)
    printf 'docker_projects=%s\n' "$ID" >> "$LAB/state/$ID.meta"
    export DOCKER_HOST="unix://$FIX/no-such-docker.sock" ;;
esac

echo "=== scenario: $SCEN   task id: $ID   shared supabase project_id: $SHARED"
echo "=== BEFORE teardown"; ( unset DOCKER_HOST; snapshot )
echo "=== task meta before:"; cat "$LAB/state/$ID.meta"
echo "=== RUN: FM_HOME=<lab> bin/fm-teardown.sh $ID"
rc=0
env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" PATH="$FIX/fakebin:$PATH" \
  "$SRC/bin/fm-teardown.sh" "$ID" 2>&1 | sed "s#$FIX#<fix>#g; s#$LAB#<lab>#g" || true
rc=${PIPESTATUS[0]}
echo "=== teardown exit code: $rc"
echo "=== AFTER teardown"; ( unset DOCKER_HOST; snapshot )
if [ -f "$LAB/state/$ID.meta" ]; then echo "=== task record: KEPT"; cat "$LAB/state/$ID.meta"; else echo "=== task record: REMOVED"; fi
[ -d "$FIX/wt" ] && echo "=== worktree: still present" || echo "=== worktree: removed"
[ -f "$LAB/state/$SIB.meta" ] && echo "=== sibling record $SIB: kept"

if [ "$SCEN" = retry ]; then
  unset DOCKER_HOST
  echo; echo "=== RETRY with the Docker daemon reachable again: FM_HOME=<lab> bin/fm-teardown.sh $ID"
  env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" PATH="$FIX/fakebin:$PATH" \
    "$SRC/bin/fm-teardown.sh" "$ID" 2>&1 | sed "s#$FIX#<fix>#g; s#$LAB#<lab>#g" || true
  echo "=== retry exit code: ${PIPESTATUS[0]}"
  echo "=== AFTER retry"; snapshot
  if [ -f "$LAB/state/$ID.meta" ]; then echo "=== task record: KEPT"; cat "$LAB/state/$ID.meta"; else echo "=== task record: REMOVED"; fi
fi
