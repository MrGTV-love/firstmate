import os, json, pathlib, subprocess, time
out=pathlib.Path(os.environ["FM_LIVE_EVIDENCE"])
label=os.environ["FM_LIVE_LABEL"]
root=os.environ["FM_LIVE_ROOT"]
load_start=os.getloadavg()
t0=time.monotonic()
r=subprocess.run([root+"/bin/fm-session-start.sh","--source","startup"],cwd=root,capture_output=True,text=True)
elapsed=time.monotonic()-t0
load_end=os.getloadavg()
state=pathlib.Path(os.environ["FM_HOME"])/"state"
def record(name):
    p=state/name
    return p.read_text() if p.exists() else None
lock=record(".lock")
complete=record(".session-start-complete")
identity=subprocess.run(["ps","-p",(lock or "0").strip(),"-o","pid=,ppid=,comm=,args="],capture_output=True,text=True).stdout
result={"elapsed_seconds":elapsed,"limit_seconds":20,"load_start":load_start,"load_end":load_end,"exit_code":r.returncode,"lock":lock,"completion":complete,"live_lock_process":identity,"cold_status_logs":25,"keyed_resolutions_per_log":60,"digest_complete":"The digest above is complete for this session start." in r.stdout,"truncated":any(line.startswith("●  STARTUP TRUNCATED") for line in r.stdout.splitlines()),"status_cursor_count":len(list(state.glob(".*.open-decisions-cursor")))}
(out/(label+"-digest.txt")).write_text(r.stdout+"\nSTDERR:\n"+r.stderr)
(out/(label+"-measurement.json")).write_text(json.dumps(result,indent=2)+"\n")
print(r.stdout,end="")
print(r.stderr,end="",file=__import__("sys").stderr)
