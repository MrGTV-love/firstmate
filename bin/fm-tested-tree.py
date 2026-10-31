#!/usr/bin/env python3
"""Verify Actions tested-tree artifact names for an exact head and landing tip.

Called by fm-pr-merge.sh, not a waiver interface. Exit 0 proves every check run
has a verified matching tree, 1 means evidence unavailable (ancestry fallback),
2 means complete verified records prove a different tree (refuse even if the
head contains the tip). Artifact metadata is read only through gh. Names bind
HEAD^{tree}, HEAD^1 (the actual merge parent, not the event's possibly newer
base SHA), and run attempt. Nothing from an artifact is executed or extracted.
"""
import json
import os
import re
import subprocess
import sys
import tempfile


class Unavailable(Exception):
    pass


def command(*args, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, check=False, **kwargs)
    if result.returncode:
        raise Unavailable()
    return result.stdout.strip()


def api(repo, endpoint):
    # --slurp preserves page boundaries so partial lists cannot prove coverage.
    return json.loads(command('gh', 'api', '--paginate', '--slurp',
                              f'repos/{repo}/{endpoint}'))


def listing(repo, endpoint, key):
    pages = api(repo, endpoint)
    counts = {p['total_count'] for p in pages}
    rows = [row for page in pages for row in page[key]]
    if len(counts) != 1 or next(iter(counts)) != len(rows):
        raise Unavailable()
    return rows


def verify(repo, head, tip, worktree):
    runs = listing(repo, f'commits/{head}/check-runs', 'check_runs')
    if not runs or len({r['id'] for r in runs}) != len(runs):
        raise Unavailable()
    records = []
    cache = {}
    for check in runs:
        if check['head_sha'] != head or check['app']['slug'] != 'github-actions':
            raise Unavailable()
        match = re.fullmatch(r'https://github\.com/' + re.escape(repo)
                             + r'/actions/runs/(\d+)/job/(\d+)', check['details_url'])
        if not match:
            raise Unavailable()
        run_id, job_id = map(int, match.groups())
        job = api(repo, f'actions/jobs/{job_id}')[0]
        attempt = job['run_attempt']
        if (job['run_id'] != run_id or job['name'] != check['name']
                or job['check_run_url'] != f'https://api.github.com/repos/{repo}/check-runs/{check["id"]}'):
            raise Unavailable()
        key = run_id, attempt
        if key not in cache:
            run = api(repo, f'actions/runs/{run_id}/attempts/{attempt}')[0]
            if (run['id'] != run_id or run['run_attempt'] != attempt
                    or run['event'] != 'pull_request' or run['head_sha'] != head):
                raise Unavailable()
            artifacts = listing(repo, f'actions/runs/{run_id}/artifacts', 'artifacts')
            found = set()
            for artifact in artifacts:
                name = re.fullmatch(r'fm-tested-tree-([0-9a-f]{40})-base-([0-9a-f]{40})-attempt-'
                                    + str(attempt), artifact['name'])
                if name and artifact['expired'] is False:
                    source = artifact['workflow_run']
                    if source['id'] != run_id or source['head_sha'] != head:
                        raise Unavailable()
                    found.add(name.groups())
            if len(found) != 1:
                raise Unavailable()
            cache[key] = found.pop()
        records.append(cache[key])

    with tempfile.TemporaryDirectory(prefix='fm-tested-tree-') as directory:
        command('git', 'init', '--bare', '-q', directory)
        environment = os.environ.copy()
        if worktree and os.path.isdir(worktree):
            objects = command('git', '-C', worktree, 'rev-parse', '--path-format=absolute',
                              '--git-path', 'objects')
            environment['GIT_ALTERNATE_OBJECT_DIRECTORIES'] = objects
        def git(*args):
            return command('git', '-C', directory, *args, env=environment)
        # Missing objects are fetched into this private scratch repository only;
        # the credential helper uses the existing gh grant without printing it.
        for sha in {head, tip, *(base for _, base in records)}:
            try:
                git('cat-file', '-e', sha + '^{commit}')
            except Unavailable:
                git('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
                    'fetch', '--no-tags', '--no-write-fetch-head',
                    f'https://github.com/{repo}.git', sha)
        for tree, base in records:
            if git('merge-tree', '--write-tree', base, head) != tree:
                raise Unavailable()
        landing = git('merge-tree', '--write-tree', tip, head)
        if any(tree != landing for tree, _ in records):
            return 2
        print(landing)
        return 0


if __name__ == '__main__':
    try:
        sys.exit(verify(*sys.argv[1:]))
    except (Unavailable, KeyError, IndexError, TypeError, ValueError, OSError):
        sys.exit(1)
