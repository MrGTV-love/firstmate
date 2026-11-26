#!/usr/bin/env bash
# Portable offline challenger exercise. The two-ID fixture is an authentic capture subset.
set -eu
cd "$(dirname "$0")/.."
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=bin python3 - "${1:-tests/fixtures/model-picker-shadow/registry-eight/catalog.json}" <<'PY'
import gzip, hashlib, json, os, shutil, sqlite3, sys, tempfile
from pathlib import Path
from unittest.mock import patch
from fm_model_picker import registry_shadow, shadow

# Synthetic coverage witnesses: no benchmark scores participate in this search.
def fact(group, metric, tags, scope='comparable'):
    return group, dict(metric=metric, acceptance_tags=list(tags), scope=scope), 0

required = {'citation', 'arithmetic', 'abstention'}
rows = [fact('shared', 'a', ['citation']), fact('shared', 'b', ['arithmetic']),
        fact('other', 'c', ['citation', 'abstention'])]
for order in (rows, list(reversed(rows))):
    assert registry_shadow.complete_fact_cover(order, required, 6) == ('b', 'c')
assert not registry_shadow.complete_fact_cover(rows, required, 1)
assert not registry_shadow.complete_fact_cover(rows[:2], required, 6)
assert not registry_shadow.complete_fact_cover([*rows[:2], fact('other', 'c', ['citation', 'abstention'], 'historical-proxy')], required, 6)
# Seven independent facts, but only six are necessary: the earlier narrow
# duplicate cannot consume the only available slot for the final requirement.
wide = {f't{i}' for i in range(6)}
many = [fact(f'g{i}', f'm{i}', [f't{i}']) for i in range(6)] + [fact('independent', 'a', ['t0'])]
assert registry_shadow.complete_fact_cover(many, wide, 6) == ('a', 'm1', 'm2', 'm3', 'm4', 'm5')
assert not registry_shadow.complete_fact_cover([*many, fact('new', 'm6', ['t6'])], wide | {'t6'}, 6)

with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    fixture = Path('tests/fixtures/model-picker-shadow')
    shutil.copytree(fixture/'projection', root/'projection')
    def put(name, value):
        path = root/name
        path.write_text(json.dumps(value))
        return str(path)
    put('verdict.json', {'verdict':'TRUSTED'})
    profiles = [dict(harness='claude', model='opus', effort='high'), dict(harness='omp', model='openai-codex/gpt-6.1-sol', effort='high')]
    result = {'status':'clear', 'candidates':[{'eligible':True,'profile':p} for p in profiles]}
    args = dict(table='bin/fm_model_picker/routes.json',task_text=str(root/'task'),rules=put('rules', {'default':profiles}),result=put('result',result),scratch=tmp)
    os.environ['FM_MODEL_PICKER_REGISTRY'] = sys.argv[1]
    calls = []
    def mock(request, *unused):
        calls.append(request)
        assert 'secret' not in json.dumps(request) and len(json.dumps(request)) <= 8192
        answers = {k:dict(type='choice',choice='candidate_'+str(i),probabilities={}) for i,k in enumerate(('worker','validator'),1)}
        return json.dumps(dict(answers=answers,model='jev-1')).encode()
    def run(tag, safe=True, simulator=mock, substitute=False, kind='design-fixture', text=None, **acceptance_fields):
        words = [tag] if isinstance(tag,str) else tag
        text = text or 'secret task '+' '.join(words)
        (root/'task').write_text(text)
        os.environ['FM_MODEL_PICKER_ACCEPTANCE'] = put('acceptance',dict(tags=words,authorized_safe_scope=safe,binding_kind=kind,task_sha256=hashlib.sha256(text.encode()).hexdigest(),**acceptance_fields))
        if substitute:
            (root/'task').write_text('different task with unreviewed acceptance conditions')
        with patch.object(shadow,'jev_call',side_effect=AssertionError('unexpected provider path')):
            shadow.observe(args,'test','mock',root,registry_mock=simulator)
        with sqlite3.connect(root/'aa.sqlite') as db:
            return db.execute('select picker_status,chosen_worker,gates from dispatch_log order by id desc limit 1').fetchone()
    catalog_keys = {r['id'] for r in json.loads(Path(sys.argv[1]).read_bytes())['records']}
    def check_catalog_coverage(audit):
        included, excluded = set(audit['included']), set(audit['excluded'])
        assert included == set(audit['support']) and not included & excluded
        assert included | excluded == catalog_keys
        comparable = sum(row['scope'] == 'comparable' for row in audit['support'].values())
        expected = dict(total=len(catalog_keys), comparable=comparable,
                        historical_proxy=len(included) - comparable, excluded=len(excluded))
        assert audit['catalog_coverage'] == expected, audit['catalog_coverage']
        return expected

    for tag, metric in [('long_document_synthesis','aa-lcr'), ('verified_terminal_execution','terminal-bench-4-0')]:
        status, worker, gates = run(tag)
        assert (status,worker)==('registry-proxy-only',None), (status,gates)
        audit = json.loads(gates)['registry']
        coverage = check_catalog_coverage(audit)
        assert (coverage['comparable'], coverage['historical_proxy']) == (0, 1)
        assert audit['included']==[metric] and 'offline_request' not in audit and not calls
        receipt = audit['support'][metric]
        assert receipt['scope']=='historical-proxy' and len({r['value'] for r in receipt['rows'].values()})==2
        print(json.dumps({'task_tag':tag, 'metric':metric, 'status':status, **receipt},sort_keys=True))
    historical=json.loads(Path(sys.argv[1]).with_name('historical-snapshot.json').read_text())
    os.environ['FM_MODEL_PICKER_REGISTRY_SNAPSHOT']=put('historical-snapshot.json',historical)
    os.environ.pop('FM_MODEL_PICKER_METHOD_PINS_SHA256', None)
    assert run(tag)[0]=='registry-unavailable' and not calls
    original_pins = Path(sys.argv[1]).with_name('method-pins.json').read_bytes()
    os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256'] = hashlib.sha256(original_pins).hexdigest()
    assert run(tag)[0]=='registry-proxy-only'
    # Explicit review commitment must not be ignored when using the archive
    # alone. A digest mismatch must refuse even though the archive internally agrees.
    saved_snapshot = os.environ.pop('FM_MODEL_PICKER_REGISTRY_SNAPSHOT')
    archive_pin = os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256']
    os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256'] = '0' * 64
    assert run(tag)[0] == 'registry-unavailable' and not calls
    os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256'] = archive_pin
    status, _, gates = run(tag)
    audit = json.loads(gates)['registry']
    assert status == 'registry-proxy-only' and audit['method_pins_sha256'] == archive_pin
    assert audit['task_binding_kind'] == 'design-fixture'
    assert audit['semantic_review_sha256'] == json.loads(original_pins)['semantic_review_sha256']
    assert audit['task_scope_sha256'] == json.loads(original_pins)['task_scope_sha256']
    original_catalog = Path(sys.argv[1])
    substituted = root/'substituted-archive'
    substituted.mkdir()
    for name in ('catalog.json', 'semantic-review.json', 'task-scope.json', 'observations.jsonl.gz', 'method-pins.json'):
        shutil.copyfile(original_catalog.with_name(name), substituted/name)
    new_review = substituted/'semantic-review.json'
    new_review.write_bytes(new_review.read_bytes() + b'\n')
    new_scope = substituted/'task-scope.json'
    source_scope = json.loads(new_scope.read_bytes())
    source_scope['semantic_review_sha256'] = hashlib.sha256(new_review.read_bytes()).hexdigest()
    new_scope.write_text(json.dumps(source_scope))
    os.environ['FM_MODEL_PICKER_REGISTRY'] = str(substituted/'catalog.json')
    assert run(tag)[0] == 'registry-unavailable' and not calls
    del os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256']
    assert run(tag)[0] == 'registry-proxy-only' and not calls
    os.environ['FM_MODEL_PICKER_REGISTRY'] = sys.argv[1]
    os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256'] = archive_pin
    os.environ['FM_MODEL_PICKER_REGISTRY_SNAPSHOT'] = saved_snapshot
    methods = historical['evaluation_inventory']['last_method_evidence']
    witness = methods['terminalbench-4-0']
    original_page = witness['page_sha256']
    witness['page_sha256'] = hashlib.sha256(b'fixture page changed outside Dataset declarations').hexdigest()
    put('historical-snapshot.json',historical)
    status, worker, gates = run(tag, simulator=None)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-insufficient', None) and 'offline_request' not in audit
    assert audit['excluded']['terminal-bench-4-0'] == 'collector page bytes differ from the reviewed page'
    witness['page_sha256'] = original_page
    put('historical-snapshot.json',historical)
    # Sanitized accepted-delivery analogue versus a reporting-only requirement on the same menu.
    for text,tags,relevant,irrelevant in [
        ('Repair the repository timing regression; pass the blocking test without raising the 7000 ms limit.', ['repository_patch','blocking_maintainer_checks'],'frontiercode','ifbench'),
        ('Return a single status event with exact syntax and the required verbatim snapshot.', ['machine_checked_output_constraints'],'ifbench','frontiercode')]:
        status,worker,gates=run(tags,kind='repo-contract',text=text)
        audit=json.loads(gates)['registry']
        assert audit['excluded'][relevant]=='no unique revision-bound label'
        assert audit['excluded'][irrelevant]=='acceptance tags incompatible'
        assert worker is None and 'offline_request' not in audit and not calls
        print(json.dumps(dict(requirement=text,reviewed_tags=tags,relevant=relevant,status=status,jev_request=None)))
    # Independently specified task cases, not derived from review records or benchmark names.
    cases=[
        ('aa-lcr','design-fixture','Link two distant manual passages to answer the keyed question.','long_document_synthesis','Count the input pages only.','capacity_only'),
        ('frontiercode','repo-contract','Patch the brief generator and pass the blocking invalid-mode regression.','repository_patch blocking_maintainer_checks','Solve the abstract puzzle, not a patch.','puzzle_only'),
        ('ifbench','repo-contract','Emit one status event with the required syntax and one verbatim snapshot.','machine_checked_output_constraints','Improve the tone without a graded output shape.','style_only'),
        ('omniscience-accuracy','design-fixture','Answer the manual questions against a separately keyed answer set.','factual_correctness_checked','Check only that cited page numbers exist.','citation_fidelity_only'),
        ('omniscience-hallucination-rate','design-fixture','Abstain when the manual gives no answer; guesses count as errors.','abstention_expected incorrect_guess_penalized','Check citations only; guesses are not graded.','citation_fidelity_only'),
        ('scicode','design-fixture','Implement a numerical integrator that passes hidden tolerance checks.','numerical_scientific_implementation','Explain numerical integration without implementing it.','explanation_only'),
        ('terminal-bench-4-0','design-fixture','Repair the local fixture in a terminal and verify its postconditions.','verified_terminal_execution','Describe the repair without running it.','explanation_only'),
        ('terminalbench21','design-fixture','Run a terminal repair and verify the resulting files.','verified_terminal_execution','Explain the commands without running them.','explanation_only')]
    for key,kind,pos,required,neg,contrast in cases:
        def exercise(words,text):
            s,w,g=run(words,kind=kind,text=text)
            a=json.loads(g)['registry']; assert w is None and 'offline_request' not in a and not calls
            assert a['catalog_sha256']==hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest()
            return a['excluded'].get(key) or a['support'][key]['scope']
        positive=exercise(required.split(),pos)
        negative=exercise([contrast],neg)
        print(json.dumps(dict(id=key,positive=positive,negative=negative)))
        expected={'aa-lcr':'historical-proxy','terminal-bench-4-0':'historical-proxy','terminalbench21':'incompatible or missing comparable observations'}
        assert positive==expected.get(key,'no unique revision-bound label') and negative=='acceptance tags incompatible'
    inv=historical['evaluation_inventory']
    slug='terminalbench-4-0'
    for flag in ('newly_discovered','missing_pages','missing_from_sitemap'):
        inv[flag].append(slug)
        put('historical-snapshot.json',historical)
        assert run(tag)[0]=='registry-insufficient' and run('long_document_synthesis')[0]=='registry-proxy-only'
        inv[flag].remove(slug)
    inv['problem'] = 'sitemap contains no canonical evaluation listings'
    put('historical-snapshot.json',historical)
    for independent_tag, key in [(tag, 'terminal-bench-4-0'), ('long_document_synthesis', 'aa-lcr')]:
        status, worker, gates = run(independent_tag)
        audit = json.loads(gates)['registry']
        assert (status, worker) == ('registry-insufficient', None) and not calls
        assert audit['excluded'][key] == 'collector method missing, changed or not independently pinned'
        assert key not in audit['included'] and 'offline_request' not in audit
    del inv['problem']
    inv['last_method_evidence'][slug]['datasets'][0]['description']='changed declaration'
    put('historical-snapshot.json',historical)
    assert run(tag)[0]=='registry-insufficient' and run('long_document_synthesis')[0]=='registry-proxy-only'
    source_catalog = Path(sys.argv[1])
    repinned = root/'repinned'
    repinned.mkdir()
    for name in ('catalog.json', 'semantic-review.json', 'task-scope.json', 'observations.jsonl.gz', 'sources.json'):
        if source_catalog.with_name(name).is_file():
            shutil.copyfile(source_catalog.with_name(name), repinned/name)
    pins = json.loads(source_catalog.with_name('method-pins.json').read_bytes())
    changed = next(p for p in pins['records'] if p['evaluation'] == slug)
    datasets = inv['last_method_evidence'][slug]['datasets']
    changed['collector_datasets_sha256'] = hashlib.sha256(json.dumps(datasets, sort_keys=True).encode()).hexdigest()
    (repinned/'method-pins.json').write_text(json.dumps(pins))
    os.environ['FM_MODEL_PICKER_REGISTRY'] = str(repinned/'catalog.json')
    assert run(tag)[0]=='registry-unavailable' and not calls, 'editing just the pin must not approve a new method'
    os.environ['FM_MODEL_PICKER_REGISTRY'] = sys.argv[1]
    print('PASS: archived method changes held; a derivative pin cannot approve a changed declaration; zero chooser calls')
    del os.environ['FM_MODEL_PICKER_REGISTRY_SNAPSHOT']
    del os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256']
    for menu in ([*profiles,dict(profiles[0],effort='medium')], [dict(profiles[0],effort='medium'),*profiles]):
        put('rules', {'default':menu})
        audit=json.loads(run(tag)[2])['registry']
        assert sorted(audit['routes'].values())==[['claude:opus','high'],['omp:openai-codex/gpt-6.1-sol','high']]
        assert [p['effort'] for p in audit['excluded_candidates'].values()]==['medium']
    put('rules',{'default':profiles})
    assert run('unrecognized_tag')[0]=='registry-unavailable' and run(tag,False)[0]=='registry-unavailable'
    assert not calls
    result['candidates'][1]['eligible']=False
    put('result',result)
    assert run(tag)[0]=='registry-insufficient' and not calls
    # Synthetic condition attestations exercise the positive path, not live model capability.
    result['candidates'][1]['eligible']=True
    put('result',result)
    portable=fixture/'registry'
    shutil.copy(portable/'catalog.json',root/'catalog.json')
    os.environ['FM_MODEL_PICKER_REGISTRY']=str(root/'catalog.json')
    table=json.loads(Path(args['table']).read_text())
    conditions={}
    for p in profiles:
        m=table['routes'][p['harness']+':'+p['model']]['projections']['high']
        att=dict(model_build='synthetic-'+m['slug'],tool_condition='test-only',population='test',split='test',scoring='test',effort='high',method_revision='synthetic-pinned-v1')
        conditions[m['slug']]=m['registry_condition']=att
    args['table']=put('table',table)
    with gzip.open(portable/'observations.jsonl.gz','rt') as source, gzip.open(root/'observations.jsonl.gz','wt') as dest:
        for line in source:
            o=json.loads(line); o.update(conditions[o['slug']]); dest.write(json.dumps(o)+'\n')
    review=json.loads((portable/'semantic-review.json').read_text())
    review['evidence_hashes']['observations.jsonl.gz']=hashlib.sha256((root/'observations.jsonl.gz').read_bytes()).hexdigest()
    put('semantic-review.json',review)
    scope=json.loads((portable/'task-scope.json').read_text())
    scope['semantic_review_sha256']=hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json',scope)
    result['chosen'] = result['candidates'][0]
    result['route_launch_binding_sha256'] = hashlib.sha256(b'Synthetic router launch').hexdigest()
    put('result', result)
    contract = hashlib.sha256(b'Synthetic terminal fixture: exact output and checksum required').hexdigest()
    validation = hashlib.sha256(b'fixture fixed independent validation policy').hexdigest()
    assert run(tag, acceptance_sha256=contract)[:2] == ('registry-unavailable', None)
    assert run(tag, acceptance_sha256=contract, validation_policy_sha256='unknown')[:2] == ('registry-unavailable', None)
    status, worker, gates = run(tag, acceptance_sha256=contract, validation_policy_sha256=validation)
    assert (status, worker) == ('registry-simulated', None)
    audit = json.loads(gates)['registry']
    assert audit['route_launch_binding_sha256'] == result['route_launch_binding_sha256']
    assert result['route_launch_binding_sha256'] not in json.dumps(audit['offline_request'])
    assert set(audit['offline_request']['questions']) == {'worker'}, audit['offline_request']['questions'].keys()
    assert audit.get('simulated_worker') == 'candidate_1' and 'simulated_pair' not in audit
    # The private full-catalog run also exercises the joint handoff, not live calibration.
    if Path(sys.argv[1]).with_name('variant-storage-replay').is_dir():
        import subprocess
        from runpy import run_path
        fixture_panel = run_path('data/jev-roi-design/test-reconcile-lifecycle.py')
        matched = run_path('data/jev-roi-design/reconcile-lifecycle.py')['matched_summary']
        panel, trial = fixture_panel['paired_panel'](), fixture_panel['frozen_trial']()
        assert audit['acceptance_sha256'] == contract and audit['validation_policy_sha256'] == validation
        for receipt in (panel['assignments'], panel['verdicts'], trial['assignments']):
            for entry in receipt:
                entry['acceptance_sha256'] = contract
        exact_task = hashlib.sha256((root/'task').read_bytes()).hexdigest()
        old_task = panel['assignments'][0]['task_sha256']
        for records in (panel['assignments'], panel['executions'], panel['verdicts'], trial['assignments']):
            for record in records:
                if record['task_sha256'] == old_task:
                    record['task_sha256'] = exact_task
        assert exact_task == audit['task_sha256']
        next(r for r in panel['usage'] if r['call'] == 'challenger/a/0/route')['input_tokens'] = 5
        by_arm = dict(incumbent='candidate_1', challenger='candidate_2')
        observed_configurations = {'candidate_1': 'claude:opus:high', 'candidate_2': 'omp:openai-codex/gpt-6.1-sol:high'}
        assert observed_configurations == {option: ':'.join(parts) for option, parts in audit['routes'].items()}
        configurations = {arm: observed_configurations[option] for arm, option in by_arm.items()}
        panel['arm_configurations'] = trial['arm_configurations'] = configurations
        trial['incumbent_configuration'] = configurations['incumbent']
        for execution in panel['executions']:
            execution['actual_configuration'] = configurations[execution['assignment'].split('/')[0]]
        summary = matched(panel, trial, target_task_sha256=exact_task)
        local = {by_arm[arm]: {key: value for key, value in counts.items() if key != 'lifecycle_tokens'}
                 for arm, counts in summary['arms'].items()}
        eligible = [dict(id=option, configuration=counts['configuration']) for option, counts in local.items()]
        observations = audit['offline_request']['state']['observations']
        assert {option: counts['configuration'] for option, counts in local.items()} == observed_configurations
        assert observations[0]['values']['candidate_1'] > observations[0]['values']['candidate_2']
        assert local['candidate_1']['accepted'] == local['candidate_2']['accepted'] == 1
        assert local['candidate_1']['input_tokens'] > local['candidate_2']['input_tokens']
        assert validation == fixture_panel['REPORT_VALIDATION']
        bindings = dict(acceptance_sha256=contract, panel_acceptance_sha256s=summary['acceptance_sha256s'],
                        validation_policy_sha256=validation,
                        panel_validation_policy_sha256s=summary['validation_policy_sha256s'])
        target = dict(task_sha256=exact_task, eligible_configurations=list(reversed(observed_configurations.values())),
                      incumbent_configuration=configurations['incumbent'], acceptance_tags=[tag], acceptance_sha256=contract,
                      validation_policy_sha256=validation,
                      configuration_generation_conditions=fixture_panel['fixture_target_profiles'](trial),
                      task_materials_sha256=fixture_panel['FIXTURE_MATERIALS'],
                      closeout_rule='same-fixture-horizon',
                      route_launch_binding_sha256=result['route_launch_binding_sha256'])
        panel_path = put('joined-panel.json', panel)
        plan_path = put('joined-plan.json', trial)
        target_path = put('joined-target.json', target)
        receipt_path = put('joined-registry.json', audit)
        audit_pin = hashlib.sha256(Path(receipt_path).read_bytes()).hexdigest()
        cmd = [sys.executable, '-B', 'data/jev-roi-design/reconcile-lifecycle.py', panel_path, '--matched-summary',
               '--trial-plan', plan_path, '--trial-plan-sha256', hashlib.sha256(Path(plan_path).read_bytes()).hexdigest(),
               '--preview-target', target_path, '--registry-receipt', receipt_path, '--registry-receipt-sha256']
        preview = subprocess.run([*cmd, audit_pin], capture_output=True, text=True)
        assert preview.returncode == 0, preview.stderr
        joined = json.loads(preview.stdout)
        assert joined['registry_receipt_sha256'] == audit_pin and joined['candidate_configurations'] == observed_configurations
        joint = joined['offline_request']
        state = joint['state']
        assert state['observations'] == observations and state['lifecycle_token_estimates'] == {'candidate_1': None, 'candidate_2': None}
        assert state['matched_local_outcomes']['incumbent_option'] == 'candidate_1'
        assert state['matched_local_outcomes']['counts'] == {option: {k: v for k, v in counts.items() if k != 'configuration'}
                                                            for option, counts in local.items()}
        assert 'matched local outcomes take precedence' in joint['questions']['worker']['instructions']
        for private in (contract, validation, exact_task, audit_pin, target['route_launch_binding_sha256'],
                        *(counts['configuration'] for counts in local.values())):
            assert private not in json.dumps(joint)
        for field in ('acceptance_sha256', 'validation_policy_sha256'):
            # The task and broad tags stay fixed, but both local arms were
            # measured under a new contract. An older public receipt must not join.
            changed_panel = json.loads(json.dumps(panel))
            changed_plan = json.loads(json.dumps(trial))
            different = hashlib.sha256(('synthetic alternate ' + field).encode()).hexdigest()
            for rows in (changed_panel['assignments'], changed_panel['verdicts'], changed_plan['assignments']):
                for row in rows:
                    row[field] = different
            put('joined-panel.json', changed_panel)
            put('joined-plan.json', changed_plan)
            put('joined-target.json', dict(target, **{field: different}))
            changed_cmd = cmd.copy()
            changed_cmd[changed_cmd.index('--trial-plan-sha256') + 1] = hashlib.sha256(Path(plan_path).read_bytes()).hexdigest()
            refused = subprocess.run([*changed_cmd, audit_pin], capture_output=True, text=True)
            assert (refused.returncode, bool(refused.stdout)) == (2, False), (field, refused.returncode, bool(refused.stdout))
            assert 'same acceptance contract and validation policy' in refused.stderr, refused.stderr
        put('joined-panel.json', panel)
        put('joined-plan.json', trial)
        put('joined-target.json', target)
        for changed, reason in [
            (dict(audit, task_sha256='0'*64), 'different task'),
            (dict(audit, routes=dict(audit['routes'], candidate_1=['claude:opus', 'low'])), 'different worker configurations'),
            (dict(audit, incumbent_option='candidate_2'), 'different incumbent'),
        ]:
            put('joined-registry.json', changed)
            observed_pin = hashlib.sha256(Path(receipt_path).read_bytes()).hexdigest()
            for pin, expected in [(observed_pin, reason), (audit_pin, 'independent digest')]:
                refused = subprocess.run([*cmd, pin], capture_output=True, text=True)
                assert (refused.returncode, refused.stdout) == (2, '') and expected in refused.stderr, refused.stderr
        for bad_options in (None, dict(candidate_1=observed_configurations['candidate_2'], candidate_2=observed_configurations['candidate_1'])):
            try:
                shadow.registry_request(eligible, observations, [tag], local_outcomes=local,
                                        incumbent='candidate_1', observation_configurations=bad_options, **bindings)
            except ValueError as exc:
                assert 'same worker configurations' in str(exc)
            else:
                raise AssertionError('opaque IDs joined without the same worker configurations')
        weaker = dict(local, candidate_1=dict(local['candidate_1'], accepted=0))
        try:
            shadow.registry_request(eligible, observations, [tag], local_outcomes=weaker,
                                    incumbent='candidate_2', observation_configurations=observed_configurations, **bindings)
        except ValueError as exc:
            assert 'observed acceptance loss' in str(exc)
        else:
            raise AssertionError('higher public score overrode observed acceptance loss')
        print('PASS: joint synthetic handoff kept rankings distinct and rejected an observed acceptance loss')
        wire = subprocess.run(['node', '--experimental-strip-types', 'data/jev-roi-design/replay-picker-wire.ts'],
                              input=json.dumps(joint), text=True, capture_output=True,
                              env=dict(PATH=os.environ['PATH'], HOME=str(root)))
        assert wire.returncode == 0, wire.stderr
        print(wire.stdout, end='')
    # The deliberately extra validator answer in the mock has no effect.
    with sqlite3.connect(root/'aa.sqlite') as db:
        assert db.execute('select chosen_worker,chosen_validator from dispatch_log order by id desc limit 1').fetchone() == (None, None)
    def abstain(req):
        assert req['state']['lifecycle_token_estimates']=={'candidate_1':None,'candidate_2':None}
        assert tag in req['state']['acceptance_tags'] and 'insufficient_evidence' in req['questions']['worker']['criteria']
        answers={k:dict(type='choice',choice=v,probabilities={}) for k,v in [('worker','insufficient_evidence'),('validator','candidate_2')]}
        return json.dumps(dict(answers=answers,model='jev-1')).encode()
    assert run(tag,simulator=abstain)[:2]==('registry-abstained',None)
    assert run(tag, simulator=None)[:2]==('registry-offline-replay', None)
    effective_rows = [dict(c, comparison_member=True) for c in result['candidates']]
    resolver_result = dict(result, routing={'model': {'model': 'fixture'}}, candidates=effective_rows)
    configured_incumbent = dict(result['candidates'][0])
    for selected, expected in [(None, 'registry-unverified-incumbent'),
                               ('unusable', 'registry-unverified-incumbent'),
                               (dict(configured_incumbent, comparison_member=False), 'registry-unverified-incumbent'),
                               (dict(configured_incumbent, profile=dict(profiles[0], effort='max')), 'registry-unverified-incumbent'),
                               (dict(configured_incumbent, unknown=True), 'registry-unverified-incumbent'),
                               (configured_incumbent, 'registry-offline-replay')]:
        put('result', dict(resolver_result, chosen=selected))
        status, worker, gates = run(tag, simulator=None)
        incumbent_audit = json.loads(gates)['registry']
        assert (status, worker) == (expected, None), (selected, status)
        assert ('offline_request' in incumbent_audit) == (selected == configured_incumbent)
        assert incumbent_audit['incumbent_option'] == ('candidate_1' if selected == configured_incumbent else None)
        if selected == configured_incumbent:
            assert incumbent_audit['offline_request']['state']['incumbent_option'] == 'candidate_1'
    put('result', result)
    # The resolver can include advisory eligible rows even when it refused clearance.
    for hook_status, result_status in [('escalate', 'escalate'), ('ambiguous', 'ambiguous'),
                                      ('clear', 'escalate'), ('escalate', 'clear'), ('clear', None)]:
        args['status'] = hook_status
        put('result', dict(result, status=result_status))
        status, worker, gates = run(tag, simulator=None)
        assert (status, worker) == ('registry-resolver-held', None), (hook_status, result_status, status)
        assert 'offline_request' not in (gates or '')
    del args['status']
    # A clear dispatch can still list a provisional or short-runway alternative.
    for flags, expect, detail in [
        ({'unknown': True, 'capacity': {'status': 'unknown'}}, 'registry-unverified-menu', 'quota or capacity unverified'),
        ({'short': True}, 'registry-insufficient', 'runway shorter than the task horizon'),
    ]:
        alternative = dict(result['candidates'][1], **flags)
        put('result', dict(result, candidates=[result['candidates'][0], alternative]))
        status, worker, gates = run(tag, simulator=None)
        audit = json.loads(gates)['registry']
        assert (status, worker) == (expect, None), (flags, status, audit['routes'])
        assert 'offline_request' not in audit and 'candidate_2' not in audit['routes']
        assert detail in audit['excluded_candidates']['candidate_2']['reason']
        assert bool(audit['unverified_eligibility']) == bool(flags.get('unknown'))
    nominal = result['candidates'][1]
    for alternate in [dict(nominal, eligible=False), dict(nominal, eligible=1),
                      dict(nominal, profile=dict(nominal['profile'], provider='fixture-other-account'))]:
        observed = []
        for pair in ([nominal, alternate], [alternate, nominal]):
            put('result', dict(result, candidates=[result['candidates'][0], *pair]))
            status, worker, gates = run(tag, simulator=None)
            audit = json.loads(gates)['registry']
            observed.append((status, worker, 'offline_request' in audit))
        assert observed == [('registry-unverified-menu', None, False)] * 2, observed
        assert 'conflicting resolver rows' in audit['excluded_candidates']['candidate_2']['reason']
    put('result', dict(result, candidates=[*result['candidates'], dict(nominal)]))
    assert run(tag, simulator=None)[:2] == ('registry-offline-replay', None)
    # Diagnostic candidate rows are not the set offered by a restricted route.
    routed = dict(result, routing={'model': {'model': 'fast'}},
                  candidates=[dict(c, comparison_member=(i == 0)) for i, c in enumerate(result['candidates'])])
    put('result', routed)
    status, worker, gates = run(tag, simulator=None)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-insufficient', None), (status, audit['routes'])
    assert set(audit['routes']) == {'candidate_1'} and 'offline_request' not in audit
    assert 'outside resolver comparison menu' in audit['excluded_candidates']['candidate_2']['reason']
    del routed['candidates'][1]['comparison_member']
    put('result', routed)
    status, worker, gates = run(tag, simulator=None)
    assert (status, worker) == ('registry-unverified-menu', None)
    assert 'offline_request' not in json.loads(gates)['registry']
    # A normalized or fallback profile can appear in the resolver result without a rules-side join.
    extra_profile = dict(profiles[0], effort='max')
    effective = [dict(c, comparison_member=True) for c in result['candidates']]
    for membership, status_expected in [(True, 'registry-unverified-menu'), (False, 'registry-offline-replay')]:
        extra_route = dict(profile=extra_profile, eligible=True, comparison_member=membership)
        put('result', dict(routed, chosen=configured_incumbent, candidates=[*effective, extra_route]))
        status, worker, gates = run(tag, simulator=None)
        audit = json.loads(gates)['registry']
        assert (status, worker) == (status_expected, None), (membership, status, audit['routes'])
        assert audit['unjoined_resolver_members'] == ([['claude:opus', 'max']] if membership else [])
        assert ('offline_request' in audit) == (not membership)
    put('result', result)
    cutoff = '2026-10-16T03:01:08Z'
    status, worker, gates = run(tag, simulator=None, evidence_not_after=cutoff)
    audit = json.loads(gates)['registry']
    assert audit['excluded'].get('terminal-bench-4-0') == 'projection acquired after the evidence cutoff or time unknown', (status, audit['included'])
    assert (status, worker) == ('registry-insufficient', None) and 'offline_request' not in audit
    status, worker, gates = run(tag, simulator=None, evidence_not_after='2026-10-16T03:01:09Z')
    assert (status, worker) == ('registry-offline-replay', None)
    assert json.loads(gates)['registry']['evidence_not_after'] == '2026-10-16T03:01:09Z'
    assert run(tag, simulator=None, evidence_not_after='2026-02-30T03:01:09Z')[0] == 'registry-unavailable'
    missing_projection = dict(profiles[0], effort='medium')
    put('rules', {'default': [*profiles, missing_projection]})
    put('result', dict(result, candidates=[*result['candidates'], {'profile': missing_projection, 'eligible': True}]))
    status, worker, gates = run(tag, simulator=None)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-incomplete-menu', None) and 'offline_request' not in audit
    assert set(audit['unmeasured_eligible']) == set(audit['excluded_candidates'])
    assert list(audit['unmeasured_eligible'].values()) == [['claude:opus', 'medium']]
    put('rules', {'default': profiles})
    put('result', result)
    extra = 'machine_checked_output_constraints'
    partial_calls = []
    def positive_on_partial(request):
        partial_calls.append(request)
        return json.dumps(dict(answers={k: dict(type='choice', choice=f'candidate_{i}', probabilities={})
                                       for i, k in enumerate(('worker', 'validator'), 1)}, model='jev-1')).encode()
    status, worker, gates = run([tag, extra], simulator=positive_on_partial)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-incomplete-acceptance', None), (status, audit.get('simulated_pair'))
    assert audit['uncovered_acceptance_tags'] == [extra] and not partial_calls
    assert 'simulated_pair' not in audit and 'offline_request' not in audit
    state = json.loads(run(tag, simulator=None)[2])['registry']['offline_request']['state']
    assert state['acceptance_tags'] == [tag] and state['uncovered_acceptance_tags'] == []
    fact = state['observations'][0]
    assert fact['acceptance_tags'] == [tag]
    assert fact['provenance'] == {
        'evaluation': 'https://artificialanalysis.ai/evaluations/terminalbench-4-0',
        'method_revision': 'synthetic-pinned-v1',
        'rows': {
            'candidate_1': {'source': 'embedded', 'observed_at': '2026-10-16T02:58:33Z'},
            'candidate_2': {'source': 'embedded', 'observed_at': '2026-10-16T03:01:09Z'},
        },
    }
    assert 'secret task' not in json.dumps(state) and len(calls) == 1
    # The preview cannot silently strip provenance or forward arbitrary source strings.
    preview_options = [{'id': option, 'family': family} for option, family in [('candidate_1', 'claude'), ('candidate_2', 'sol')]]
    for bad_provenance in [
            dict(fact['provenance'], evaluation='https://example.com/evaluations/terminalbench-4-0'),
            dict(fact['provenance'], rows={'candidate_1': fact['provenance']['rows']['candidate_1']}),
            dict(fact['provenance'], rows={**fact['provenance']['rows'], 'candidate_1': {'source': 'embedded', 'observed_at': 'unknown'}})]:
        try:
            shadow.registry_request(preview_options, [dict(fact, provenance=bad_provenance)], state['acceptance_tags'])
        except ValueError as exc:
            assert 'provenance' in str(exc) or 'acquisition time' in str(exc)
        else:
            raise AssertionError('unbound observation serialized')
    for bad_score in ('private-fixture-prose', True, float('nan'), float('inf'), -0.01, 1.01):
        altered = dict(fact, scale='fraction', unit='fraction', values={'candidate_1': 0.5, 'candidate_2': bad_score})
        try:
            shadow.registry_request(preview_options, [altered], state['acceptance_tags'])
        except ValueError as exc:
            assert 'finite numeric scores' in str(exc)
        else:
            raise AssertionError('malformed benchmark cell serialized')
    for field, bad in [('metric', 'fixture/private/path'), ('revision', 'fixture\nnotes'),
                       ('direction', 'unknown'), ('unit', 'incompatible')]:
        try:
            shadow.registry_request(preview_options, [dict(fact, **{field: bad})], state['acceptance_tags'])
        except ValueError as exc:
            assert 'unbounded observation label' in str(exc)
        else:
            raise AssertionError('malformed scorecard label serialized')
    for ids in [('candidate_1', 'insufficient_evidence'), ('candidate_1', 'candidate_1')]:
        try:
            shadow.registry_request([{'id': item} for item in ids], [], state['acceptance_tags'])
        except ValueError as exc:
            assert 'opaque worker options' in str(exc)
        else:
            raise AssertionError('ambiguous worker menu serialized')
    assert run(tag, substitute=True)[0]=='registry-unavailable'
    list(conditions.values())[0]['method_revision']='changed-method'
    args['table']=put('table',table)
    assert run(tag)[0]=='registry-insufficient' and len(calls)==1
    list(conditions.values())[0]['method_revision']='synthetic-pinned-v1'
    args['table']=put('table',table)
    inventory = dict(problem=None, advertised=[], missing_pages=[], changed_method_evidence={}, newly_discovered=[], missing_from_sitemap=[],last_method_evidence={})
    for rec, check in zip(json.loads((portable/'catalog.json').read_text())['records'],review['records']):
        assert rec['id']==check['id']
        slug=rec['source'].rsplit('/',1)[1]
        datasets=[{'description':'synthetic independently pinned method'}]
        inventory['advertised'].append(slug)
        page_digest=hashlib.sha256(('synthetic source page '+slug).encode()).hexdigest()
        inventory['last_method_evidence'][slug]=dict(source=rec['source'],datasets=datasets,fetched_at='test',page_sha256=page_digest)
        check['collector_datasets_sha256']=hashlib.sha256(json.dumps(datasets,sort_keys=True).encode()).hexdigest()
        check['page_sha256']=page_digest
    put('semantic-review.json',review)
    scope['semantic_review_sha256']=hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json',scope)
    put('method-pins.json',dict(task_scope_sha256=hashlib.sha256((root/'task-scope.json').read_bytes()).hexdigest(),catalog_sha256=scope['catalog_sha256'],semantic_review_sha256=scope['semantic_review_sha256'],records=[{k:r[k] for k in ('id','collector_datasets_sha256','page_sha256')} for r in review['records']]))
    snapshot=lambda: put('snapshot.json',{'evaluation_inventory':inventory})
    os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256'] = hashlib.sha256((root/'method-pins.json').read_bytes()).hexdigest()
    os.environ['FM_MODEL_PICKER_REGISTRY_SNAPSHOT']=snapshot()
    assert run(tag,simulator=None)[0]=='registry-offline-replay'
    inventory['last_method_evidence'][slug]['fetched_at'] = '2026-10-16T03:01:10Z'
    snapshot()
    status, worker, gates = run(tag, simulator=None, evidence_not_after='2026-10-16T03:01:09Z')
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-insufficient', None) and 'offline_request' not in audit
    assert audit['excluded']['terminal-bench-4-0'] == 'collector method acquired after the evidence cutoff or time unknown'
    assert run(tag, simulator=None, evidence_not_after='2026-10-16T03:01:10Z')[0] == 'registry-offline-replay'
    inventory['last_method_evidence'][slug]['datasets']=[{'description':'changed'}]
    snapshot()  # Daily diff empty: persistent reviewed pin must still detect drift.
    assert run(tag)[0]=='registry-insufficient'
    assert run('long_document_synthesis',simulator=None)[0]=='registry-offline-replay'
    del os.environ['FM_MODEL_PICKER_REGISTRY_SNAPSHOT']
    del os.environ['FM_MODEL_PICKER_METHOD_PINS_SHA256']
    # A synthetic reviewed overlap must not let the earlier proxy hide the exact fact.
    checks = {r['id']: r for r in review['records']}
    checks['aa-lcr']['overlap_group'] = checks['terminal-bench-4-0']['overlap_group']
    # Same-strength and same-family fixture: a later fact strictly covers the
    # earlier fact's acceptance tags as well as another required tag.
    terminal_tags = checks['terminal-bench-4-0']['required_tags']
    checks['terminal-bench-4-0']['required_tags'] = [*terminal_tags, 'long_document_synthesis']
    put('semantic-review.json', review)
    scope['semantic_review_sha256'] = hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json', scope)
    status, worker, gates = run([tag, 'long_document_synthesis'], simulator=None)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-offline-replay', None), (status, audit['included'])
    assert audit['included'] == ['terminal-bench-4-0'] and audit['uncovered_acceptance_tags'] == []
    assert 'strict superset' in audit['excluded']['aa-lcr']
    # This subtest uses the portable subcatalog even when the invocation's
    # top-level coverage helper is pinned to the full archive catalog.
    assert audit['catalog_coverage']['comparable'] == 1
    assert set(audit['included']) | set(audit['excluded']) == {r['id'] for r in json.loads((root/'catalog.json').read_bytes())['records']}
    checks['terminal-bench-4-0']['required_tags'] = terminal_tags
    put('semantic-review.json', review)
    scope['semantic_review_sha256'] = hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json', scope)
    status, worker, gates = run([tag, 'long_document_synthesis'], simulator=None)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-incomplete-acceptance', None)
    assert len(audit['included']) == 1 and 'offline_request' not in audit
    captured = (root/'observations.jsonl.gz').read_bytes()
    with gzip.open(root/'observations.jsonl.gz', 'wt') as dest:
        for line in gzip.decompress(captured).splitlines():
            obs = json.loads(line)
            if obs['metric_id'] in {label['id'] for label in checks['aa-lcr']['source_series']}:
                obs.pop('tool_condition', None)
            dest.write(json.dumps(obs)+'\n')
    review['evidence_hashes']['observations.jsonl.gz'] = hashlib.sha256((root/'observations.jsonl.gz').read_bytes()).hexdigest()
    put('semantic-review.json', review)
    scope['semantic_review_sha256'] = hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json', scope)
    assert run('long_document_synthesis', simulator=None)[0] == 'registry-proxy-only'
    status, worker, gates = run([tag, 'long_document_synthesis'], simulator=None)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-incomplete-acceptance', None), (status, audit['included'])
    assert audit['included'] == ['terminal-bench-4-0']
    assert audit['uncovered_acceptance_tags'] == ['long_document_synthesis']
    assert 'offline_request' not in audit and 'overlap' in audit['excluded']['aa-lcr']
    assert run(tag, simulator=None)[0] == 'registry-offline-replay'
    # Both exact rows still bind after tying the scores in the synthetic capture.
    metric = 'terminal-bench-4-0'
    tied_value = next(iter(fact['values'].values()))
    for slug in conditions:
        path = 'projection/' + slug + '.json'
        projection = json.loads((root/path).read_text())
        projection['metrics'][metric]['value'] = tied_value
        put(path, projection)
    series_ids = {label['id'] for label in checks[metric]['source_series']}
    captured = (root/'observations.jsonl.gz').read_bytes()
    with gzip.open(root/'observations.jsonl.gz', 'wt') as dest:
        for line in gzip.decompress(captured).splitlines():
            obs = json.loads(line)
            if obs['metric_id'] in series_ids:
                obs['value'] = tied_value
            dest.write(json.dumps(obs)+'\n')
    review['evidence_hashes']['observations.jsonl.gz'] = hashlib.sha256((root/'observations.jsonl.gz').read_bytes()).hexdigest()
    put('semantic-review.json', review)
    scope['semantic_review_sha256'] = hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json', scope)
    status, worker, gates = run(tag, simulator=positive_on_partial)
    audit = json.loads(gates)['registry']
    assert (status, worker) == ('registry-no-discrimination', None), (status, audit.get('simulated_pair'))
    assert audit['uncovered_acceptance_tags'] == [] and audit['included'] == [metric]
    assert {row['value'] for row in audit['support'][metric]['rows'].values()} == {tied_value}
    assert 'offline_request' not in audit and not partial_calls
    review['records']=[r for r in review['records'] if r['id']!='terminal-bench-4-0']
    put('semantic-review.json',review)
    scope=json.loads((portable/'task-scope.json').read_text())
    scope['semantic_review_sha256']=hashlib.sha256((root/'semantic-review.json').read_bytes()).hexdigest()
    put('task-scope.json',scope)
    assert run(tag)[0]=='registry-insufficient' and len(calls)==1
    print('PASS: synthetic mock-only pair, missing review, changed method, substituted task, exact effort, eligibility and privacy; no routing nominations')

    # The private full-catalog run also exercises the retained current projections.
    # The public default remains portable and does not depend on private captures.
    catalog = Path(sys.argv[1]).resolve()
    current = catalog.parent / 'variant-storage-replay'
    if current.is_dir():
        root = Path(tmp) / 'current'
        shutil.copytree(current/'projection', root/'projection')
        shutil.copy(current/'verdict.json', root/'verdict.json')
        args.update(table='bin/fm_model_picker/routes.json', task_text=str(root/'task'),
                    rules=str(root/'rules'), result=str(root/'result'), scratch=str(root))
        os.environ['FM_MODEL_PICKER_REGISTRY'] = str(catalog)
        report_bytes = (catalog.parent/'current-report-menu-replay.json').read_bytes()
        report = json.loads(report_bytes)
        report_profiles = [item['profile'] for item in report['public_exact_model_rows']]
        patch_profiles = [report_profiles[1], report_profiles[2]]
        report_task = 'Emit one status event with exact syntax and one verbatim snapshot.'
        pilot = catalog.parent/'exact-report-measurement-20261118-sonnet-high'
        if (pilot/'manifest.json').is_file():
            manifest = json.loads((pilot/'manifest.json').read_bytes())
            task_bytes = (pilot/'task.txt').read_bytes()
            assert hashlib.sha256(task_bytes).hexdigest() == manifest['task_sha256']
            assert hashlib.sha256(report_bytes).hexdigest() == manifest['observed_menu_sha256']
            report_task = task_bytes.decode('utf-8')
        grounded_bytes = (catalog.parent/'source-grounded-report-task.txt').read_bytes()
        grounded_digest = 'd3f90ef196cc991cd57f475b65acf177fe27b8cefaa04981e6826d881cb91891'
        assert hashlib.sha256(grounded_bytes).hexdigest() == grounded_digest
        grounded_task = grounded_bytes.decode('utf-8')
        grounded_tags = ['factual_correctness_checked', 'abstention_expected', 'incorrect_guess_penalized']
        for kind, task, tags, menu, expected, last_eligible in [
                ('patch', 'Repair the repository timing regression without raising the blocking test limit.',
                 ['repository_patch', 'blocking_maintainer_checks'], patch_profiles, 'registry-insufficient', True),
                ('grounded-report', grounded_task, grounded_tags, patch_profiles, 'registry-insufficient', True),
                ('report', report_task,
                 ['machine_checked_output_constraints'], report_profiles, 'registry-incomplete-menu', True),
                ('patch-sol-unavailable', 'Repair the repository timing regression without raising the blocking test limit.',
                 ['repository_patch', 'blocking_maintainer_checks'], patch_profiles, 'registry-insufficient', False)]:
            put('rules', {'default': menu})
            put('result', dict(status='clear', routing={'model': {'model': 'fixture'}},
                               chosen=dict(profile=menu[0], eligible=True),
                               candidates=[dict(profile=p, eligible=(last_eligible or i < len(menu) - 1),
                                                comparison_member=True) for i, p in enumerate(menu)]))
            status, worker, gates = run(tags, kind='repo-contract', text=task, simulator=None)
            audit = json.loads(gates)['registry']
            assert (status, worker) == (expected, None), (kind, status, audit)
            assert not audit['unjoined_resolver_members'] and not audit['unverified_eligibility']
            assert 'offline_request' not in audit
            coverage = check_catalog_coverage(audit)
            assert coverage == dict(total=63, comparable=0, historical_proxy=0, excluded=63)
            descriptive = audit.get('descriptive_public_evidence', [])
            if kind == 'patch':
                pair = json.loads((catalog.parent/'frontiercode-current-pair.json').read_text())['rows']
                assert {r['slug']: r['score'] for r in descriptive} == {r['slug']: r['score'] for r in pair}
                assert {r['scope'] for r in descriptive} == {'public-only; local parity unverified'}
            elif kind == 'grounded-report':
                assert audit['task_sha256'] == grounded_digest
                assert len(audit['routes']) == 2 and not audit['unmeasured_eligible']
                assert not descriptive and not audit['included']
                for metric in ('omniscience-accuracy', 'omniscience-hallucination-rate'):
                    assert audit['excluded'][metric] == 'no independent binding for this task kind'
                for metric in ('frontiercode', 'ifbench'):
                    assert audit['excluded'][metric] == 'acceptance tags incompatible'
            elif kind == 'report':
                assert len(audit['routes']) == 3 and list(audit['unmeasured_eligible'].values()) == [['omp:openai-codex/gpt-6-luna', 'low']]
                assert not descriptive and 'ifbench' not in audit['included']
            else:
                assert len(audit['routes']) == 1 and not descriptive
            print(json.dumps(dict(case=kind, status=status, admitted=sorted(audit['routes']),
                                  descriptive=descriptive, unmeasured=audit['unmeasured_eligible'],
                                  excluded=audit['excluded_candidates'], offline_request=None)))
        assert len(calls) == 1
        print('PASS: patch, grounded report, literal report and unavailable route through the current observer')

        # Exercise the deployed entry point with no credentials and a transport tripwire.
        import subprocess
        put('rules', {'default': report_profiles})
        put('result', dict(status='clear', routing={'model': {'model': 'fixture'}},
                           candidates=[dict(profile=p, eligible=True, comparison_member=True) for p in report_profiles]))
        tripwire = root/'transport-invoked'
        fake = root/'fake-bin'
        fake.mkdir()
        curl = fake/'curl'
        curl.write_text('#!/bin/sh\n: > "$FM_TEST_TRANSPORT_TRIPWIRE"\nexit 97\n')
        curl.chmod(0o700)
        env = dict(HOME=str(root), PATH=os.pathsep.join((str(fake), str(Path(sys.executable).parent), os.defpath)),
                   FM_HOME=str(root), FM_MODEL_PICKER_SHADOW='1', FM_MODEL_PICKER_DATA=str(root),
                   FM_MODEL_PICKER_REGISTRY=str(catalog), FM_TEST_TRANSPORT_TRIPWIRE=str(tripwire),
                   FM_MODEL_PICKER_ACCEPTANCE=str(root/'acceptance'))
        cmd = ['bash', 'bin/fm-model-picker-shadow.sh', '--observe', '--status', 'clear',
               '--task-text', str(root/'task'), '--rules', str(root/'rules'), '--result', str(root/'result')]
        lf = report_task.encode('utf-8').rstrip(b'\n') + b'\n'
        crlf = lf.replace(b'\n', b'\r\n')
        bad_utf8 = lf + b'\x80'
        for supplied, approved, expected in [
                (lf, lf, 'registry-incomplete-menu'),
                (crlf, crlf, 'registry-incomplete-menu'),
                (crlf, lf, 'registry-unavailable'),
                (bad_utf8, bad_utf8.decode('utf-8','replace').encode('utf-8'), 'registry-unavailable')]:
            (root/'task').write_bytes(supplied)
            put('acceptance', dict(task_sha256=hashlib.sha256(approved).hexdigest(), authorized_safe_scope=True,
                                   binding_kind='repo-contract', tags=['machine_checked_output_constraints']))
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            assert (result.returncode, result.stdout) == (0, ''), result.stderr
            with sqlite3.connect(root/'aa.sqlite') as db:
                status, worker, validator = db.execute('select picker_status,chosen_worker,chosen_validator from dispatch_log order by id desc limit 1').fetchone()
            assert (status, worker, validator) == (expected, None, None), (expected, status, result.stderr)
            assert not tripwire.exists()
        # The fact that both briefs yield a report is not permission to reuse
        # the literal report's acceptance receipt for the grounded brief.
        put('rules', {'default': patch_profiles})
        put('result', dict(status='clear', routing={'model': {'model': 'fixture'}},
                           chosen=dict(profile=patch_profiles[0], eligible=True),
                           candidates=[dict(profile=p, eligible=True, comparison_member=True) for p in patch_profiles]))
        (root/'task').write_bytes(grounded_bytes)
        for approved_digest, approved_tags, expected in [
                (grounded_digest, grounded_tags, 'registry-insufficient'),
                (hashlib.sha256(lf).hexdigest(), ['machine_checked_output_constraints'], 'registry-unavailable')]:
            put('acceptance', dict(task_sha256=approved_digest, authorized_safe_scope=True,
                                   binding_kind='repo-contract', tags=approved_tags))
            result = subprocess.run(cmd, env=env, capture_output=True, text=True)
            assert (result.returncode, result.stdout) == (0, ''), result.stderr
            with sqlite3.connect(root/'aa.sqlite') as db:
                last = db.execute('select picker_status,chosen_worker,chosen_validator from dispatch_log order by id desc limit 1').fetchone()
            assert last == (expected, None, None), (expected, last, result.stderr)
            assert not tripwire.exists()
        print('PASS: observer CLI binds exact UTF-8 bytes and rejects a swapped report contract without transport or nomination')
PY
