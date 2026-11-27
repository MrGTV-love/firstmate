
# Scratch only (not committed): a root whose queued attempt ran without source
# following and whose alone rerun followed sources; prints telemetry source rows.
scratch_nosource_rerun() {
  local tmp fakebin shims real_python rc=0
  tmp=$(fm_test_tmproot fm-lint-scratch-nosource)
  printf 'over\nslow-later\n\n\n' > "$tmp/plan"
  [ "$(uname)" = Darwin ] || { echo "SKIP not macOS"; return; }
  fakebin=$(fm_fakebin "$tmp")
  shims="$tmp/shims"
  real_python=$(command -v python3)
  mkdir -p "$shims"
  fm_lint_write_rss_shims "$shims"
  printf 'lib_fn() { :; }\n' > "$tmp/lib.sh"
  printf '#!/usr/bin/env bash\n# shellcheck source=lib.sh\n. "$(dirname "$0")/lib.sh"\nexit 0\n' > "$tmp/footprint.sh"
  fm_lint_write_growing_shellcheck "$fakebin"
  : > "$tmp/flags.log"
  : > "$tmp/py.log"
  fm_test_tree_leash env -u FM_TEST_RSS_SHIM_DEPTH PATH="$fakebin:$shims:$PATH" \
    FM_TEST_REAL_PS=/bin/ps FM_TEST_REAL_PYTHON="$real_python" \
    FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" FM_TEST_PY_MEMORY="1024 2048" \
    FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_ROOT_RSS_KIB=102400 \
    FM_TEST_FLAGS_LOG="$tmp/flags.log" FM_TEST_PID_FILE="$tmp/footprint.pid" FM_TEST_GROW_STEPS=1 FM_TEST_GROW_HOLD=22 \
    FM_TEST_GROW_NARROW=1 FM_TEST_PY_PLAN="$tmp/plan" \
    "$LINT" --telemetry "$tmp/pass.tsv" "$tmp/footprint.sh" > "$tmp/out" 2>&1 || rc=$?
  echo "rc=$rc"
  echo "--- flags (source following per attempt)"; cat "$tmp/flags.log"
  echo "--- roots log rows"; grep -E '^(begin|end)' "$tmp/pass.roots.tsv" | cut -f1-3,9,10,12
  echo "--- meta"; grep -E '^meta	roots_' "$tmp/pass.roots.tsv"
  echo "--- telemetry source rows"; grep -E '^source_' "$tmp/pass.tsv"
  echo "--- output tail"; tail -6 "$tmp/out"
}
