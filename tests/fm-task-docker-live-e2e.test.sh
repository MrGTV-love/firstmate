#!/usr/bin/env bash
# Live regression for bin/fm-task-docker-lib.sh against the host's real Docker.
#
# The teardown suite drives the library through a fake docker that renders the
# library's own --format templates, so it proves the ownership rules but not that
# real Docker prints those fields the way the library reads them. Only a real
# daemon proves the ps, network ls, volume ls, rm, and label-filter calls work
# where they are executed. The guard creates containers without starting them
# from an image that is already local, so it pulls nothing and spends no network.
#
# Every object it creates carries the fm.test marker label with this run's token,
# and the cleanup trap removes only objects carrying that token, so it can never
# touch a real stack. Decoys are created the same way and must survive.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_TASK_DOCKER_LIVE_E2E docker

docker info >/dev/null 2>&1 || { printf 'skip: live: docker daemon not reachable\n'; exit 0; }
IMAGE=$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>' | head -1)
[ -n "$IMAGE" ] || { printf 'skip: live: no local docker image to create containers from\n'; exit 0; }

# shellcheck source=bin/fm-task-docker-lib.sh
. "$ROOT/bin/fm-task-docker-lib.sh"

RUN="fmtdl$$x$(date +%s)"
TASK="task-$RUN"
OTHER="task-$RUN-v2"
TMP_ROOT=$(fm_test_tmproot fm-task-docker-live)
export FM_TASK_DOCKER_TIMEOUT_SECS=60

live_cleanup() {
  local ids
  ids=$(docker ps -a -q --filter "label=fm.test=$RUN" 2>/dev/null) || ids=
  [ -z "$ids" ] || printf '%s\n' "$ids" | xargs docker rm -f -v >/dev/null 2>&1 || true
  ids=$(docker network ls -q --filter "label=fm.test=$RUN" 2>/dev/null) || ids=
  [ -z "$ids" ] || printf '%s\n' "$ids" | xargs docker network rm >/dev/null 2>&1 || true
  ids=$(docker volume ls -q --filter "label=fm.test=$RUN" 2>/dev/null) || ids=
  [ -z "$ids" ] || printf '%s\n' "$ids" | xargs docker volume rm >/dev/null 2>&1 || true
}
trap 'live_cleanup; fm_test_cleanup' EXIT

# create_container <name> [label=value]... : a stopped container carrying the run token.
create_container() {
  local name=$1 label args=()
  shift
  for label in "$@"; do args+=(--label "$label"); done
  docker create --name "$name" --label "fm.test=$RUN" "${args[@]+"${args[@]}"}" "$IMAGE" true >/dev/null \
    || fail "cannot create container $name from $IMAGE"
}

# create_network <name> [label=value]... : a labelled bridge network on an explicit
# subnet from the 198.18.0.0/15 benchmarking range. Docker's default address pools
# can be fully subnetted by leaked networks (observed 2026-10-08), and an explicit
# subnet needs no free pool, so the guard still reaches the code under test.
create_network() {
  local name=$1 label args=() octet
  shift
  for label in "$@"; do args+=(--label "$label"); done
  for _ in 1 2 3 4 5 6 7 8; do
    octet=$(( (RANDOM % 250) + 1 ))
    if docker network create --label "fm.test=$RUN" --subnet "198.18.$octet.0/24" \
        "${args[@]+"${args[@]}"}" "$name" >/dev/null 2>&1; then
      return 0
    fi
  done
  fail "cannot create network $name on any of 8 explicit subnets"
}

exists() { docker ps -a --format '{{.Names}}' | grep -Fxq "$1"; }
network_exists() { docker network ls --format '{{.Name}}' | grep -Fxq "$1"; }
volume_exists() { docker volume ls -q | grep -Fxq "$1"; }

test_real_docker_removes_only_the_tasks_own_objects() {
  local wt="$TMP_ROOT/wt" elsewhere="$TMP_ROOT/elsewhere" rc=0
  mkdir -p "$wt/stack" "$elsewhere/stack"
  fm_write_meta "$TMP_ROOT/$TASK.meta" "kind=ship"

  # The task's own: marker label, name, compose project, compose working dir.
  create_container "$TASK-pg"
  create_container "$RUN-labelled" "fm.task=$TASK"
  create_container "$RUN-proj" "com.docker.compose.project=$TASK"
  create_container "$RUN-path" "com.docker.compose.project=$RUN-default" \
    "com.docker.compose.project.working_dir=$wt/stack"
  # Not the task's: a longer sibling task's name, another task's marker, an
  # unmarked container, a stack from elsewhere, a Supabase-labelled container
  # for a project no task owns, and a name another task's marker overrides.
  create_container "$OTHER-pg"
  create_container "$RUN-foreign" "fm.task=$OTHER"
  create_container "$RUN-unmarked"
  create_container "$RUN-else" "com.docker.compose.project=$RUN-else" \
    "com.docker.compose.project.working_dir=$elsewhere/stack"
  create_container "$RUN-supa" "com.supabase.cli.project=$RUN-shared" "com.docker.compose.project=$RUN-shared"
  create_container "$TASK-claimed" "fm.task=$OTHER"

  create_network "$RUN-own-net" "fm.task=$TASK"
  create_network "$RUN-foreign-net" "fm.task=$OTHER"
  create_network "$RUN-supa-net" "com.docker.compose.project=$RUN-shared" "com.supabase.cli.project=$RUN-shared"
  docker volume create --label "fm.test=$RUN" --label "fm.task=$TASK" "$RUN-own-vol" >/dev/null || fail "volume create failed"
  docker volume create --label "fm.test=$RUN" "$RUN-unmarked-vol" >/dev/null || fail "volume create failed"
  docker volume create --label "fm.test=$RUN" --label "fm.task=$OTHER" "$RUN-foreign-vol" >/dev/null || fail "volume create failed"

  fm_task_docker_cleanup "$TASK" "$OTHER" 0 "" "$TMP_ROOT/$TASK.meta" "$wt" 2> "$TMP_ROOT/stderr" || rc=$?
  expect_code 0 "$rc" "real docker: cleanup should succeed: $(cat "$TMP_ROOT/stderr")"

  for gone in "$TASK-pg" "$RUN-labelled" "$RUN-proj" "$RUN-path"; do
    ! exists "$gone" || fail "real docker: the task's own container $gone survived"
  done
  for kept in "$OTHER-pg" "$RUN-foreign" "$RUN-unmarked" "$RUN-else" "$RUN-supa" "$TASK-claimed"; do
    exists "$kept" || fail "real docker: container $kept is not the task's and must survive"
  done
  ! network_exists "$RUN-own-net" || fail "real docker: the task's labelled network survived"
  network_exists "$RUN-foreign-net" || fail "real docker: another task's network was removed"
  network_exists "$RUN-supa-net" || fail "real docker: a Supabase-labelled network no task owns was removed"
  ! volume_exists "$RUN-own-vol" || fail "real docker: the task's labelled volume survived"
  volume_exists "$RUN-unmarked-vol" || fail "real docker: an unmarked named volume was removed"
  volume_exists "$RUN-foreign-vol" || fail "real docker: another task's volume was removed"
  pass "real Docker: the task's labelled, named, compose-project and worktree stacks are removed and every other object survives"
}

test_real_docker_ambiguous_id_trusts_only_the_worktree() {
  local wt="$TMP_ROOT/wt2" rc=0
  mkdir -p "$wt"
  fm_write_meta "$TMP_ROOT/$TASK.meta" "kind=ship"
  create_container "$TASK-ambig-pg"
  create_container "$RUN-ambig-labelled" "fm.task=$TASK"
  create_container "$RUN-ambig-path" "com.docker.compose.project=$RUN-ambig" \
    "com.docker.compose.project.working_dir=$wt"
  fm_task_docker_cleanup "$TASK" "" 1 "" "$TMP_ROOT/$TASK.meta" "$wt" 2> "$TMP_ROOT/stderr2" || rc=$?
  expect_code 0 "$rc" "real docker ambiguous: cleanup should succeed: $(cat "$TMP_ROOT/stderr2")"
  exists "$TASK-ambig-pg" || fail "real docker ambiguous: a name match was trusted though the id is ambiguous"
  exists "$RUN-ambig-labelled" || fail "real docker ambiguous: a label match was trusted though the id is ambiguous"
  ! exists "$RUN-ambig-path" || fail "real docker ambiguous: the worktree compose container survived"
  pass "real Docker: when the id is ambiguous across homes only a compose working directory under the worktree is trusted"
}

test_real_docker_excluded_nested_lane_path_is_left_alone() {
  local wt="$TMP_ROOT/wt3" rc=0
  mkdir -p "$wt/lane"
  fm_write_meta "$TMP_ROOT/$TASK.meta" "kind=ship"
  create_container "$RUN-lane" "com.docker.compose.project=$RUN-lane" \
    "com.docker.compose.project.working_dir=$wt/lane"
  create_container "$RUN-own" "com.docker.compose.project=$RUN-own" \
    "com.docker.compose.project.working_dir=$wt"
  # shellcheck disable=SC2329
  fm_task_docker_path_excluded() { case "$2" in "$wt"/lane*) return 0 ;; esac; return 1; }
  fm_task_docker_cleanup "$TASK" "" 0 "" "$TMP_ROOT/$TASK.meta" "$wt" 2> "$TMP_ROOT/stderr3" || rc=$?
  unset -f fm_task_docker_path_excluded
  expect_code 0 "$rc" "real docker lane: cleanup should succeed: $(cat "$TMP_ROOT/stderr3")"
  exists "$RUN-lane" || fail "real docker lane: a nested lane's container was removed"
  ! exists "$RUN-own" || fail "real docker lane: the worktree's own container survived"
  pass "real Docker: a compose project in a nested lane the task does not own is left alone"
}

test_real_docker_never_claims_the_projects_own_shared_stack() {
  local rc=0 wt="$TMP_ROOT/wt4"
  mkdir -p "$wt"
  fm_write_meta "$TMP_ROOT/$TASK.meta" "kind=ship"
  # A task whose id equals the project's name: the shared stack is named for the
  # project, so the name rules must not claim it. Its worktree compose project is
  # still the task's own.
  create_container "$RUN-shared-db" "com.docker.compose.project=$TASK" "com.supabase.cli.project=$TASK"
  create_container "$RUN-shared-path" "com.docker.compose.project=$RUN-sp" \
    "com.docker.compose.project.working_dir=$wt"
  create_network "$RUN-shared-net" "com.docker.compose.project=$TASK" "com.supabase.cli.project=$TASK"
  fm_task_docker_cleanup "$TASK" "" 0 "$TASK" "$TMP_ROOT/$TASK.meta" "$wt" 2> "$TMP_ROOT/stderr4" || rc=$?
  expect_code 0 "$rc" "real docker protected: cleanup should succeed: $(cat "$TMP_ROOT/stderr4")"
  exists "$RUN-shared-db" || fail "real docker protected: the project's shared stack container was removed"
  network_exists "$RUN-shared-net" || fail "real docker protected: the project's shared stack network was removed"
  ! exists "$RUN-shared-path" || fail "real docker protected: the worktree compose container survived"
  pass "real Docker: protected project identity vetoes every heuristic while an isolated worktree stack is removed"
}

test_real_docker_removes_only_the_tasks_own_objects
test_real_docker_ambiguous_id_trusts_only_the_worktree
test_real_docker_excluded_nested_lane_path_is_left_alone
test_real_docker_never_claims_the_projects_own_shared_stack
