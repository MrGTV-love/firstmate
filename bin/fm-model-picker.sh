#!/usr/bin/env bash
# fm-model-picker.sh - benchmark collector for the model picker (Artificial Analysis).
# Usage: fm-model-picker.sh --selftest | --coverage-only
#        fm-model-picker.sh [--evals-only] [--models SLUG,SLUG] [--sweep [--replay | --embedded-only]
#                            [--stale-after-hours N]] [--db] [--chartdiff]
# --selftest        fixture suite (calibration tables, embedded parser, fetch layer, sweep, matrix load, chart-diff); no network.
# --coverage-only   rebuild coverage.md from the cache, never from aa.sqlite or snapshot.json; no acquisition.
# (no flags)        revalidate the evaluation pages (unless --replay) and read the model-page cohort from the cache, with the
#                   network only on a miss, into snapshot.json.
# --evals-only      the evaluation pages only; revalidated unless --replay.
# --sweep           discover the model universe from the sitemap and selector catalog and give every slug values or a
#                   recorded reason. Cache first; the network is used only for slugs without values (batches of 5, 0.8 s
#                   after every attempt, one fetch at a time). Without --replay it also revalidates the sitemap and the
#                   selector catalog. Every slug ends with values or a recorded reason (exit 1 otherwise).
# --stale-after-hours N   with --sweep, treat cached compare pages older than N hours as missing and ignore remembered 404s older than N hours
#                   (a daily run passes 24; without it nothing expires).
# --replay          cache-first everywhere: no revalidation; with --chartdiff, no live re-fetch (a mismatch stays a mismatch).
# --embedded-only   --sweep from the cache alone: no network at all.
# --db              rebuild aa.sqlite from raw evidence and write projection/<slug>.json per catalog model. A rebuild sets
#                   verdict.json to UNTRUSTED (matrix rebuilt without chart-diff); only --chartdiff restores a verdict.
#                   In a projection, as_of is the newest observed_at across its metrics; each metric's own observed_at is
#                   authoritative for freshness; a rounded eval-leaderboard value can win over a full-precision value when newer.
# --chartdiff       compare table, payload and rendered-chart values; re-fetch each disagreeing page once; rebuild
#                   aa.sqlite; write reconcile.md and verdict.json. Exit 3 when the verdict is UNTRUSTED.
# Order when combined: acquisition, chart-diff, database. Long runs go through bin/fm-proc-budget.sh.
# Exit codes: 0 done. 1 a slug has neither values nor a recorded reason. 2 a fetch failed where the run cannot go on
#   (error: on stderr). 3 the chart-diff verdict is UNTRUSTED. 4 the outputs were written but acquisition was incomplete:
#   a comparison, evaluation or model page could not be fetched (a 404 is not a failure; --embedded-only fetches nothing
#   on purpose and is not one), or the sweep stopped after 3 straight fetch failures (INCOMPLETE: on stderr). A run that
#   is also UNTRUSTED exits 3.
# Data root: FM_MODEL_PICKER_DATA, else <FM_HOME or code root>/data/model-picker (FM_DATA_OVERRIDE selects another
# data directory). It holds raw/ (cache and fetch times), snapshot.json, coverage.md, reconcile.md, verdict.json,
# aa.sqlite and projection/. docs/configuration.md owns the layout. The code is bin/fm_model_picker/.
# Calibration: dispatch_log and outcomes are created first in aa.sqlite (bin/fm_model_picker/aadb.py: log_dispatch,
# record_validator, record_review, record_outcome). The matrix rebuild never touches them.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help) [ "$#" -eq 1 ] && { awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$0"; exit 0; } ;;
esac
command -v python3 >/dev/null 2>&1 || { printf 'error: Python 3 is required for the model-picker collector\n' >&2; exit 1; }
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1 exec python3 -m fm_model_picker.collect "$@"
