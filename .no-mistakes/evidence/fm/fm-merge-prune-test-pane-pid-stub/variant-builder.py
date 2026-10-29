import sys,re
root,stub,lib,iso=sys.argv[1:5]
t=open(root+'/tests/fm-merge-prune.test.sh').read()
new_stub="test_pane_pid=$2; fm_mp_pane_pid() { printf %s \"$test_pane_pid\"; };"
old_stub="fm_mp_pane_pid() { printf %s \"$2\"; };"
assert t.count(new_stub)==1
if stub=='old': t=t.replace(new_stub,old_stub)
if iso=='1':
    s=t.index('scn_partial_process_table_proves_no_agent_gone() {')
    e=t.index('\n}\n',s)
    body=t[s:e]
    lines=body.split('\n')
    out=[];after=False
    for ln in lines:
        if 'partly read process table admitted' in ln or 'stopped on a partial process table' in ln or 'did not back off on the failed read' in ln: continue
        if after and ln.strip()=='make_world':
            out.append('  return 0'); break
        if 'took a partly read process table' in ln: after=True
        out.append(ln)
    t=t[:s]+'\n'.join(out)+t[e:]
open(root+'/tests/fm-merge-prune.test.sh','w').write(t)
if lib=='mut':
    l=open(root+'/bin/fm-merge-prune-lib.sh').read()
    o='  table=$(ps -axo pid=,ppid= 2>/dev/null) || return 1\n  [ -n "$table" ] || return 1\n  tree='
    n='  table=$(ps -axo pid=,ppid= 2>/dev/null) || true\n  tree='
    assert l.count(o)==1; l=l.replace(o,n)
    open(root+'/bin/fm-merge-prune-lib.sh','w').write(l)
