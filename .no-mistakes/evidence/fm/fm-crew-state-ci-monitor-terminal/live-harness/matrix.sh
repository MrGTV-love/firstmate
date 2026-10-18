#!/usr/bin/env bash
LAB=$(cat /tmp/fm-ci-int-lab-path); R=$1
REF=01M55RW68N1QX2Q95N3FCWBBZJ; BP=01M4GQF0NG9NA68WPVKX79PK6C
n=0
run() {  # <title> <wt> <run> -- env assignments then "AFTER|BEFORE"
  local title=$1 wt=$2 rid=$3; shift 3
  for side in AFTER BEFORE; do
    n=$((n+1)); local bin=$R; [ $side = BEFORE ] && bin=$LAB/base
    printf '[%s] %s\n' "$side" "$title"
    printf '    %s\n' "$(env "$@" "$LAB/drive.sh" "$bin" "$wt" "$rid" "c$n" | grep -v '^ledger:')"
  done
  echo
}
echo "### S1 reference run (all steps done, PR merged on the forge), id-addressed/outcome route"
run "S1 outcome route" "$LAB/wt" $REF X=1
echo "### S2 same run, bare status with NO outcome/error line (the incident shape), status-only arm"
run "S2 status-only route" "$LAB/wt" $REF SHIM_STRIP_OUTCOME=1
echo "### S3 PR is really CLOSED unmerged on the forge (vernant#3444)"
run "S3 closed PR" "$LAB/wt" $REF "SHIM_SED=s#pull/3434#pull/3444#"
echo "### S4 PR does not exist on the forge (vernant#99999999)"
run "S4 missing PR" "$LAB/wt" $REF "SHIM_SED=s#pull/3434#pull/99999999#"
echo "### S5 forge read skipped (FM_CREW_STATE_NO_FORGE=1)"
run "S5 forge skipped" "$LAB/wt" $REF FM_CREW_STATE_NO_FORGE=1
echo "### S6 forge unreadable (gh and gh-axi both fail)"
run "S6 forge unreadable" "$LAB/wt" $REF "PATH=$LAB/noforge:$PATH"
echo "### S7 REAL stored run with intent skipped (backpass, PR open): must stay unknown"
run "S7 intent skipped (real run $BP)" "$LAB/wt2" $BP X=1
echo "### S8 steps edited: lint pending / pr step failed / rebase skipped / ci failed"
run "S8a lint pending" "$LAB/wt" $REF "SHIM_SED=s#lint,completed#lint,pending#"
run "S8b pr step failed" "$LAB/wt" $REF "SHIM_SED=s#pr,completed#pr,failed#"
run "S8c rebase skipped" "$LAB/wt" $REF "SHIM_SED=s#^( *)rebase,completed#\1rebase,skipped#"
run "S8d ci failed" "$LAB/wt" $REF "SHIM_SED=s#ci,skipped#ci,failed#"
echo "### S9 no PR recorded on the run"
run "S9 no pr" "$LAB/wt" $REF "SHIM_SED=/^  pr: /d"
echo "### S10 status-only arm with an unfinished step (before: working, after: unknown)"
run "S10 status-only + lint pending" "$LAB/wt" $REF SHIM_STRIP_OUTCOME=1 "SHIM_SED=s#lint,completed#lint,pending#"
