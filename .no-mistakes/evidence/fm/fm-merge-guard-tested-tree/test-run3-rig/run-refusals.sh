set -u; WT=$1; export RIG; . "$RIG/lib.sh"; export RIG_CACHE=1; . "$RIG/shas"; T="$RIG/task"
FINAL="$EV/test-run3-live-forged-missing-and-other-refusals.txt"; : > "$FINAL"
echo "# Real PR reads through the rig (Actions job, run, artifact and check-run reads cached after their first real read; pr view, rollup, rules are always real). gh pr merge is blocked. Each case edits ONE real response to make the bad state. X0=$X0 stacked tip (landing=tested). X1=$X1 disjoint tip (landing $T1)." >> "$FINAL"
disjoint(){ compare_json $X1 $MB 20 > "$SCEN_DIR/compare.final"; }
stacked(){ compare_json $X0 $MB 20 > "$SCEN_DIR/compare.final"; }
art(){ cat > "$SCEN_DIR/artifacts.py"; }
# attempt <name> <url> <head> <label> <setup-fn> args...: retries only when GitHub's read limit hit.
attempt() {
  local name=$1 url=$2 head=$3 label=$4 setup=$5 n=0; shift 5
  while :; do
    OUT=$(mktemp "$RIG/o.XXXXXX")
    new_lab "$name" "$url" "$head"; $setup
    drive "$label" "$WT" "$url" "$@"
    if grep -q 'could not read the GitHub pull request state\|check rollup at head .* could not be read completely\|could not be read' "$SCEN_DIR/out" && [ $n -lt 6 ] && ! [ -f "$SCEN_DIR/keep" ]; then
      n=$((n+1)); rm -f "$OUT"; sleep 90; continue
    fi
    cat "$OUT" >> "$FINAL"; [ $n -eq 0 ] || echo "(rerun $n time(s) after a GitHub read-limit pause)" >> "$FINAL"; rm -f "$OUT"; break
  done
  sleep 25
}
s_forged(){ disjoint; art <<PY
for p in data:
    for a in p['artifacts']:
        if a['name'].startswith('fm-tested-tree-'):
            a['name'] = 'fm-tested-tree-$T1-base-$MAIN-attempt-1'
PY
}
s_split(){ disjoint; art <<PY
if '41291278844' in endpoint:
    for p in data:
        for a in p['artifacts']:
            if a['name'].startswith('fm-tested-tree-'):
                a['name'] = 'fm-tested-tree-$T1-base-$X1-attempt-1'
PY
}
s_selfconsistent(){ disjoint; art <<PY
for p in data:
    for a in p['artifacts']:
        if a['name'].startswith('fm-tested-tree-'):
            a['name'] = 'fm-tested-tree-$T1-base-$X1-attempt-1'
PY
}
s_missing(){ stacked; art <<PY
for p in data:
    p['artifacts'] = [a for a in p['artifacts'] if not a['name'].startswith('fm-tested-tree-')]
    p['total_count'] = len(p['artifacts'])
PY
}
s_expired(){ stacked; art <<PY
for p in data:
    for a in p['artifacts']:
        if a['name'].startswith('fm-tested-tree-'): a['expired'] = True
PY
}
s_partial(){ stacked; art <<PY
if '41291278844' in endpoint:
    for p in data:
        p['artifacts'] = [a for a in p['artifacts'] if not a['name'].startswith('fm-tested-tree-')]
        p['total_count'] = len(p['artifacts'])
PY
}
s_two(){ stacked; art <<PY
import copy
for p in data:
    extra = [copy.deepcopy(a) for a in p['artifacts'] if a['name'].startswith('fm-tested-tree-')]
    for a in extra: a['name'] = 'fm-tested-tree-$T1-base-$X1-attempt-1'
    p['artifacts'] += extra; p['total_count'] = len(p['artifacts'])
PY
}
s_link(){ stacked; cat > "$SCEN_DIR/checkruns.py" <<PY
for p in data:
    for c in p['check_runs']:
        c['details_url'] = c['details_url'].replace('MrGTV-love/firstmate','other/repo')
PY
}
s_foreign_socket(){ stacked; cat > "$SCEN_DIR/checkruns.py" <<PY
for p in data:
    for c in p['check_runs']:
        if c['app']['slug'] != 'github-actions': c['head_sha'] = '2'*40
PY
}
s_foreign_actions(){ stacked; cat > "$SCEN_DIR/checkruns.py" <<PY
for p in data:
    for c in p['check_runs']:
        if c['app']['slug'] == 'github-actions':
            c['head_sha'] = '2'*40; break
PY
}
s_red(){ stacked; cat > "$SCEN_DIR/rollup.py" <<PY
n = data[0]['data']['repository']['object']['statusCheckRollup']['contexts']['nodes']
for x in n:
    if x.get('name') == 'Lint 1': x['conclusion'] = 'FAILURE'
PY
}
s_required(){ stacked; printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Rig required check"}]}}]' > "$SCEN_DIR/rules.json"; }
s_legacy(){ stacked; cat > "$SCEN_DIR/rollup.py" <<PY
c = data[0]['data']['repository']['object']['statusCheckRollup']['contexts']
c['nodes'].append({'__typename':'StatusContext','context':'legacy/status','state':'SUCCESS'}); c['totalCount'] += 1
PY
}
s_held(){ stacked; FM_HOME="$LAB" HOME="$RIG/userhome" TASKS_AXI_BACKEND=markdown PATH="$RIG/bin:$PATH" "$WT/bin/fm-captain-hold.sh" hold rig-task --title 'Rig hold' --reason 'lab test hold' >/dev/null 2>&1; }
s_none(){ :; }
s_346_disjoint(){ compare_json $X1 $MB 3 > "$SCEN_DIR/compare.final"; }
A="attempt"
$A forged-diff "$URL" $H "FORGED record: claims tested tree = disjoint landing tree, real base (recompute differs)" s_forged --squash
$A split "$URL" $H "SPLIT records: CI run says base X1, compliance runs say real base (each self-consistent; trees differ)" s_split --squash
$A self-consistent "$URL" $H "SELF-CONSISTENT forgery: every record names base X1 and tree merge-tree(X1,head)" s_selfconsistent --squash
$A missing "$URL" $H "MISSING record on a stacked tree: stays on ancestry" s_missing --squash
$A expired "$URL" $H "EXPIRED record on a stacked tree" s_expired --squash
$A partial "$URL" $H "PARTIAL records: only the CI run lost its record (stacked tree)" s_partial --squash
$A two "$URL" $H "TWO records in one attempt of a run" s_two --squash
$A link "$URL" $H "CHECK LINK points at another repo (cannot bind the record)" s_link --squash
$A foreign-socket "$URL" $H "NON-ACTIONS run (Socket) at ANOTHER head on a stacked tree: refused" s_foreign_socket --squash
$A foreign-actions "$URL" $H "ACTIONS run at ANOTHER head on a stacked tree: refused" s_foreign_actions --squash
$A red "$URL" $H "RED check on a stacked tree: still refused" s_red --squash
$A required "$URL" $H "REQUIRED check never reported on a stacked tree: still refused" s_required --squash
$A legacy "$URL" $H "LEGACY commit status in the rollup on a stacked tree: stays on ancestry" s_legacy --squash
$A held "$URL" $H "HELD task on a stacked tree: still refused" s_held --squash
$A auto "$URL" $H "ATTENDED --auto on real clean PR, real tip: auto-not-armed check runs and passes" s_none --attended-override --auto --squash
U346=https://github.com/$R/pull/346; H346=0f07b896d9ac08562647d49ae59619445899f0a8
$A real346 "$U346" $H346 "REAL PR 346: head contains real main tip, no tested-tree record: ancestry allows as today" s_none --squash
$A real346-disjoint "$U346" $H346 "REAL PR 346, no record, tip X1 it lacks: refused with ancestry text" s_346_disjoint --squash
U348=https://github.com/$R/pull/348; H348=6dd4ff3a3dfb9511274cd04eb0b7a5af8af62660
$A real348 "$U348" $H348 "REAL PR 348: head really lacks main tip, no record: refused" s_none --squash
git -C "$T" checkout -q --detach $H
L=https://github.com/mrgtv-love/firstmate/pull/343
$A lowercase "$L" $H "REAL PR 343 with lower-case owner in the URL" s_none --squash
echo ALLDONE >> "$FINAL"
