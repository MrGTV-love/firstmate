# Test driver used from /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4EXCFFXV5ZVRXQ95RXK339W/.validation; not a product stub.
import ast, pathlib
p=pathlib.Path(__file__).with_name('live.py')
tree=ast.parse(p.read_text())
tree.body=tree.body[:next(i for i,node in enumerate(tree.body) if isinstance(node,ast.Try))]
exec(compile(tree,str(p),'exec'))
LAB=ROOT/'.validation/runtime-topology'
results=[]; screens=[]
try:
    LAB.mkdir()
    outer=LAB/'outer'; ancestor(outer)
    inner=outer/'secondmate'; ancestor(inner)
    (inner/'.fm-secondmate-home').write_text('disposable-secondmate\n')
    (inner/'bin/fm-spawn.sh').unlink()
    nested=inner/'projects/proj/.claude/worktrees/task'; git_init(nested)
    launch('secondmate-reproduction',nested,excludes(LAB),str(inner/'AGENTS.md'))
    launch('multiple-ancestor-fixed',nested,excludes(nested),'composer')
    alias=LAB/'task-alias'; alias.symlink_to(nested,target_is_directory=True)
    launch('symlink-ancestor-fixed',alias,excludes(alias),'composer')
finally:
    tmux('kill-server')
    (EVIDENCE/'topology-live-results.json').write_text(json.dumps(results,indent=2))
    (EVIDENCE/'nested-topology-surfaces.html').write_text('<!doctype html><meta charset="utf-8"><title>Nested secondmate and symlink topology</title><style>body{background:#121212;color:#eee;font:15px monospace;margin:24px}pre{background:#191919;padding:20px;overflow:auto}</style>'+''.join('<h2>'+html.escape(n)+'</h2><pre>'+html.escape(s)+'</pre>' for n,s in screens))
    shutil.rmtree(LAB,ignore_errors=True)
if any(not x['passed'] for x in results): raise SystemExit(1)
