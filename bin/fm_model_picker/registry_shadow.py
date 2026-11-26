"""Strict, local evidence join for the opt-in registry shadow challenger."""
import gzip
import io
import hashlib
import json
import math
import os
from collections import defaultdict
from datetime import datetime
from pathlib import Path
import re

TOKEN = re.compile(r'[a-z0-9][a-z0-9_-]{0,63}\Z')


def utc_timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', value, flags=re.ASCII):
        return False
    try:
        datetime.fromisoformat(value[:-1] + '+00:00')
    except ValueError:
        return False
    return True


def tags(text, vocabulary):
    acceptance = json.loads(Path(os.environ['FM_MODEL_PICKER_ACCEPTANCE']).read_bytes())
    words = acceptance['tags']
    if (acceptance.get('authorized_safe_scope') is not True or not text or
            acceptance.get('task_sha256') != hashlib.sha256(text.encode()).hexdigest() or
            not isinstance(words, list) or not 0 < len(words) <= 16 or
            not all(isinstance(w, str) and TOKEN.fullmatch(w) and w in vocabulary for w in words) or
            'unsafe_or_unreviewed_scope' in words):
        raise ValueError('invalid task acceptance')
    kind = acceptance.get('binding_kind')
    if kind not in ('design-fixture', 'repo-contract'):
        raise ValueError('unknown task binding')
    cutoff = acceptance.get('evidence_not_after')
    if 'evidence_not_after' in acceptance and not utc_timestamp(cutoff):
        raise ValueError('invalid evidence cutoff; expected exact UTC timestamp')
    fields = ('acceptance_sha256', 'validation_policy_sha256')
    policy = {field: acceptance[field] for field in fields if field in acceptance}
    if policy and (len(policy) != len(fields) or not all(
            isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value) for value in policy.values())):
        raise ValueError('expected both exact acceptance and validation policy digests')
    return set(words), kind, cutoff, policy


def index(rows):
    out = {}
    for row in rows:
        key = row['id']
        if not TOKEN.fullmatch(key) or key in out:
            raise ValueError('invalid or duplicate registry ID')
        out[key] = row
    return out


def agreement(obs, exact):
    if obs['value'] == exact:
        return True
    # Only the precision actually printed in a corroborating display is admissible.
    match = re.fullmatch(r'(\d+)(?:\.(\d+))?(%)?', obs.get('raw') or '')
    if not match or obs['source'] not in ('comparison-table', 'rendered-chart', 'eval-leaderboard'):
        return False
    factor = 100 if match[3] else 1
    return (math.isclose(float(obs['raw'].rstrip('%')), obs['value'] * factor) and
            abs(obs['value'] - exact) <= 0.5 * 10 ** -len(match[2] or '') / factor + 1e-12)


def complete_fact_cover(entries, required, limit):
    """Find a bounded comparable cover, with one fact per family and no score weights."""
    bits = {tag: 1 << i for i, tag in enumerate(sorted(required))}
    full = (1 << len(bits)) - 1
    families = defaultdict(list)
    for group, fact, _ in entries:
        if fact['scope'] == 'comparable':
            mask = sum(bits[tag] for tag in set(fact['acceptance_tags']) & bits.keys())
            if mask:
                families[group].append((fact['metric'], mask))

    # Each step consumes a whole family. For a given coverage mask only the
    # shortest (then lexically first) witness matters to the remaining families.
    states = {0: ()}
    for choices in families.values():
        updated = states.copy()
        for covered, chosen in states.items():
            if len(chosen) == limit:
                continue
            for metric, mask in choices:
                merged = covered | mask
                if merged == covered:
                    continue
                proposal = tuple(sorted((*chosen, metric)))
                current = updated.get(merged)
                if current is None or (len(proposal), proposal) < (len(current), current):
                    updated[merged] = proposal
        states = updated
    return states.get(full, ())


def evidence(path, text, candidates):
    path = Path(path)
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    catalog = index(json.loads(raw)['records'])
    review_bytes = path.with_name('semantic-review.json').read_bytes()
    review = json.loads(review_bytes)
    scope_bytes = path.with_name('task-scope.json').read_bytes()
    scope = json.loads(scope_bytes)
    review_digest = hashlib.sha256(review_bytes).hexdigest()
    scope_digest = hashlib.sha256(scope_bytes).hexdigest()
    if scope['catalog_sha256'] != digest or scope['semantic_review_sha256'] != review_digest:
        raise ValueError('task scope does not match review')
    bindings = index(scope['records'])
    if review['catalog_sha256'] != digest:
        raise ValueError('independent review does not match catalog')
    reviewed = index(review['records'])
    task, kind, cutoff, policy = tags(text, review['tag_vocabulary'])

    def available(value):
        return cutoff is None or utc_timestamp(value) and value <= cutoff

    archive = path.with_name('observations.jsonl.gz')
    archive_bytes = archive.read_bytes()
    if hashlib.sha256(archive_bytes).hexdigest() != review['evidence_hashes'][archive.name]:
        raise ValueError('observation archive does not match review')
    audit = {'catalog_sha256': digest, 'observations_sha256': review['evidence_hashes'][archive.name],
             'semantic_review_sha256': review_digest, 'task_scope_sha256': scope_digest,
             'task_sha256': hashlib.sha256(text.encode('utf-8')).hexdigest(), 'task_binding_kind': kind,
             'acceptance_tags': sorted(task), 'evidence_not_after': cutoff,
             'excluded': {}, 'included': [], 'support': {}, **policy}
    snapshot = os.environ.get('FM_MODEL_PICKER_REGISTRY_SNAPSHOT')
    inventory = json.loads(Path(snapshot).read_bytes())['evaluation_inventory'] if snapshot is not None else None
    audit['mode'] = 'collector-pinned-replay' if snapshot is not None else 'frozen-historical-replay'
    pins = {}
    pin_path = path.with_name('method-pins.json')
    expected_pin = os.environ.get('FM_MODEL_PICKER_METHOD_PINS_SHA256')
    if expected_pin is not None or (snapshot is not None and pin_path.exists()):
        # An explicit commitment applies even without a collector overlay.
        # A derivative document cannot authorize its own changed declaration.
        pin_bytes = pin_path.read_bytes()
        pin_digest = hashlib.sha256(pin_bytes).hexdigest()
        if expected_pin != pin_digest:
            raise ValueError('collector method pins do not match the separate review commitment')
        audit['method_pins_sha256'] = pin_digest
        pin_doc = json.loads(pin_bytes)
        if (pin_doc['catalog_sha256'] != digest or pin_doc['semantic_review_sha256'] != review_digest or
                pin_doc['task_scope_sha256'] != scope_digest):
            raise ValueError('collector method pins do not match independent review')
        pins = index(pin_doc['records'])
    excluded = audit['excluded']
    chosen = {}
    for key, rec in sorted(catalog.items()):
        check = reviewed.get(key, {})
        if check.get('disposition') != 'shadow-eligible':
            excluded[key] = 'unreviewed or not shadow-eligible'
            continue
        binding = bindings.get(key, {})
        if binding.get('task_bound') is not True or binding.get('binding_kind') != kind:
            excluded[key] = 'no independent binding for this task kind'
            continue
        need, avoid = check['required_tags'], check['excluded_tags']
        if not all(isinstance(seq, list) and all(TOKEN.fullmatch(t) for t in seq) for seq in (need, avoid)):
            raise ValueError('malformed review tags')
        if not need or not set(need) <= task or task.intersection(avoid):
            excluded[key] = 'acceptance tags incompatible'
            continue
        group = check['overlap_group']
        if not TOKEN.fullmatch(group) or rec['direction'] not in ('higher', 'lower'):
            excluded[key] = 'unknown overlap or direction'
            continue
        if snapshot is not None:
            source = rec.get('source', '')
            slug = source.rsplit('/', 1)[-1]
            current = inventory['last_method_evidence'].get(slug, {})
            datasets = current.get('datasets')
            pin = pins.get(key, {})
            if (not source.startswith('https://artificialanalysis.ai/evaluations/') or
                    inventory.get('problem') or slug not in inventory['advertised'] or
                    any(slug in inventory[k] for k in ('newly_discovered', 'missing_from_sitemap', 'missing_pages', 'changed_method_evidence')) or
                    current.get('source') != source or not current.get('fetched_at') or not current.get('page_sha256') or
                    not datasets or hashlib.sha256(json.dumps(datasets, sort_keys=True).encode()).hexdigest() !=
                    pin.get('collector_datasets_sha256')):
                excluded[key] = 'collector method missing, changed or not independently pinned'
                continue
            reviewed_page = pin.get('page_sha256')
            # A stable Dataset declaration cannot witness text elsewhere in the page.
            if (not isinstance(reviewed_page, str) or not re.fullmatch(r'[a-f0-9]{64}', reviewed_page) or
                    current['page_sha256'] != reviewed_page):
                excluded[key] = 'collector page bytes differ from the reviewed page'
                continue
            if not available(current.get('fetched_at')):
                excluded[key] = 'collector method acquired after the evidence cutoff or time unknown'
                continue
        chosen[key] = (rec, group)
    slugs = {c['projection']['slug']: c['projection']['name'] for c in candidates}
    ids = {l['id'] for rec, _ in chosen.values() for l in rec['labels']}
    obs = defaultdict(list)
    if ids and slugs:
        with gzip.GzipFile(fileobj=io.BytesIO(archive_bytes)) as stream:
            for line in stream:
                o = json.loads(line)
                if o['slug'] in slugs and o['metric_id'] in ids and available(o.get('observed_at')):
                    obs[o['slug'], o['metric_id']].append(o)
    admissible = []
    for key, (rec, group) in chosen.items():
        versions = [l for l in rec['labels'] if l.get('version') or re.search(r'\b\d+\.\d+\b', l['label'])]
        if len(versions) != 1:
            excluded[key] = 'no unique revision-bound label'
            continue
        label = versions[0]
        if {k: label[k] for k in ('id', 'label', 'version', 'unit', 'scale')} not in reviewed[key]['source_series']:
            excluded[key] = 'series not independently reviewed'
            continue
        values = {}
        exact_conditions = True
        tools = set()
        for c in candidates:
            slug = c['projection']['slug']
            rows = [o for o in obs[slug, label['id']] if not o['partial'] and not o['derived']]
            fact = c['metrics'].get(key, {})
            if fact and not available(fact.get('observed_at')):
                excluded[key] = 'projection acquired after the evidence cutoff or time unknown'
                break
            if (fact.get('label') != label['label'] or fact.get('unit') != label['unit'] or
                    fact.get('scale') != label['scale'] or not rows or
                    any(o.get('name') != slugs[slug] or o['variant'] != '' for o in rows) or
                    any(fact.get(k) is not False for k in ('partial', 'derived', 'estimated'))):
                break
            value = fact.get('value')
            if type(value) not in (float, int) or not math.isfinite(value) or not any(
                    o['value'] == value and o['source'] == fact['source'] and o['observed_at'] == fact['observed_at'] for o in rows):
                break
            if not all(agreement(o, value) for o in rows):
                break
            condition = c.get('registry_condition') or {}
            fields = ('model_build', 'tool_condition', 'population', 'split', 'scoring', 'effort', 'method_revision')
            if any(len({o[f] for o in rows if o.get(f)} | ({condition[f]} if condition.get(f) else set())) > 1
                   for f in fields):
                break
            for field in fields:
                if not condition.get(field) or any(o.get(field) != condition[field] for o in rows):
                    exact_conditions = False
            if condition.get('effort') != c['effort_configured']:
                exact_conditions = False
            tools.add(tuple(condition.get(k) for k in ('tool_condition', 'population', 'split', 'scoring', 'method_revision')))
            values[c['id']] = value
        if not candidates or len(values) != len(candidates) or len(tools) != 1:
            excluded.setdefault(key, 'incompatible or missing comparable observations')
            continue
        fact = {'metric': key, 'revision': label.get('version') or label['label'],
                'unit': label['unit'], 'scale': label['scale'], 'direction': rec['direction'],
                'values': values, 'acceptance_tags': reviewed[key]['required_tags'],
                'scope': 'comparable' if exact_conditions else 'historical-proxy'}
        admissible.append((group, fact, label['id']))

    # A comparable representative cannot suppress strictly broader reviewed
    # coverage in its own overlap family. No cross-metric score is needed.
    exact_coverages = defaultdict(list)
    for group, fact, _ in admissible:
        if fact['scope'] == 'comparable':
            exact_coverages[group].append(set(fact['acceptance_tags']))

    ranked = []
    for group, fact, series in sorted(admissible, key=lambda entry: entry[1]['scope'] != 'comparable'):
        if fact['scope'] == 'comparable' and any(set(fact['acceptance_tags']) < tags for tags in exact_coverages[group]):
            excluded[fact['metric']] = 'overlap family has comparable evidence covering a strict superset of acceptance tags'
        else:
            ranked.append((group, fact, series))

    def bounded(entries):
        selected, groups = [], set()
        for group, fact, series in entries:
            if group not in groups and len(selected) < 6:
                selected.append((group, fact, series))
                groups.add(group)
        return selected

    selected = bounded(ranked)
    covered = {tag for _, fact, _ in selected if fact['scope'] == 'comparable' for tag in fact['acceptance_tags']}
    if not task <= covered:
        witness = set(complete_fact_cover(ranked, task, 6))
        if witness:
            selected = bounded(sorted(ranked, key=lambda entry: entry[1]['metric'] not in witness))
            audit['coverage_recovered'] = True

    retained = {fact['metric'] for _, fact, _ in selected}
    for _, fact, _ in ranked:
        if fact['metric'] not in retained:
            excluded[fact['metric']] = 'overlap or metric bound'
    facts = []
    for _, fact, series in selected:
        key = fact['metric']
        facts.append(fact)
        audit['included'].append(key)
        audit['support'][key] = {'series': series, 'scope': fact['scope'], 'rows': {
            c['id']: {'slug': c['projection']['slug'], 'value': fact['values'][c['id']],
                      'observed_at': c['metrics'][key]['observed_at'], 'source': c['metrics'][key]['source']}
            for c in candidates}}
    # Audit only: this revision has public patch evidence, not local tool parity.
    descriptive = []
    if 'frontiercode' in chosen and len(candidates) >= 2:
        for c in candidates:
            m = c['metrics'].get('frontiercode-2-0', {})
            if (m.get('label') != 'FrontierCode-AA 2.0' or m.get('source') != 'embedded' or
                    m.get('unit') != 'fraction' or m.get('scale') != 'fraction' or
                    not all(m.get(flag) is False for flag in ('derived', 'estimated', 'partial')) or
                    not m.get('observed_at') or not available(m.get('observed_at')) or
                    type(m.get('value')) not in (int, float) or
                    not 0 <= m['value'] <= 1):
                break
            descriptive.append({'slug': c['projection']['slug'], 'score': m['value'],
                                'observed_at': m['observed_at'], 'metric': 'frontiercode-2-0',
                                'scope': 'public-only; local parity unverified'})
        else:
            audit['descriptive_public_evidence'] = descriptive
    for fact in facts:
        if fact['scope'] != 'comparable':
            continue
        key = fact['metric']
        fact['provenance'] = {
            'evaluation': chosen[key][0]['source'],
            'method_revision': candidates[0]['registry_condition']['method_revision'],
            'rows': {option: {k: row[k] for k in ('source', 'observed_at')}
                     for option, row in audit['support'][key]['rows'].items()},
        }
    admitted = set(audit['included'])
    if len(admitted) != len(facts) or admitted.intersection(excluded) or admitted.union(excluded) != catalog.keys():
        raise ValueError('incomplete or conflicting catalog disposition')
    comparable_count = sum(f['scope'] == 'comparable' for f in facts)
    audit['catalog_coverage'] = {'total': len(catalog), 'comparable': comparable_count,
                                 'historical_proxy': len(facts) - comparable_count,
                                 'excluded': len(excluded)}
    return facts, audit
