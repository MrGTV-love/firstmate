#!/usr/bin/env python3
"""Verify Actions tested-tree artifact names for an exact head and landing tip.

Usage: fm-tested-tree.py <owner/repo> <head> <tip> <scratch> <worktree> [--offline]

Called by fm-pr-merge.sh, not a waiver interface. Exit 0 proves every check run
has a verified matching tree, 1 means evidence unavailable (ancestry fallback,
with a one-line reason on stderr), 2 means complete verified records prove a
different tree (refuse even if the head contains the tip). Artifact metadata is
read only through gh. Names bind HEAD^{tree}, HEAD^1 (the actual merge parent,
not the event's possibly newer base SHA), and run attempt. Nothing from an
artifact is executed or extracted.

<scratch> is a private bare repository the caller owns for one invocation.
The verdict for a head is kept there with the check-run ids it covered; a
later call lists the check runs again and reuses the verdict only for the same
ids. --offline makes no gh call and no fetch: it needs a verdict an earlier
call made and the tip's objects already local, and is used at the final read.
"""
import json
import os
import re
import subprocess
import sys


class Unavailable(Exception):
    pass


def command(*args, reason, **kwargs):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            text=True, check=False, **kwargs)
    if result.returncode:
        raise Unavailable(reason)
    return result.stdout.strip()


def api(repo, endpoint):
    # --slurp preserves page boundaries so partial lists cannot prove coverage.
    return json.loads(command('gh', 'api', '--paginate', '--slurp',
                              f'repos/{repo}/{endpoint}',
                              reason='a GitHub Actions read failed'))


def listing(repo, endpoint, key):
    pages = api(repo, endpoint)
    counts = {p['total_count'] for p in pages}
    rows = [row for page in pages for row in page[key]]
    if len(counts) != 1 or next(iter(counts)) != len(rows):
        raise Unavailable('a GitHub Actions list was incomplete')
    return rows


def check_runs(repo, head):
    runs = listing(repo, f'commits/{head}/check-runs', 'check_runs')
    if not runs or len({r['id'] for r in runs}) != len(runs):
        raise Unavailable(f'the check runs at head {head} are empty or repeated')
    return runs


def read_records(repo, head, runs):
    records = []
    cache = {}
    for check in runs:
        if check['head_sha'] != head or check['app']['slug'] != 'github-actions':
            raise Unavailable(f'check run {check["id"]} is not a GitHub Actions run at head {head}')
        match = re.fullmatch(r'https://github\.com/' + re.escape(repo)
                             + r'/actions/runs/(\d+)/job/(\d+)', check['details_url'],
                             re.IGNORECASE)
        if not match:
            raise Unavailable(f'check run {check["id"]} does not link a job of this repository')
        run_id, job_id = map(int, match.groups())
        job = api(repo, f'actions/jobs/{job_id}')[0]
        attempt = job['run_attempt']
        if (job['run_id'] != run_id or job['name'] != check['name']
                or job['check_run_url'].lower()
                != f'https://api.github.com/repos/{repo}/check-runs/{check["id"]}'.lower()):
            raise Unavailable(f'job {job_id} does not match check run {check["id"]}')
        key = run_id, attempt
        if key not in cache:
            run = api(repo, f'actions/runs/{run_id}/attempts/{attempt}')[0]
            if (run['id'] != run_id or run['run_attempt'] != attempt
                    or run['event'] != 'pull_request' or run['head_sha'] != head):
                raise Unavailable(f'run {run_id} attempt {attempt} is not a pull_request run at head {head}')
            artifacts = listing(repo, f'actions/runs/{run_id}/artifacts', 'artifacts')
            found = set()
            for artifact in artifacts:
                name = re.fullmatch(r'fm-tested-tree-([0-9a-f]{40})-base-([0-9a-f]{40})-attempt-'
                                    + str(attempt), artifact['name'])
                if name and artifact['expired'] is False:
                    source = artifact['workflow_run']
                    if source['id'] != run_id or source['head_sha'] != head:
                        raise Unavailable(f'a tested-tree record of run {run_id} names another run or head')
                    found.add(name.groups())
            if len(found) != 1:
                raise Unavailable(f'run {run_id} attempt {attempt} has no single tested-tree record')
            cache[key] = found.pop()
        records.append(cache[key])
    return records


def verify(repo, head, tip, scratch, worktree, *mode):
    if mode not in ((), ('--offline',)):
        raise Unavailable('the arguments were not understood')
    offline = bool(mode)
    if not os.path.isfile(os.path.join(scratch, 'HEAD')):
        command('git', 'init', '--bare', '-q', scratch, reason='the scratch repository could not be made')
    environment = os.environ.copy()
    if worktree and os.path.isdir(worktree):
        environment['GIT_ALTERNATE_OBJECT_DIRECTORIES'] = command(
            'git', '-C', worktree, 'rev-parse', '--path-format=absolute', '--git-path', 'objects',
            reason='the task worktree objects could not be read')

    def git(*args, reason):
        return command('git', '-C', scratch, *args, env=environment, reason=reason)

    def ensure(sha):
        try:
            git('cat-file', '-e', sha + '^{commit}', reason='')
        except Unavailable:
            if offline:
                raise Unavailable(f'commit {sha} is not local at the final read')
            # Missing objects are fetched into this private scratch repository only;
            # the credential helper uses the existing gh grant without printing it.
            git('-c', 'credential.helper=', '-c', 'credential.helper=!gh auth git-credential',
                'fetch', '--no-tags', '--no-write-fetch-head',
                f'https://github.com/{repo}.git', sha, reason=f'commit {sha} could not be fetched')

    verified = os.path.join(scratch, f'fm-verified-{head}')
    cached = None
    if os.path.isfile(verified):
        with open(verified, encoding='ascii') as handle:
            cached = handle.read().split()
    if offline:
        if not cached:
            raise Unavailable(f'no tested-tree records were verified for head {head} before the final read')
        tested = cached[0]
    else:
        runs = check_runs(repo, head)
        ids = sorted(str(run['id']) for run in runs)
        if cached and cached[1:] == ids:
            tested = cached[0]
        else:
            if cached:
                os.remove(verified)
            records = read_records(repo, head, runs)
            for sha in {head, *(base for _, base in records)}:
                ensure(sha)
            for tree, base in records:
                if git('merge-tree', '--write-tree', base, head,
                       reason=f'base {base} and head {head} do not merge') != tree:
                    raise Unavailable(f'the tested-tree record for base {base} does not match its merge')
            trees = {tree for tree, _ in records}
            tested = trees.pop() if len(trees) == 1 else 'none'
            with open(verified, 'w', encoding='ascii') as handle:
                handle.write(' '.join([tested, *ids]) + '\n')
    ensure(tip)
    landing = git('merge-tree', '--write-tree', tip, head,
                  reason=f'tip {tip} and head {head} do not merge')
    if landing != tested:
        return 2
    print(landing)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(verify(*sys.argv[1:]))
    except Unavailable as error:
        print(f'note: tested-tree records unavailable ({error}); the ancestry rule applies', file=sys.stderr)
        sys.exit(1)
    except (KeyError, IndexError, TypeError, ValueError, OSError):
        print('note: tested-tree records unavailable (a record or argument was malformed); the ancestry rule applies',
              file=sys.stderr)
        sys.exit(1)
