# Start the --sandbox-only suite, send a signal the moment a lease state file
# appears in the private pool, then report what remains in the lab.
import os, signal, subprocess, sys, time, glob
wt, lab, path, signame = sys.argv[1:5]
sig = getattr(signal, signame)
env = {"PATH": path, "HOME": f"{lab}/home", "TMPDIR": f"{lab}/tmp-link"}
p = subprocess.Popen(["bash", "tests/fm-backend-herdr-presentation-e2e.test.sh", "--sandbox-only"],
                     cwd=wt, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
seen = None
deadline = time.time() + 60
while time.time() < deadline and p.poll() is None:
    hits = glob.glob(f"{lab}/tmp-real/fm-herdr-presentation.*/treehouse.*/.treehouse/*/treehouse-state.json") \
         + glob.glob(f"{lab}/tmp-real/fm-herdr-presentation.*/treehouse.*/.treehouse/*/*/treehouse-state.json")
    if hits:
        seen = hits[0]
        os.kill(p.pid, sig)   # signal only the suite's bash, like a Ctrl-C / kill to the runner
        break
    time.sleep(0.005)
out, _ = p.communicate(timeout=120)
print(out.decode(errors="replace"))
print(f"signal={signame} sent_after_lease_seen={seen is not None} lease_file={seen}")
print(f"exit={p.returncode}")
left = sorted(glob.glob(f"{lab}/tmp-real/fm-herdr-presentation.*"))
print(f"leftover_fixture_roots={left}")
