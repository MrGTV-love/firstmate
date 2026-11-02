#!/usr/bin/env bash
# Behavior tests for the firstmate-repository publication boundary
# (bin/fm-role-lib.sh, bin/fm-role.sh, and its consumers).
#
# Every home runs as a user/operator by default: a ship task whose project is
# firstmate's own repository may carry a publishing contract (no-mistakes or
# direct-PR) only under an explicit grant - the maintainer scope written by
# the operator into config/firstmate-role, or a bounded per-task
# --upstream-consent recorded in the delivery contract. Role is never inferred
# from remotes, credentials, or repository ownership. In a secondmate home the
# grant is honored only when the inheritance receipt matches the exact bytes
# the parent published; the receipt guards supported propagation, not forged
# local records. local-only publishes nothing and never reaches the
# gate.
#
# These tests exercise the real entry points only: bin/fm-role.sh, the
# propagation owner bin/fm-config-inherit-lib.sh, bin/fm-brief.sh,
# bin/fm-spawn.sh, bin/fm-promote.sh, and fm_dod_block. Nothing here greps
# source for policy prose.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-role-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

ROLE="$ROOT/bin/fm-role.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-self-repo-role)
# Keep guard telemetry inside the fixture root: a refusal must not write into
# the checkout's own state directory while this suite runs.
export FM_GUARD_EVENT_LOG="$TMP_ROOT/guard-events.jsonl"
export FM_BACKEND=tmux

# The code root under test is this checkout, so self-repo detection reaches it
# through the shared git common dir. Its publication target is derived, never
# assumed: a checkout without an upstream/github/origin remote resolves to the
# undeterminable path and the scope-bound cases adapt.
PUB_TARGET=$(fm_role_publication_target "$ROOT")
# A no-mistakes task publishes to origin alone, so the spawn cases that ship
# mode=no-mistakes scope to that target.
PUB_TARGET_NM=$(fm_role_publication_target "$ROOT" no-mistakes)

# The no-mistakes gate also refuses a pipeline registration that names another
# destination, read from <NM_HOME>/state.sqlite. This fixture registry
# stands in for the operator's, so no case reads or writes the real one.
export NM_HOME="$TMP_ROOT/nm-home"
mkdir -p "$NM_HOME"
python3 -I - "$NM_HOME/state.sqlite" <<'PY' || fail "could not create the fixture no-mistakes registry"
import sqlite3, sys
con = sqlite3.connect(sys.argv[1])
con.execute("CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE, upstream_url TEXT NOT NULL, fork_url TEXT)")
con.commit()
PY

# nm_register <checkout> <upstream-url> - record a registration for <checkout>.
nm_register() {
  python3 -I - "$NM_HOME/state.sqlite" "$1" "$2" <<'PY' || fail "could not register $1 in the fixture registry"
import sqlite3, sys, uuid
con = sqlite3.connect(sys.argv[1])
con.execute("INSERT OR REPLACE INTO repos (id, working_path, upstream_url) VALUES (?, ?, ?)", (uuid.uuid4().hex[:12], sys.argv[2], sys.argv[3]))
con.commit()
PY
}
[ -z "$(git -C "$ROOT" remote get-url origin 2>/dev/null)" ] || nm_register "$ROOT" "$(git -C "$ROOT" remote get-url origin)"
ORIGIN_URL=$(git -C "$ROOT" remote get-url upstream 2>/dev/null) \
  || ORIGIN_URL=$(git -C "$ROOT" remote get-url github 2>/dev/null) \
  || ORIGIN_URL=$(git -C "$ROOT" remote get-url origin 2>/dev/null) \
  || ORIGIN_URL=

# make_role_home <name> [<role-file-content>]: a bare home whose only contents
# are config/ (optionally holding firstmate-role) plus the state/ and data/
# dirs the other consumers expect. Echoes the home path.
make_role_home() {
  local name=$1 content=${2-} home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/state" "$home/data"
  if [ $# -ge 2 ]; then
    printf '%s\n' "$content" > "$home/config/firstmate-role"
  fi
  printf '%s\n' "$home"
}

# git_commit <repo> <msg> - an empty commit with a fixed fixture identity.
git_commit() {
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m "$2" || fail "could not commit in $1"
}

# make_lineage_root <name> <origin-url> - a fixture firstmate code root with
# two commits and the given origin. Echoes its path.
make_lineage_root() {
  local root="$TMP_ROOT/$1"
  git init -q "$root" || fail "could not initialize $1 fixture"
  git_commit "$root" root
  git_commit "$root" second
  git -C "$root" remote add origin "$2"
  printf '%s\n' "$root"
}

# clone_with_origin <src> <name> <origin-url> - a separate clone of <src>
# (its own git dir, full history) whose origin is rewritten. Echoes its path.
clone_with_origin() {
  local clone="$TMP_ROOT/$2"
  git clone -q --shared --no-checkout "$1" "$clone" || fail "could not clone $1"
  git -C "$clone" remote set-url origin "$3"
  printf '%s\n' "$clone"
}

# check_as <code-root> <home> <args...> - fm-role.sh check against a fixture
# code root.
check_as() {
  local root=$1 home=$2
  shift 2
  FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROLE" check "$@" 2>&1
}

# run_role <home> <args...> - fm-role.sh pinned to a fixture home. FM_ROOT stays
# this checkout: the check command exists to compare a task's project against
# the running code root.
run_role() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" \
    "$ROLE" "$@" 2>&1
}

# --- report -----------------------------------------------------------------

test_report_default_and_local_grants() {
  local home out
  home=$(make_role_home report-default)
  out=$(run_role "$home" report)
  assert_equals "fm-role: user (default)" "$out" "an unconfigured home must report the user default"

  home=$(make_role_home report-user 'user')
  out=$(run_role "$home" report)
  assert_equals "fm-role: user (local)" "$out" "an explicit user directive must report user from the local file"

  home=$(make_role_home report-maint 'maintainer GitHub.COM/Org/Repo')
  out=$(run_role "$home" report)
  assert_equals "fm-role: maintainer github.com/org/repo (local)" "$out" \
    "a maintainer directive must report normalized scopes from the local file"
  pass "fm-role.sh report: default, user, and maintainer directives resolve"
}

test_report_fails_closed_on_unsafe_input() {
  local home out
  home=$(make_role_home report-bad1 'maintainer')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a scope-less maintainer directive must resolve to user"
  assert_contains "$out" "malformed role file" "a scope-less maintainer directive must report the narrow problem"

  home=$(make_role_home report-bad2 'admin github.com/a/b')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "an unknown role must resolve to user"
  assert_contains "$out" "unknown role 'admin'" "an unknown role must name itself in the reason"

  home=$(make_role_home report-bad3 'maintainer ../escape')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "an invalid scope must resolve to user"
  assert_contains "$out" "invalid repository scope" "an invalid scope must name the narrow problem"

  home=$(make_role_home report-symlink)
  printf 'maintainer github.com/a/b\n' > "$TMP_ROOT/report-symlink-target"
  ln -s "$TMP_ROOT/report-symlink-target" "$home/config/firstmate-role"
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a symlinked role file must resolve to user"
  assert_contains "$out" "must not be a symlink" "a symlinked role file must report the narrow problem"

  home=$(make_role_home report-two-directives "$(printf 'maintainer github.com/kunchenguid/firstmate\n# trailing\nuser')")
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a later directive must make the whole file malformed, not be ignored"
  assert_contains "$out" "exactly one directive line" "a second directive must name the narrow problem"

  home=$(make_role_home report-two-scopes 'maintainer github.com/kunchenguid/firstmate github.com/other/firstmate')
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a maintainer directive naming two scopes must resolve to user"
  assert_contains "$out" "exactly one repository scope" "a multi-scope directive must name the narrow problem"
  pass "fm-role.sh report: malformed, unknown, and unsafe input fails closed"
}

# --- check: the self-repository publication gate ----------------------------

test_check_user_home_refused_on_self_repo() {
  local home out rc
  home=$(make_role_home check-user)
  : > "$FM_GUARD_EVENT_LOG"
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 1 "$rc" "a user/operator home must be refused a publishing contract on firstmate itself"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_contains "$out" "no publication authority" "the refusal must name the missing grant"
  assert_contains "$out" "config/firstmate-role" "the refusal must name where authority is granted"
  assert_contains "$out" "--upstream-consent" "the refusal must name the one-task consent flag"
  [ "$(grep -c '"guard":"upstream-publish-role".*"decision":"deny"' "$FM_GUARD_EVENT_LOG")" -eq 1 ] \
    || fail "the refusal must append exactly one deny event"
  pass "fm-role.sh check: the default user/operator home cannot publish to firstmate upstream"
}

test_check_foreign_project_passes_through() {
  local home proj out rc
  home=$(make_role_home check-foreign)
  proj="$TMP_ROOT/foreign-proj"
  git init -q "$proj" || fail "could not initialize foreign project fixture"
  git -C "$proj" remote add origin https://github.com/someone/elseware.git
  out=$(run_role "$home" check "$proj"); rc=$?
  expect_code 2 "$rc" "an ordinary project must not be gated at all"
  assert_contains "$out" "not a self-repository task" "an ordinary project must be reported as outside the boundary"
  pass "fm-role.sh check: a task on an ordinary project is untouched by the boundary"
}

test_check_maintainer_scope_authorizes() {
  local home out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  home=$(make_role_home check-maint "maintainer $PUB_TARGET")
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 0 "$rc" "a matching maintainer scope must authorize (got: $out)"
  assert_contains "$out" "authorized: maintainer scope $PUB_TARGET" "the authority must name the matched scope"

  home=$(make_role_home check-maint-case "maintainer $(printf '%s' "$PUB_TARGET" | tr '[:lower:]' '[:upper:]')")
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 0 "$rc" "scope comparison must be case-insensitive (got: $out)"
  pass "fm-role.sh check: a matching maintainer scope authorizes the self-repository publication"
}

test_check_wrong_scope_and_remote_presence_do_not_authorize() {
  local home clone out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  # A maintainer grant for a different repository is no authority here, even
  # though the project's own remote IS the real upstream: role is never
  # inferred from the remote itself.
  home=$(make_role_home check-other 'maintainer github.com/other/firstmate')
  out=$(run_role "$home" check "$ROOT"); rc=$?
  expect_code 1 "$rc" "a non-matching maintainer scope must be refused"
  assert_contains "$out" "no publication authority for $PUB_TARGET" \
    "the refusal must name the target the grant did not cover"

  # A second clone of the same upstream (shared history, different git dir)
  # is still firstmate's repository: the boundary follows lineage, not the
  # checkout path.
  home=$(make_role_home check-clone)
  clone=$(clone_with_origin "$ROOT" second-clone "$ORIGIN_URL")
  out=$(run_role "$home" check "$clone"); rc=$?
  expect_code 1 "$rc" "a second clone of the same upstream must still be gated"
  assert_contains "$out" "user/operator" "a second clone must be treated as firstmate's own repository"
  pass "fm-role.sh check: scope mismatch and mere upstream remote presence never authorize"
}

# Equivalent remote spellings of one upstream (trailing slash, .git suffix,
# scp form) must normalize to one publication target, so the maintainer scope
# matches every clone. The code root is a fixture, independent of this
# checkout's own remotes.
test_check_equivalent_remote_spellings_are_one_repo() {
  local root clone url user_home maint_home out rc n=0
  root=$(make_lineage_root spelling-root https://github.com/kunchenguid/firstmate)
  user_home=$(make_role_home spelling-user)
  maint_home=$(make_role_home spelling-maint 'maintainer github.com/kunchenguid/firstmate')
  for url in https://github.com/kunchenguid/firstmate.git/ \
    https://github.com/kunchenguid/firstmate/ \
    git@github.com:kunchenguid/firstmate.git/; do
    n=$((n + 1))
    clone=$(clone_with_origin "$root" "spelling-clone-$n" "$url")
    out=$(check_as "$root" "$user_home" "$clone"); rc=$?
    expect_code 1 "$rc" "a clone of $url must be gated as firstmate (got: $out)"
    out=$(check_as "$root" "$maint_home" "$clone"); rc=$?
    expect_code 0 "$rc" "the maintainer scope must cover a clone of $url (got: $out)"
  done
  pass "fm-role.sh check: equivalent remote spellings resolve to one publication target"
}

# Firstmate run from a fork, dispatching to a separate clone of the parent:
# their origins and git dirs differ, but they share firstmate's root commit,
# so the task still meets the role/consent gate. A fork's maintainer scope
# does not cover the parent; one-task consent for the parent does.
test_check_fork_lineage_reaches_the_gate() {
  local fork parent user_home fork_home out rc
  fork=$(make_lineage_root fork-root https://github.com/someone/firstmate-fork)
  parent=$(clone_with_origin "$fork" parent-clone https://github.com/kunchenguid/firstmate)
  user_home=$(make_role_home fork-user)
  out=$(check_as "$fork" "$user_home" "$parent"); rc=$?
  expect_code 1 "$rc" "a parent clone dispatched from a fork code root must be gated (got: $out)"
  assert_contains "$out" "no publication authority for github.com/kunchenguid/firstmate" \
    "the refusal must name the parent publication target"

  fork_home=$(make_role_home fork-maint 'maintainer github.com/someone/firstmate-fork')
  out=$(check_as "$fork" "$fork_home" "$parent"); rc=$?
  expect_code 1 "$rc" "a fork maintainer scope must not cover the parent (got: $out)"

  out=$(check_as "$fork" "$user_home" "$parent" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 0 "$rc" "one-task consent for the parent must authorize (got: $out)"

  git init -q "$TMP_ROOT/fork-unrelated" || fail "could not initialize unrelated fixture"
  git_commit "$TMP_ROOT/fork-unrelated" unrelated
  git -C "$TMP_ROOT/fork-unrelated" remote add origin https://github.com/kunchenguid/firstmate
  out=$(check_as "$fork" "$user_home" "$TMP_ROOT/fork-unrelated"); rc=$?
  expect_code 2 "$rc" "an unrelated history is not firstmate even with a firstmate remote (got: $out)"
  pass "fm-role.sh check: repository lineage, not remotes, identifies firstmate across forks"
}

# Lineage that cannot be determined refuses, and a firstmate-lineage project
# with no determinable publication target is refused even under consent.
test_check_undeterminable_lineage_and_target_refuse() {
  local root shallow bare home out rc
  root=$(make_lineage_root undet-root https://github.com/kunchenguid/firstmate)
  home=$(make_role_home undet-user)
  shallow="$TMP_ROOT/undet-shallow"
  git clone -q --depth 1 "file://$root" "$shallow" || fail "could not make a shallow clone"
  git -C "$shallow" remote set-url origin https://github.com/kunchenguid/firstmate
  out=$(check_as "$root" "$home" "$shallow" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "a shallow clone sharing no root commit must be refused (got: $out)"
  assert_contains "$out" "cannot determine whether" "the refusal must name undeterminable lineage"

  bare=$(clone_with_origin "$root" undet-no-remote https://github.com/kunchenguid/firstmate)
  git -C "$bare" remote remove origin
  out=$(check_as "$root" "$home" "$bare" upstream-consent github.com/kunchenguid/firstmate); rc=$?
  expect_code 1 "$rc" "consent must not authorize an undeterminable publication target (got: $out)"
  assert_contains "$out" "no publication target can be determined" "the refusal must name the missing target"
  pass "fm-role.sh check: undeterminable lineage or publication target refuses"
}

test_check_task_consent_authorizes_one_task() {
  local home out rc
  [ -n "$PUB_TARGET" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  home=$(make_role_home check-consent)
  out=$(run_role "$home" check "$ROOT" upstream-consent "$PUB_TARGET"); rc=$?
  expect_code 0 "$rc" "a matching one-task consent must authorize a user home (got: $out)"
  assert_contains "$out" "authorized: task consent for $PUB_TARGET" "the authority must be recorded as task consent"

  out=$(run_role "$home" check "$ROOT" upstream-consent github.com/other/repo); rc=$?
  expect_code 1 "$rc" "a consent naming a different repository must be refused"
  assert_contains "$out" "no publication authority for $PUB_TARGET" \
    "a mismatched consent must not widen into a grant"
  pass "fm-role.sh check: recorded one-task consent authorizes its named repository only"
}

# --- secondmate homes: receipt-proven grants only ---------------------------

# In a secondmate home (its .fm-secondmate-home marker) a role file without a
# propagation receipt resolves to user.
test_secondmate_cannot_self_grant() {
  local home out rc
  home=$(make_role_home sm-selfgrant "maintainer ${PUB_TARGET:-github.com/a/b}")
  : > "$home/.fm-secondmate-home"
  out=$(run_role "$home" report)
  assert_contains "$out" "fm-role: user" "a self-planted role file must not grant a secondmate anything"
  assert_contains "$out" "no propagation receipt" "the report must name the missing receipt"
  if [ -n "$PUB_TARGET" ]; then
    out=$(run_role "$home" check "$ROOT"); rc=$?
    expect_code 1 "$rc" "a self-granted secondmate must be refused at the gate"
  fi
  pass "secondmate home: a role file without an inheritance receipt grants nothing"
}

# The real propagation path (fm-config-inherit-lib.sh) both carries the file
# and writes the exact-byte receipt; the resolved role then reads as
# inherited, revocation mirrors the parent's removal, and any local edit
# invalidates the proof.
test_secondmate_inheritance_receipt_lifecycle() {
  local src dst_config sm_home out rc receipt
  src="$TMP_ROOT/inherit-src-config"
  dst_config="$TMP_ROOT/inherit-sm/config"
  sm_home="$TMP_ROOT/inherit-sm"
  mkdir -p "$src" "$dst_config" "$sm_home/state" "$sm_home/data"
  : > "$sm_home/.fm-secondmate-home"
  receipt="$dst_config/.fm-inherit-firstmate-role.generation"

  printf 'maintainer %s\n' "${PUB_TARGET:-github.com/kunchenguid/firstmate}" > "$src/firstmate-role"
  FM_INHERITABLE_CONFIG=firstmate-role propagate_inheritable_config "$src" "$dst_config" \
    || fail "local propagation of firstmate-role failed"
  assert_present "$dst_config/firstmate-role" "propagation did not copy the role file"
  assert_present "$receipt" "propagation did not commit the role receipt"
  out=$(run_role "$sm_home" report)
  assert_equals "fm-role: maintainer ${PUB_TARGET:-github.com/kunchenguid/firstmate} (inherited)" "$out" \
    "a receipt-proven inherited grant must resolve to maintainer"
  if [ -n "$PUB_TARGET" ]; then
    out=$(run_role "$sm_home" check "$ROOT"); rc=$?
    expect_code 0 "$rc" "an inherited matching scope must authorize at the gate (got: $out)"
  fi

  # Local drift after propagation invalidates the exact-byte proof.
  printf 'maintainer github.com/evil/scope\n' > "$dst_config/firstmate-role"
  out=$(run_role "$sm_home" report)
  assert_contains "$out" "fm-role: user" "a locally edited inherited grant must die"
  assert_contains "$out" "unverified inherited grant" "a diverged grant must name the unverified state"
  assert_contains "$out" "diverges from the receipt" "a diverged grant must name the divergence"

  # The receipt proves consistency, not provenance: a deliberately forged
  # local record is out of scope. Rewriting the receipt here only exercises
  # how an inherited file with a second directive parses: it is malformed as
  # a whole even when its receipt matches the exact bytes.
  gen=$(sed -n '1p' "$receipt")
  printf 'maintainer %s\nuser\n' "${PUB_TARGET:-github.com/kunchenguid/firstmate}" > "$dst_config/firstmate-role"
  {
    printf '%s\n' "$((gen + 1))"
    wc -c <"$dst_config/firstmate-role" | tr -d '[:space:]' | awk '{printf "%s\n", $1}'
    fm_role_sha256_stdin <"$dst_config/firstmate-role"
    printf 'put\n'
  } > "$receipt"
  out=$(run_role "$sm_home" report)
  assert_contains "$out" "fm-role: user" "an inherited file with two directives must resolve to user"
  assert_contains "$out" "malformed inherited role" "an inherited two-directive file must be named malformed"

  # Revocation: the parent's role file disappears, so propagation removes the
  # destination file and records the absence in the receipt.
  printf 'maintainer %s\n' "${PUB_TARGET:-github.com/kunchenguid/firstmate}" > "$dst_config/firstmate-role"
  rm "$src/firstmate-role"
  FM_INHERITABLE_CONFIG=firstmate-role propagate_inheritable_config "$src" "$dst_config" \
    || fail "revocation propagation of firstmate-role failed"
  assert_absent "$dst_config/firstmate-role" "revocation did not remove the inherited role file"
  assert_present "$receipt" "revocation dropped the receipt that proves absence"
  [ "$(sed -n '4p' "$receipt")" = absent ] || fail "revocation did not record an absent receipt"
  out=$(run_role "$sm_home" report)
  assert_equals "fm-role: user (inherited)" "$out" "a revoked grant must resolve to user"

  # Once revoked, a role file planted locally still has only the absent
  # receipt to its name and grants nothing.
  printf 'maintainer %s\n' "${PUB_TARGET:-github.com/kunchenguid/firstmate}" > "$dst_config/firstmate-role"
  out=$(run_role "$sm_home" report)
  assert_contains "$out" "fm-role: user" "a post-revocation self-plant must grant nothing"
  assert_contains "$out" "unverified inherited grant" "a self-plant after revocation must be named unverified"
  pass "secondmate home: inherited grants need a matching receipt; receipt-less and revoked grants are dead"
}

# The parent publishes its resolved role, not its raw file: a primary role
# file the primary's own resolver rejects (symlinked or malformed) propagates
# as revocation, never as a copied grant.
test_secondmate_inherits_only_resolved_primary_role() {
  local src dst_config sm_home out receipt scope bad
  scope=${PUB_TARGET:-github.com/kunchenguid/firstmate}
  src="$TMP_ROOT/resolved-src-home/config"
  sm_home="$TMP_ROOT/resolved-sm"
  dst_config="$sm_home/config"
  mkdir -p "$src" "$dst_config" "$sm_home/state" "$sm_home/data"
  : > "$sm_home/.fm-secondmate-home"
  receipt="$dst_config/.fm-inherit-firstmate-role.generation"

  for bad in symlink two-directives; do
    rm -f "$src/firstmate-role"
    printf '# operator note\nmaintainer %s\n' "$scope" > "$src/firstmate-role"
    FM_INHERITABLE_CONFIG=firstmate-role propagate_inheritable_config "$src" "$dst_config" \
      || fail "propagation of a valid primary grant failed"
    out=$(run_role "$sm_home" report)
    assert_equals "fm-role: maintainer $scope (inherited)" "$out" "a valid primary grant must be inherited"

    rm -f "$src/firstmate-role"
    case $bad in
    symlink)
      printf 'maintainer %s\n' "$scope" > "$TMP_ROOT/resolved-symlink-target"
      ln -s "$TMP_ROOT/resolved-symlink-target" "$src/firstmate-role"
      ;;
    two-directives)
      printf 'maintainer %s\nuser\n' "$scope" > "$src/firstmate-role"
      ;;
    esac
    out=$(FM_HOME="$TMP_ROOT/resolved-src-home" FM_CONFIG_OVERRIDE="$src" "$ROLE" report 2>&1)
    assert_contains "$out" "fm-role: user" "the $bad primary role file must resolve to user on the primary"
    FM_INHERITABLE_CONFIG=firstmate-role propagate_inheritable_config "$src" "$dst_config" \
      || fail "propagation of a rejected $bad primary role failed"
    assert_absent "$dst_config/firstmate-role" "a rejected $bad primary role must not be copied downstream"
    [ "$(sed -n '4p' "$receipt")" = absent ] || fail "a rejected $bad primary role must record an absent receipt"
    out=$(run_role "$sm_home" report)
    assert_equals "fm-role: user (inherited)" "$out" "a rejected $bad primary role must revoke the secondmate grant"
  done
  pass "secondmate home: a primary role its own resolver rejects propagates as revocation"
}

# --- delivery contract rendering --------------------------------------------

test_dod_block_renders_and_bounds_consent() {
  local out rc
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-dod-lib.sh"
  out=$(fm_dod_block direct-PR consent-id fm/consent-id none '' github.com/kunchenguid/firstmate)
  assert_contains "$out" "Delivery contract: mode=direct-PR upstream-consent=github.com/kunchenguid/firstmate" \
    "a publishing contract must render the recorded consent token"
  out=$(fm_dod_block direct-PR noconsent-id fm/noconsent-id)
  assert_not_contains "$out" "upstream-consent" "a contract without consent must not render the token"
  out=$(fm_dod_block local-only local-id fm/local-id none '' github.com/a/b 2>&1); rc=$?
  expect_code 1 "$rc" "local-only must refuse a consent token it can never spend"
  pass "fm_dod_block: upstream consent renders on publishing contracts and is refused on local-only"
}

# --- fm-brief.sh ------------------------------------------------------------

test_brief_consent_flag_bounds() {
  local home out rc brief
  home=$(make_role_home brief-user)
  brief="$home/data/brief-consent-ok/brief.md"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-bad some-proj --mode direct-PR --upstream-consent 'not a scope' 2>&1); rc=$?
  expect_code 1 "$rc" "an invalid consent scope must be refused"
  assert_contains "$out" "must be <host>/<owner>/<repo>" "an invalid consent scope must name the schema"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-scout some-proj --scout --upstream-consent github.com/a/b 2>&1); rc=$?
  expect_code 1 "$rc" "a scout must refuse a consent it can never spend"
  assert_contains "$out" "applies only to ship briefs" "a scout consent refusal must name the boundary"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-local some-proj --mode local-only --upstream-consent github.com/a/b 2>&1); rc=$?
  expect_code 1 "$rc" "local-only must refuse a consent it publishes nothing with"
  assert_contains "$out" "local-only" "a local-only consent refusal must name the mode"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-consent-ok some-proj --mode direct-PR --upstream-consent GitHub.COM/KunChenGuid/FirstMate 2>&1); rc=$?
  expect_code 0 "$rc" "a valid consent must scaffold (got: $out)"
  assert_grep "upstream-consent=github.com/kunchenguid/firstmate" "$brief" \
    "the scaffolded brief must carry the normalized consent token"
  pass "fm-brief.sh: --upstream-consent validates, scopes to ship tasks, and renders normalized"
}

test_brief_self_repo_pre_gate() {
  local home out rc
  home=$(make_role_home brief-selfrepo)
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" brief-selfrefuse some-proj --mode direct-PR --project "$ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "a user home must be refused a publishing brief for firstmate itself"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_contains "$out" "no publication authority" "the refusal must name the missing grant"

  if [ -n "$PUB_TARGET" ]; then
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      "$BRIEF" brief-selfconsent some-proj --mode direct-PR --project "$ROOT" \
      --upstream-consent "$PUB_TARGET" 2>&1); rc=$?
    expect_code 0 "$rc" "recorded consent must let the same scaffold through (got: $out)"
    assert_grep "upstream-consent=$PUB_TARGET" "$home/data/brief-selfconsent/brief.md" \
      "the consented scaffold must record the consent"
  fi

  home=$(make_role_home brief-maint "maintainer ${PUB_TARGET:-github.com/x/y}")
  if [ -n "$PUB_TARGET" ]; then
    out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      "$BRIEF" brief-selfmaint some-proj --mode direct-PR --project "$ROOT" 2>&1); rc=$?
    expect_code 0 "$rc" "a matching maintainer home must scaffold a self-repo publishing brief (got: $out)"
  fi
  pass "fm-brief.sh: --project applies the self-repository gate at scaffold time"
}

# --- fm-spawn.sh ------------------------------------------------------------

# A thin spawn fixture: home, a project arg resolved to the code root itself,
# and a brief whose delivery contract the spawn must agree with. The fake tmux
# exits 1 so an authorized spawn stops at launch rather than a worktree.
SPAWN_FAKEBIN="$TMP_ROOT/spawn-fakebin"
mkdir -p "$SPAWN_FAKEBIN"
fm_test_link_ts_runtime "$SPAWN_FAKEBIN"
printf '#!/bin/sh\nexit 1\n' > "$SPAWN_FAKEBIN/tmux"
chmod +x "$SPAWN_FAKEBIN/tmux"

write_ship_brief() {  # <home> <id> [<contract-extras>]
  local home=$1 id=$2 extras=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the role gate.\n\n## Firstmate spec\nVerify the boundary.\n\n# Definition of done\n'
    printf 'Delivery contract: mode=no-mistakes%s\nShip branch: fm/%s\n' "$extras" "$id"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <spawn-args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$SPAWN_FAKEBIN:$BASE_PATH" \
    "$SPAWN" "$@" 2>&1
}
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

test_spawn_gate_on_self_repo() {
  local home out rc
  home=$(make_role_home spawn-user)
  write_ship_brief "$home" spawn-self-a1
  out=$(run_spawn "$home" spawn-self-a1 "$ROOT" claude --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "a user home must not launch a publishing task on firstmate itself"
  assert_contains "$out" "spawn refused for spawn-self-a1" "the refusal must name the task"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_absent "$home/state/spawn-self-a1.meta" "a refused spawn must write no task metadata"

  if [ -n "$PUB_TARGET_NM" ]; then
    home=$(make_role_home spawn-maint "maintainer $PUB_TARGET_NM")
    write_ship_brief "$home" spawn-self-a2
    out=$(run_spawn "$home" spawn-self-a2 "$ROOT" claude --mode no-mistakes --yolo off)
    assert_not_contains "$out" "spawn refused" "a matching maintainer home must pass the gate"
    assert_not_contains "$out" "user/operator" "a matching maintainer home must not be told it lacks authority"
  fi
  pass "fm-spawn.sh: the launch gate refuses a user/operator home and passes a matching maintainer"
}

test_spawn_consent_agreement() {
  local home out rc
  [ -n "$PUB_TARGET_NM" ] || {
    printf '# skip - checkout has no upstream/github/origin remote to scope\n'
    return
  }
  home=$(make_role_home spawn-consent)

  # Consent on the flag but not the brief: the two sides of the record must
  # agree, or the worker's contract and the task's authority diverge.
  write_ship_brief "$home" spawn-consent-b1
  rc=0
  out=$(run_spawn "$home" spawn-consent-b1 "$ROOT" claude --mode no-mistakes --yolo off \
    --upstream-consent "$PUB_TARGET_NM") || rc=$?
  [ "$rc" -ne 0 ] || fail "a flag-without-brief consent must refuse"
  assert_contains "$out" "upstream-consent mismatch for spawn-consent-b1" \
    "a flag without a matching brief token must refuse"
  assert_absent "$home/state/spawn-consent-b1.meta" "a mismatched spawn must write no metadata"

  # Consent on the brief but not the flag: same divergence, other direction.
  write_ship_brief "$home" spawn-consent-b2 " upstream-consent=$PUB_TARGET_NM"
  rc=0
  out=$(run_spawn "$home" spawn-consent-b2 "$ROOT" claude --mode no-mistakes --yolo off) || rc=$?
  [ "$rc" -ne 0 ] || fail "a brief-without-flag consent must refuse"
  assert_contains "$out" "upstream-consent mismatch for spawn-consent-b2" \
    "a brief token without the flag must refuse"

  # Both sides agree: the consent carries the task through the gate on a
  # user/operator home.
  write_ship_brief "$home" spawn-consent-b3 " upstream-consent=$PUB_TARGET_NM"
  out=$(run_spawn "$home" spawn-consent-b3 "$ROOT" claude --mode no-mistakes --yolo off \
    --upstream-consent "$PUB_TARGET_NM")
  assert_not_contains "$out" "spawn refused" "matching consent must pass the gate"
  assert_not_contains "$out" "upstream-consent mismatch" "agreeing sides must not be reported as a mismatch"

  # Consent on a foreign project is harmless: the boundary does not apply and
  # the spawn passes the gate to whatever fails after.
  local proj="$TMP_ROOT/consent-foreign"
  git init -q "$proj" || fail "could not initialize foreign fixture"
  git -C "$proj" remote add origin https://github.com/someone/elseware.git
  write_ship_brief "$home" spawn-consent-b4 " upstream-consent=$PUB_TARGET_NM"
  out=$(run_spawn "$home" spawn-consent-b4 "$proj" claude --mode no-mistakes --yolo off \
    --upstream-consent "$PUB_TARGET_NM")
  assert_not_contains "$out" "spawn refused" "consent on an ordinary project must not be gated"

  # Consent on local-only is refused before any gate: it names a publication
  # local-only never performs.
  write_ship_brief "$home" spawn-consent-b5
  rc=0
  out=$(run_spawn "$home" spawn-consent-b5 "$ROOT" claude --mode local-only --yolo off \
    --upstream-consent "$PUB_TARGET_NM") || rc=$?
  [ "$rc" -ne 0 ] || fail "local-only must refuse a consent flag"
  assert_contains "$out" "meaningless on local-only" "local-only must refuse a consent flag"
  pass "fm-spawn.sh: consent must agree between flag and brief, and is refused on local-only"
}

# --- fm-promote.sh ----------------------------------------------------------

test_promote_gate_on_self_repo() {
  local home meta out rc
  home=$(make_role_home promote-user)
  meta="$home/state/promote-r1.meta"
  printf 'window=fm-promote-r1\nkind=scout\nproject=%s\nworktree=/tmp/wt\n' "$ROOT" > "$meta"
  mkdir -p "$home/data/promote-r1"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nInvestigate a firstmate bug.\n\n## Firstmate spec\nReport findings.\n' \
    > "$home/data/promote-r1/brief.md"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$PROMOTE" promote-r1 --mode direct-PR --yolo off 2>&1); rc=$?
  expect_code 1 "$rc" "a user home must not promote a self-repo scout into a publishing ship"
  assert_contains "$out" "promotion refused for promote-r1" "the refusal must name the task"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_grep 'kind=scout' "$meta" "a refused promotion must leave the scout kind untouched"
  assert_absent "$home/data/promote-r1/ship-instructions.md" "a refused promotion must publish no instructions"

  if [ -n "$PUB_TARGET" ]; then
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" \
      "$PROMOTE" promote-r1 --mode direct-PR --yolo off --upstream-consent "$PUB_TARGET" 2>&1); rc=$?
    expect_code 0 "$rc" "recorded consent must let the same promotion through (got: $out)"
    assert_grep 'upstream_consent=' "$meta" "the promoted task record must carry the consent"
    assert_grep "upstream-consent=$PUB_TARGET" "$home/data/promote-r1/ship-instructions.md" \
      "the promoted ship instructions must render the consent token"
  fi
  pass "fm-promote.sh: the self-repository gate governs promotion identically to spawn"
}

test_secondmate_spawn_refuses_consent_flag() {
  local home out
  home=$(make_role_home spawn-sm)
  mkdir -p "$home/data/spawn-sm-c1"
  printf 'You are a secondmate.\n' > "$home/data/spawn-sm-c1/brief.md"
  rc=0
  out=$(run_spawn "$home" spawn-sm-c1 "$home" --secondmate --mode no-mistakes --yolo off \
    --upstream-consent github.com/a/b 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a secondmate charter must refuse a consent flag"
  assert_contains "$out" "applies only to ship spawns" "a secondmate charter must refuse a consent flag"
  pass "fm-spawn.sh: --upstream-consent is refused on secondmate charters"
}

# --- publication target follows the delivery mode ---------------------------

# make_two_remote_project <name> <origin-url> <upstream-url> [<registered-url>]
# - a fixture project sharing this checkout's history whose origin and upstream
# remotes name two different repositories (no upstream remote when
# <upstream-url> is empty). The no-mistakes registry records <registered-url>
# for it, defaulting to origin; the word none leaves it unregistered. Echoes
# its path. Fails the test when the checkout's history cannot seed a lineage
# clone: a skipped fixture would hide the regression it guards.
make_two_remote_project() {
  local proj="$TMP_ROOT/$1"
  git clone -q --shared --no-checkout "$ROOT" "$proj" 2>/dev/null || fail "could not clone $ROOT for fixture $1"
  git -C "$proj" remote set-url origin "$2" 2>/dev/null || git -C "$proj" remote add origin "$2"
  [ -z "${3:-}" ] || git -C "$proj" remote add upstream "$3"
  fm_role_self_repo "$proj" "$ROOT" || fail "fixture $1 does not share this checkout's lineage (full history required)"
  [ "${4:-}" = none ] || nm_register "$proj" "${4:-$2}"
  printf '%s\n' "$proj"
}

TARGET_A=github.com/fixture-a/firstmate
TARGET_B=github.com/fixture-b/firstmate
URL_A=https://github.com/fixture-a/firstmate
URL_B=https://github.com/fixture-b/firstmate

# The reported publish-guard bug: a no-mistakes task opens its pull request
# against origin, but the gate used to check the upstream remote instead. One
# test per user-facing entry point so each reports its own result.
test_nomistakes_origin_consent_passes_role_check() {
  local proj home out rc
  proj=$(make_two_remote_project two-remote-check "$URL_A" "$URL_B")
  home=$(make_role_home nm-origin-check)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "consent for origin must authorize a no-mistakes task (got: $out)"
  assert_equals "authorized: task consent for $TARGET_A" "$out" "the reported target must be the origin repository"
  pass "fm-role.sh check: no-mistakes consent for origin passes and reports the origin repository"
}

test_nomistakes_origin_consent_passes_brief() {
  local proj home out rc
  proj=$(make_two_remote_project two-remote-brief "$URL_A" "$URL_B")
  home=$(make_role_home nm-origin-brief-home)
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" nm-origin-brief some-proj --mode no-mistakes --project "$proj" \
    --upstream-consent "$TARGET_A" 2>&1); rc=$?
  expect_code 0 "$rc" "the brief scaffold must pass the gate for origin consent (got: $out)"
  assert_grep "upstream-consent=$TARGET_A" "$home/data/nm-origin-brief/brief.md" \
    "the scaffold must record the consent"
  pass "fm-brief.sh: no-mistakes consent for origin passes the scaffold gate"
}

test_nomistakes_origin_consent_passes_spawn() {
  local proj home out
  proj=$(make_two_remote_project two-remote-spawn "$URL_A" "$URL_B")
  home=$(make_role_home nm-origin-spawn-home)
  write_ship_brief "$home" nm-origin-spawn " upstream-consent=$TARGET_A"
  out=$(run_spawn "$home" nm-origin-spawn "$proj" claude --mode no-mistakes --yolo off \
    --upstream-consent "$TARGET_A")
  assert_not_contains "$out" "spawn refused" "the spawn gate must pass for origin consent (got: $out)"
  assert_not_contains "$out" "no publication authority" "the spawn gate must not name a missing grant"
  pass "fm-spawn.sh: no-mistakes consent for origin passes the launch gate"
}

test_nomistakes_origin_consent_passes_promote() {
  local proj home out rc
  proj=$(make_two_remote_project two-remote-promote "$URL_A" "$URL_B")
  home=$(make_role_home nm-origin-promote-home)
  mkdir -p "$home/data/nm-origin-promote"
  printf 'project=%s\nkind=scout\nwindow=fm-nm-origin-promote\nworktree=/tmp/wt\n' "$proj" > "$home/state/nm-origin-promote.meta"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nInvestigate.\n\n## Firstmate spec\nReport.\n' \
    > "$home/data/nm-origin-promote/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$PROMOTE" nm-origin-promote --mode no-mistakes --yolo off --upstream-consent "$TARGET_A" 2>&1); rc=$?
  expect_code 0 "$rc" "promotion must pass the gate for origin consent (got: $out)"
  assert_grep "upstream-consent=$TARGET_A" "$home/data/nm-origin-promote/ship-instructions.md" \
    "the promoted instructions must record the consent"
  pass "fm-promote.sh: no-mistakes consent for origin passes the promotion gate"
}

# Consent or a maintainer scope for any repository but the one origin names
# must never carry a no-mistakes task, and the refusal names that repository.
test_nomistakes_gate_refuses_what_origin_does_not_name() {
  local proj home out rc
  proj=$(make_two_remote_project nm-neg "$URL_A" "$URL_B")

  home=$(make_role_home nm-neg-wrongconsent)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_B" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "consent for the upstream repository must not carry a no-mistakes task (got: $out)"
  assert_contains "$out" "no publication authority for $TARGET_A" "the refusal must name the origin repository"

  out=$(run_role "$home" check "$proj" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a user/operator home with no consent must be refused (got: $out)"
  assert_contains "$out" "user/operator" "the refusal must name the role"
  assert_contains "$out" "no publication authority for $TARGET_A" "the refusal must name the origin repository"

  home=$(make_role_home nm-neg-maint-b "maintainer $TARGET_B")
  out=$(run_role "$home" check "$proj" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a maintainer scope for the upstream repository must not carry a no-mistakes task (got: $out)"
  assert_contains "$out" "no publication authority for $TARGET_A" "the refusal must name the origin repository"

  home=$(make_role_home nm-neg-maint-a "maintainer $TARGET_A")
  out=$(run_role "$home" check "$proj" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a maintainer scope for the origin repository must authorize (got: $out)"
  assert_equals "authorized: maintainer scope $TARGET_A" "$out" "the authority must name the origin scope"

  # The same refusals come through the entry points that print the remedy.
  home=$(make_role_home nm-neg-entry)
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" nm-neg-brief some-proj --mode no-mistakes --project "$proj" \
    --upstream-consent "$TARGET_B" 2>&1); rc=$?
  expect_code 1 "$rc" "the brief scaffold must refuse consent for the wrong repository (got: $out)"
  assert_contains "$out" "--upstream-consent $TARGET_A" "the remedy must name the origin repository"
  write_ship_brief "$home" nm-neg-spawn " upstream-consent=$TARGET_B"
  out=$(run_spawn "$home" nm-neg-spawn "$proj" claude --mode no-mistakes --yolo off \
    --upstream-consent "$TARGET_B"); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must refuse consent for the wrong repository"
  assert_contains "$out" "spawn refused for nm-neg-spawn" "the spawn refusal must name the task"
  assert_contains "$out" "no publication authority for $TARGET_A" "the spawn refusal must name the origin repository"
  assert_absent "$home/state/nm-neg-spawn.meta" "a refused spawn must write no task metadata"
  pass "no-mistakes gate: only the origin repository's grant authorizes, and refusals name it"
}

test_nomistakes_gate_refuses_unknown_destination() {
  local proj home out rc
  proj=$(make_two_remote_project nm-noorigin "$URL_A" "$URL_B")
  git -C "$proj" remote remove origin
  home=$(make_role_home nm-noorigin-user)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_B" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a no-mistakes task with no origin remote must be refused even under consent for upstream (got: $out)"
  assert_contains "$out" "no publication target can be determined" "the refusal must name the missing destination"
  assert_contains "$out" "origin remote" "the refusal must name the remote no-mistakes targets"

  home=$(make_role_home nm-noorigin-maint "maintainer $TARGET_B")
  out=$(run_role "$home" check "$proj" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a maintainer scope must not authorize a no-mistakes task with no origin remote (got: $out)"

  # The gh-based path still finds the upstream remote it always did.
  out=$(run_role "$home" check "$proj" mode direct-PR); rc=$?
  expect_code 0 "$rc" "direct-PR keeps resolving the upstream remote (got: $out)"
  pass "no-mistakes gate: an unknown destination is refused"
}

# Delivery paths that publish through gh keep their resolution: upstream, then
# github, then origin. A repo with one remote resolves the same for every mode.
# These assertions hold identically on the base revision.
test_gh_delivery_resolution_is_unchanged() {
  local proj home out rc mode
  proj=$(make_two_remote_project gh-two "$URL_A" "$URL_B")
  home=$(make_role_home gh-user)
  for mode in direct-PR ''; do
    out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" ${mode:+mode "$mode"}); rc=$?
    expect_code 1 "$rc" "consent for origin must not carry a gh-based task whose default is upstream (mode '${mode:-none}', got: $out)"
    assert_contains "$out" "no publication authority for $TARGET_B" "the refusal must name the gh default repository"
    out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_B" ${mode:+mode "$mode"}); rc=$?
    expect_code 0 "$rc" "consent for the gh default must authorize (mode '${mode:-none}', got: $out)"
    assert_equals "authorized: task consent for $TARGET_B" "$out" "the gh default must be the reported target"
  done

  git -C "$proj" remote add github https://github.com/fixture-c/firstmate
  git -C "$proj" remote remove upstream
  out=$(run_role "$home" check "$proj" upstream-consent github.com/fixture-c/firstmate mode direct-PR); rc=$?
  expect_code 0 "$rc" "github still outranks origin for a gh-based task (got: $out)"

  local solo
  solo=$(make_two_remote_project origin-only "$URL_A" '')
  for mode in no-mistakes direct-PR ''; do
    out=$(run_role "$home" check "$solo" upstream-consent "$TARGET_A" ${mode:+mode "$mode"}); rc=$?
    expect_code 0 "$rc" "an origin-only repository resolves to origin for mode '${mode:-none}' (got: $out)"
    assert_equals "authorized: task consent for $TARGET_A" "$out" "the origin-only target must be origin"
  done
  pass "gh delivery keeps upstream, github, origin; an origin-only repo is mode-independent"
}

# The no-mistakes contrast: a github remote outranks origin only for gh-based
# tasks, never for the pipeline that opens its pull request against origin.
test_nomistakes_ignores_github_and_upstream_remotes() {
  local proj home out rc
  proj=$(make_two_remote_project nm-contrast "$URL_A" "$URL_B")
  git -C "$proj" remote add github https://github.com/fixture-c/firstmate
  home=$(make_role_home nm-contrast-user)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "origin consent must authorize a no-mistakes task beside github and upstream remotes (got: $out)"
  out=$(run_role "$home" check "$proj" upstream-consent github.com/fixture-c/firstmate mode no-mistakes); rc=$?
  expect_code 1 "$rc" "consent for the github remote must not carry a no-mistakes task (got: $out)"
  assert_contains "$out" "no publication authority for $TARGET_A" "the refusal must name the origin repository"
  pass "no-mistakes gate: github and upstream remotes never name the destination"
}

# The pipeline opens its pull request against its registered destination and
# keeps the prior registration when its run-start refresh from origin fails, so
# origin A with a registration B must not authorize a task consented for A.
test_nomistakes_refuses_when_registration_disagrees_with_origin() {
  local proj home out rc
  proj=$(make_two_remote_project nm-reg-mismatch "$URL_A" "$URL_B" "$URL_B")
  home=$(make_role_home nm-reg-mismatch-user)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "consent for origin must not carry a task whose registration names another repository (got: $out)"
  assert_contains "$out" "origin names $TARGET_A" "the refusal must name origin"
  assert_contains "$out" "registration for $proj publishes to $TARGET_B" "the refusal must name the registered destination"
  assert_contains "$out" "owner must reconcile the no-mistakes registration" "the refusal must name who repairs it"
  assert_not_contains "$out" "no-mistakes init" "the refusal must not send anyone to init, which refuses a fork layout"
  assert_not_contains "$out" "correct origin" "the refusal must not ask for a remote change"

  home=$(make_role_home nm-reg-mismatch-maint "maintainer $TARGET_A")
  out=$(run_role "$home" check "$proj" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a maintainer scope for origin must not carry a task whose registration names another repository (got: $out)"

  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    "$BRIEF" nm-reg-mismatch-brief some-proj --mode no-mistakes --project "$proj" \
    --upstream-consent "$TARGET_A" 2>&1); rc=$?
  expect_code 1 "$rc" "the brief scaffold must refuse a registration that disagrees with origin (got: $out)"
  assert_contains "$out" "registration for $proj publishes to $TARGET_B" "the scaffold refusal must name the registered destination"
  assert_absent "$home/data/nm-reg-mismatch-brief/brief.md" "a refused scaffold must write no brief"

  write_ship_brief "$home" nm-reg-mismatch-spawn " upstream-consent=$TARGET_A"
  out=$(run_spawn "$home" nm-reg-mismatch-spawn "$proj" claude --mode no-mistakes --yolo off \
    --upstream-consent "$TARGET_A"); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn must refuse a registration that disagrees with origin"
  assert_contains "$out" "spawn refused for nm-reg-mismatch-spawn" "the spawn refusal must name the task"
  assert_absent "$home/state/nm-reg-mismatch-spawn.meta" "a refused spawn must write no task metadata"

  # Agreement after re-registration passes again, and gh-based delivery never
  # reads the registry, so the mismatch does not touch it.
  nm_register "$proj" "$URL_A"
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a registration that agrees with origin must authorize again (got: $out)"
  nm_register "$proj" "$URL_B"
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_B" mode direct-PR); rc=$?
  expect_code 0 "$rc" "gh-based delivery must not consult the no-mistakes registry (got: $out)"
  pass "no-mistakes gate: origin A with registration B is refused, repair re-authorizes, gh delivery is unaffected"
}

# A grant cannot clear a registration refusal, so only a refusal for missing
# authority tells the operator to obtain one.
test_grant_advice_only_follows_authority_refusal() {
  local proj home out rc advice='to let this home publish' entry
  proj=$(make_two_remote_project nm-reg-advice "$URL_A" "$URL_B" "$URL_B")
  home=$(make_role_home nm-reg-advice-home)
  mkdir -p "$home/data/nm-reg-advice-promote"
  printf 'project=%s\nkind=scout\nwindow=fm-nm-reg-advice-promote\nworktree=/tmp/wt\n' "$proj" > "$home/state/nm-reg-advice-promote.meta"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nInvestigate.\n\n## Firstmate spec\nReport.\n' \
    > "$home/data/nm-reg-advice-promote/brief.md"
  write_ship_brief "$home" nm-reg-advice-spawn " upstream-consent=$TARGET_A"

  # run_gate_entry <brief|spawn|promote> <consent-args...> sets out and rc.
  run_gate_entry() {
    local which=$1
    shift
    rc=0
    case $which in
    brief)
      out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
        "$BRIEF" nm-reg-advice-brief some-proj --mode no-mistakes --project "$proj" "$@" 2>&1) || rc=$?
      ;;
    spawn)
      out=$(run_spawn "$home" nm-reg-advice-spawn "$proj" claude --mode no-mistakes --yolo off "$@") || rc=$?
      ;;
    promote)
      out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
        FM_CONFIG_OVERRIDE="$home/config" \
        "$PROMOTE" nm-reg-advice-promote --mode no-mistakes --yolo off "$@" 2>&1) || rc=$?
      ;;
    esac
  }

  for entry in brief spawn promote; do
    run_gate_entry "$entry" --upstream-consent "$TARGET_A"
    [ "$rc" -ne 0 ] || fail "$entry must refuse a registration that disagrees with origin (got: $out)"
    assert_contains "$out" "registration for $proj publishes to $TARGET_B" "$entry must print the registration refusal"
    assert_not_contains "$out" "$advice" "$entry must not offer a grant after a registration refusal"
  done

  nm_register "$proj" "$URL_A"
  write_ship_brief "$home" nm-reg-advice-spawn
  for entry in brief spawn promote; do
    run_gate_entry "$entry"
    [ "$rc" -ne 0 ] || fail "$entry must refuse with no grant (got: $out)"
    assert_contains "$out" "$advice to $TARGET_A" "$entry must offer the grant after an authority refusal"
  done
  pass "brief, spawn and promote: grant advice follows only an authority refusal"
}

test_nomistakes_unregistered_project_keeps_origin() {
  local proj home out rc
  proj=$(make_two_remote_project nm-reg-origin-only "$URL_A" "" none)
  home=$(make_role_home nm-reg-origin-only-user)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "an unregistered origin-only project with consent for origin must be allowed (got: $out)"
  assert_contains "$out" "task consent for $TARGET_A" "the allow must name the origin repository"

  proj=$(make_two_remote_project nm-reg-missing "$URL_A" "$URL_B" none)
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "an unregistered project with consent for origin must be allowed (got: $out)"

  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_B" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "an unregistered project must still refuse consent for another repository (got: $out)"
  assert_contains "$out" "no publication authority for $TARGET_A" "the refusal must name the origin repository"

  out=$(NM_HOME="$TMP_ROOT/nm-home-absent" run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 0 "$rc" "a home with no registry database must be allowed with consent for origin (got: $out)"

  out=$(run_role "$home" check "$proj" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "no grant must still be refused (got: $out)"
  assert_contains "$out" "no publication authority for $TARGET_A" "the no-grant refusal must name the origin repository"

  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_B" mode direct-PR); rc=$?
  expect_code 0 "$rc" "gh-based delivery must not need a registration (got: $out)"
  pass "no-mistakes gate: an unregistered project or absent registry is checked against origin alone"
}

test_nomistakes_refuses_unreadable_registration() {
  local proj home out rc
  proj=$(make_two_remote_project nm-reg-unreadable "$URL_A" "$URL_B" none)
  home=$(make_role_home nm-reg-unreadable-user)
  mkdir -p "$TMP_ROOT/nm-home-corrupt"
  printf 'not a database\n' > "$TMP_ROOT/nm-home-corrupt/state.sqlite"
  out=$(NM_HOME="$TMP_ROOT/nm-home-corrupt" run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a corrupt registry must be refused (got: $out)"
  assert_contains "$out" "cannot read the no-mistakes registration" "the refusal must say the registry cannot be read"
  assert_not_contains "$out" "no-mistakes init" "the refusal must not send anyone to init"

  nm_register "$proj" ""
  out=$(run_role "$home" check "$proj" upstream-consent "$TARGET_A" mode no-mistakes); rc=$?
  expect_code 1 "$rc" "a registration with no destination must not count as unregistered (got: $out)"
  assert_contains "$out" "cannot read the no-mistakes registration" "the refusal must say the registration cannot be read"
  pass "no-mistakes gate: an unreadable registry or empty registration is refused"
}

test_role_check_rejects_bad_mode_arguments() {
  local home out rc
  home=$(make_role_home check-badmode)
  out=$(run_role "$home" check "$ROOT" mode merge-train); rc=$?
  expect_code 1 "$rc" "an unknown delivery mode must be rejected (got: $out)"
  assert_contains "$out" "mode must be no-mistakes or direct-PR" "the rejection must name the valid modes"
  out=$(run_role "$home" check "$ROOT" mode); rc=$?
  expect_code 1 "$rc" "a valueless mode argument must be rejected (got: $out)"
  out=$(run_role "$home" check "$ROOT" bogus x); rc=$?
  expect_code 1 "$rc" "an unknown check argument must be rejected (got: $out)"
  assert_contains "$out" "usage:" "the rejection must print the usage"
  pass "fm-role.sh check: mode and consent arguments are validated"
}

# --- run --------------------------------------------------------------------

test_report_default_and_local_grants
test_report_fails_closed_on_unsafe_input
test_check_user_home_refused_on_self_repo
test_check_foreign_project_passes_through
test_check_maintainer_scope_authorizes
test_check_wrong_scope_and_remote_presence_do_not_authorize
test_check_equivalent_remote_spellings_are_one_repo
test_check_fork_lineage_reaches_the_gate
test_check_undeterminable_lineage_and_target_refuse
test_check_task_consent_authorizes_one_task
test_secondmate_cannot_self_grant
test_secondmate_inheritance_receipt_lifecycle
test_secondmate_inherits_only_resolved_primary_role
test_dod_block_renders_and_bounds_consent
test_brief_consent_flag_bounds
test_brief_self_repo_pre_gate
test_spawn_gate_on_self_repo
test_spawn_consent_agreement
test_promote_gate_on_self_repo
test_secondmate_spawn_refuses_consent_flag
test_nomistakes_origin_consent_passes_role_check
test_nomistakes_origin_consent_passes_brief
test_nomistakes_origin_consent_passes_spawn
test_nomistakes_origin_consent_passes_promote
test_nomistakes_gate_refuses_what_origin_does_not_name
test_nomistakes_gate_refuses_unknown_destination
test_gh_delivery_resolution_is_unchanged
test_nomistakes_ignores_github_and_upstream_remotes
test_nomistakes_refuses_when_registration_disagrees_with_origin
test_grant_advice_only_follows_authority_refusal
test_nomistakes_unregistered_project_keeps_origin
test_nomistakes_refuses_unreadable_registration
test_role_check_rejects_bad_mode_arguments

echo "# all fm-self-repo-role tests passed"
