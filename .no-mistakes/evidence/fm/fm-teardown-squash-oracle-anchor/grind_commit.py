#!/usr/bin/env python3
# Rewrite HEAD's committer timestamp until the short commit ID ends in "add".
# Usage: grind_commit.py <real-git> <repo>
import hashlib, re, subprocess, sys
git, repo = sys.argv[1], sys.argv[2]
raw = subprocess.check_output([git, "-C", repo, "cat-file", "commit", "HEAD"])
m = re.search(rb"^(committer .*> )(\d+)( [+-]\d{4})$", raw, re.M)
base = int(m.group(2))
for delta in range(1, 2_000_000):
    body = raw[:m.start(2)] + str(base + delta).encode() + raw[m.end(2):]
    sha = hashlib.sha1(b"commit %d\0" % len(body) + body).hexdigest()
    if sha[4:7] == "add":
        new = subprocess.run([git, "-C", repo, "hash-object", "-t", "commit", "-w", "--stdin"],
                             input=body, capture_output=True, check=True).stdout.decode().strip()
        assert new == sha, (new, sha)
        subprocess.check_call([git, "-C", repo, "reset", "-q", "--soft", new])
        print(f"grind: steered 'add b' to {sha[:7]} after {delta} tries", file=sys.stderr)
        sys.exit(0)
sys.exit("grind: no match")
