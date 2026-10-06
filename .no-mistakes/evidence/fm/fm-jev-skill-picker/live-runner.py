#!/usr/bin/env python3
import sys, subprocess, os, pathlib, json
args=sys.argv[1:]
data=sys.stdin.buffer.read()
e=pathlib.Path(os.environ["LIVE_WIRE_DIR"]); e.mkdir(parents=True,exist_ok=True)
existing=list(e.glob("request-*.json")); n=len(existing)+1
(e/f"request-{n}.json").write_bytes(data)
p=subprocess.run(["/usr/bin/curl"]+args,input=data,pass_fds=(3,),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if "-o" in args:
    f=pathlib.Path(args[args.index("-o")+1])
    if f.exists(): (e/f"response-{n}.json").write_bytes(f.read_bytes())
(e/f"transport-{n}.json").write_text(json.dumps({"returncode":p.returncode,"http_and_time":p.stdout.decode()}))
sys.stdout.buffer.write(p.stdout); sys.stderr.buffer.write(p.stderr)
sys.exit(p.returncode)
