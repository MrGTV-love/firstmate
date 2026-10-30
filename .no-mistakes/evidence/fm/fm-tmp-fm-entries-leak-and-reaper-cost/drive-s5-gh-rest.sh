#!/usr/bin/env bash
# Live drive: bin/fm-gh-rest.sh get against the real GitHub API (public read
# endpoints only) with the machine's gh, a sandbox state dir and an empty TMPDIR.
set -u
WT=$1; SB=$(mktemp -d /tmp/fmnm-s5.XXXXXX); export TMPDIR=$SB/t FM_STATE_OVERRIDE=$SB/state; mkdir -p "$TMPDIR" "$FM_STATE_OVERRIDE"
count() { printf 'entries in TMPDIR: %s  [%s]\n' "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "$(cd "$TMPDIR" && find . -mindepth 1 | tr '\n' ' ')"; }
echo "--- normal read: get repos/cli/cli"; "$WT/bin/fm-gh-rest.sh" get repos/cli/cli | jq -r '"full_name=\(.full_name)"'; echo "rc=${PIPESTATUS[0]}"; count
echo "--- forge error: get repos/cli/no-such-repo-fmnm-zz"; "$WT/bin/fm-gh-rest.sh" get repos/cli/no-such-repo-fmnm-zz >/dev/null 2>"$SB/err"; echo "rc=$? stderr: $(head -c 120 "$SB/err")"; count
echo "--- a KILLed owner's entry, then a real read"
bash -c ". $WT/bin/fm-scratch-lib.sh; fm_scratch_new d fm-gh-rest; kill -KILL \$\$"; count
"$WT/bin/fm-gh-rest.sh" get repos/cli/cli >/dev/null; echo "rc=$?"; count
echo "--- TERM while a paginated read runs"
"$WT/bin/fm-gh-rest.sh" get repos/cli/cli/releases?per_page=1 --paginate >/dev/null 2>&1 & p=$!; sleep 1.5; kill -TERM $p 2>/dev/null; wait $p; echo "rc=$?"; count
rm -rf "$SB"
