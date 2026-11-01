#!/usr/bin/env python3
"""Read-only heartbeat evidence, never a guard or an attribution of intent.

Usage: python3 bin/fm-guard-workarounds.py [--state <dir>] [--log <jsonl>]
       [--repo <path> --head <ref> --task <id>] [--json] [--limit <n>]
The home scan inspects only local ship/scout metadata and the recorded branch
(or HEAD in its isolated copy). No fetch, checkout, ref update or event write.
The most recent --limit first-parent commits are inspected (default 100),
excluding the recorded base lineage in a home scan (--base in explicit mode).
A bare base name resolves to refs/remotes/origin/<name> first, then the local branch.
A tree-equal merge is a signature, not proof that a refusal caused the merge.
A base-merge-only change additionally requires a task/head-bound merge denial,
a later commit time, and second parents reachable from that denial's base ref.
Legacy events without a task, head or base cannot establish that second claim.
Text output is one line per task; --json emits one object per signature, suitable
for fm-guard-metrics.sh --workarounds. Nothing is disabled or automatically fixed.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess


SHA = re.compile(r'[0-9a-f]{40,64}\Z')


def git(repo, *args):
    result = subprocess.run(['git', '--no-optional-locks', '-C', str(repo), *args],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else ''


def resolve_base(repo, ref):
    # A bare branch name is the base as the forge sees it, so the fetched
    # origin ref wins over a possibly stale or absent local branch.
    candidates = [ref] if ref.startswith('refs/') else ['refs/remotes/origin/' + ref, 'refs/heads/' + ref]
    for candidate in candidates:
        sha = git(repo, 'rev-parse', '--verify', '--end-of-options', candidate + '^{commit}')
        if SHA.fullmatch(sha):
            return sha
    return ''


def events(path):
    try:
        with open(path, encoding='utf-8') as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if isinstance(event, dict):
                    yield event
    except OSError:
        return


def scan(repo, head, task, refusals, limit, base_ref=''):
    tip = git(repo, 'rev-parse', '--verify', '--end-of-options', head + '^{commit}')
    if not SHA.fullmatch(tip):
        return []
    exclude = []
    base_tip = resolve_base(repo, base_ref) if base_ref else ''
    if base_tip:
        exclude = ['--not', base_tip]
    commits = [line.split() for line in git(
        repo, 'log', '--first-parent', f'--max-count={limit}',
        '--format=%H %T %ct %P', tip, *exclude, '--').splitlines()]
    trees = {row[0]: row[1] for row in commits}
    committed_times = {row[0]: int(row[2]) for row in commits}
    signatures = []
    for commit, tree, _committed_at, *parents in commits:
        if len(parents) < 2:
            continue
        # Every interior first parent is already in the bounded log; only the
        # base/limit boundary needs another read, not two git processes per merge.
        parent_tree = trees.get(parents[0])
        if parent_tree is None:
            parent_tree = git(repo, 'rev-parse', parents[0] + '^{tree}')
            trees[parents[0]] = parent_tree
        if tree and tree == parent_tree:
            signatures.append(dict(guard='merge-green-head', rule='base-containment',
                                   task=task, head=commit, kind='tree-equal-merge'))
    for event in refusals:
        if event.get('task') != task or not SHA.fullmatch(str(event.get('head', ''))):
            continue
        old = event['head']
        if old == tip or not event.get('base'):
            continue
        # --ancestry-path alone would include merges along non-first parents.
        # The first-parent path must actually end at the refused head.
        chain = []
        for commit, _tree, _committed_at, *parents in commits:
            if commit == old:
                break
            chain.append((commit, parents))
        else:
            continue
        base = resolve_base(repo, event['base'])
        if not base:
            continue
        try:
            refused_at = datetime.datetime.fromisoformat(event['ts'].replace('Z', '+00:00')).timestamp()
        except (KeyError, TypeError, ValueError):
            continue
        base_lineage = set(git(repo, 'log', '--first-parent', f'--max-count={limit}',
                               '--format=%H', base, '--').splitlines())
        valid = True
        for commit, parents in chain:
            if (len(parents) != 2 or parents[1] not in base_lineage
                    or committed_times[commit] < refused_at):
                valid = False
                break
        if valid and chain:
            signatures.append(dict(guard=event['guard'], rule=event.get('rule') or event['guard'],
                                   task=task, head=tip, refused_head=old, kind='base-merge-only-after-refusal'))
    return signatures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--state', default=str(Path(os.environ.get('FM_HOME', Path(__file__).resolve().parent.parent)) / 'state'))
    parser.add_argument('--log')
    parser.add_argument('--repo')
    parser.add_argument('--head', default='HEAD')
    parser.add_argument('--base', default='', help='exclude history already on this base ref')
    parser.add_argument('--task', default='')
    parser.add_argument('--limit', type=int, default=100)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    if args.limit < 1:
        parser.error('--limit must be positive')
    state = Path(args.state)
    log = args.log or os.environ.get('FM_GUARD_EVENT_LOG') or str(state / 'guard-events.jsonl')
    refusals = [e for e in events(log) if e.get('decision') == 'deny' and e.get('guard') == 'merge-green-head']
    targets = []
    if args.repo:
        targets.append((args.repo, args.head, args.task, args.base))
    else:
        for path in sorted(state.glob('*.meta')):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                metadata = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
            except (OSError, UnicodeError):
                continue
            if metadata.get('remote_host') or metadata.get('kind') not in ('ship', 'scout'):
                continue
            repo = metadata.get('worktree')
            if not repo or not Path(repo).is_dir():
                continue
            branch = metadata.get('branch')
            base = metadata.get('base_branch') or git(repo, 'symbolic-ref', 'refs/remotes/origin/HEAD') or 'main'
            targets.append((repo, 'refs/heads/' + branch if branch else 'HEAD', path.stem, base))
    seen = set()
    for repo, head, task, base in targets:
        found = []
        for signature in scan(repo, head, task, refusals, args.limit, base):
            key = (task, signature['head'], signature['kind'], signature['rule'])
            if key in seen:
                continue
            seen.add(key)
            found.append(signature)
            if args.json:
                print(json.dumps(signature))
        if found and not args.json:
            details = ','.join(f"{s['kind']}:{s['head']}" for s in found)
            print(f'GUARD_WORKAROUND task={task} signatures={details} (read-only evidence; reassess the guard)')


if __name__ == '__main__':
    main()
