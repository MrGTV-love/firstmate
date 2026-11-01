#!/usr/bin/env python3
"""Independent replay of the 135-family / 113-site classification against the
PR head, using the PR's real base commit. Read-only. Asserts semantics, prints counts."""
import collections, csv, json, re, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1]).resolve(); base = sys.argv[2]
home = Path('/Users/charlesabrooker/fleet/fm-mini-home')
helpers = home / 'data/fm-guard-policy-20261031/helpers'
ev = home / 'data/fm-guard-registry-burn-down'
git = lambda *a: subprocess.check_output(['git', '-C', str(root), *a])
rows = list(csv.DictReader((helpers / 'unregistered-families.tsv').open(), delimiter='\t'))
maps = [r for i in range(1, 8) for r in csv.reader((helpers / f'map{i}.tsv').open(), delimiter='\t') if r]
rec = json.loads((ev / 'site-reconciliation.json').read_text())
old = json.loads(git('show', base + ':docs/guards/registry.json'))
old_ids = {g['id'] for g in old['guards']}
policy = {r['family_id'] for r in rows if r['kind'] == 'policy-guard'}
redesign = set(rec['redesign']); keep = policy - redesign; new_ids = keep - old_ids
out = {'policy_families_in_tsv': len(policy), 'redesign_excluded': len(redesign),
       'kept_families': len(keep), 'kept_new_ids': len(new_ids), 'kept_already_registered': len(keep & old_ids)}
canonical = [(k, ref, 'treehouse-slot-lock-serialization' if ref in rec['project_lock_refs']
              else rec['aliases'].get(f, f)) for k, ref, f in maps]
reg = json.loads((root / 'docs/guards/registry.json').read_text())
guards = {g['id']: g for g in reg['guards']}
out['registry_guards_head'] = len(guards); out['registry_guards_base'] = len(old_ids)
out['kept_missing_from_registry'] = sorted(keep - set(guards))
out['redesign_wrongly_registered'] = sorted((redesign - old_ids) & set(guards))
out['unexpected_new_ids'] = sorted(set(guards) - old_ids - new_ids)
changed_old = [g['id'] for g in old['guards'] if {k: v for k, v in g.items() if k not in ('sites', 'layer_note')}
               != {k: v for k, v in guards[g['id']].items() if k not in ('sites', 'layer_note')}]
out['preexisting_entries_changed_beyond_sites'] = changed_old
scan = json.loads(subprocess.check_output([sys.executable, str(root / 'bin/fm-guard-sites.py'), '--root', str(root)]))
sites = {s['key']: s for s in scan['sites']}
out['scanner_errors'] = scan['errors']; out['sites_head'] = len(sites)
out['mapped_head'] = sum(s['entry'] is not None for s in scan['sites'])
covered = [(k, f) for k, _, f in canonical if f in old_ids or f in {'spawn-write-confinement-raw-parse', 'jev-block-renderer'}]
selected = [(k, f) for k, _, f in canonical if f in keep or f == 'spawn-confinement-coverage']
out['covered_sites_classified'] = len(covered); out['kept_sites_classified'] = len(selected)
gone = [k for k, _ in selected if k not in sites]
wrong = [(k, f, sites[k]['entry']) for k, f in selected if k in sites and sites[k]['entry'] != f]
out['classified_site_keys_no_longer_in_source'] = gone
out['classified_sites_wrong_owner'] = wrong
out['covered_sites_mapped_to_family'] = sum(1 for k, f in covered if k in sites and sites[k]['entry'] == f)
cred = 'site:bin/fm-git-secrets.py:2cc52cb9c6'
out['credential_site'] = {k: sites[cred][k] for k in ('file', 'line', 'sig', 'entry', 'text')} if cred in sites else None
out['redesign_sites_left_unmapped'] = all(sites[k]['entry'] is None for k, _, f in canonical if f in redesign and k in sites)
oa = json.loads(git('show', base + ':docs/guards/lint-allowlist.json'))
na = json.loads((root / 'docs/guards/lint-allowlist.json').read_text())
op = {(r['id'], r['rule']) for r in oa['allowed']}; np_ = {(r['id'], r['rule']) for r in na['allowed']}
out['allowlist_base'] = len(op); out['allowlist_head'] = len(np_)
out['allowlist_added_entries'] = sorted(np_ - op)
out['allowlist_removed_not_by_mapping'] = sorted((op - np_) - {(k, 'S1') for k in sites if sites[k]['entry']} - {(k, 'S1') for k, _ in selected})
out['unmapped_sites_equal_S1_allowlist'] = ({s['key'] for s in scan['sites'] if s['entry'] is None}
                                             == {k for k, r in np_ if r == 'S1'})
print(json.dumps(out, indent=2))
