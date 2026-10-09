# Test driver used from /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4EXCFFXV5ZVRXQ95RXK339W/.validation; not a product stub.
import ast, pathlib
p=pathlib.Path(__file__).with_name('live.py')
tree=ast.parse(p.read_text())
tree.body=tree.body[:next(i for i,node in enumerate(tree.body) if isinstance(node,ast.Try))]
exec(compile(tree,str(p),'exec'))
LAB=ROOT/'.validation/runtime-symlink'
results=[]; screens=[]
try:
    LAB.mkdir()
    home=LAB/'home'; ancestor(home)
    nested=home/'projects/proj/.claude/worktrees/task'; git_init(nested)
    alias=LAB/'task-alias'; alias.symlink_to(nested,target_is_directory=True)
    launch('symlink-ancestor-fixed-redrive',alias,excludes(alias),'composer')
finally:
    tmux('kill-server')
    (EVIDENCE/'symlink-live-results.json').write_text(json.dumps(results,indent=2))
    (EVIDENCE/'symlink-redrive-surface.html').write_text('<!doctype html><meta charset="utf-8"><title>Symlink launch after canonical trust registration</title><pre>'+html.escape(screens[0][1] if screens else '')+'</pre>')
    shutil.rmtree(LAB,ignore_errors=True)
if any(not x['passed'] for x in results): raise SystemExit(1)
