# Test driver used from /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4EXCFFXV5ZVRXQ95RXK339W/.validation; not a product stub.
import ast, pathlib
p=pathlib.Path(__file__).with_name('live.py')
tree=ast.parse(p.read_text())
tree.body=tree.body[:next(i for i,node in enumerate(tree.body) if isinstance(node,ast.Try))]
exec(compile(tree,str(p),'exec'))
LAB=ROOT/'.validation/runtime-isolate'
results=[]; screens=[]
try:
    LAB.mkdir()
    for name,dirname in [('ampersand-only','R&D only'),('brackets-only','square [home]'),('braces-only','brace {x}'),('apostrophe-only',"quote it's")]:
        home=LAB/dirname; ancestor(home)
        nested=home/'projects/proj/.claude/worktrees/task'; git_init(nested)
        launch(name,nested,excludes(nested),'composer')
    # A direct consumer comparison on the same bracketed home distinguishes
    # ineffective production glob syntax from trust or credential setup.
    nested=LAB/'square [home]/projects/proj/.claude/worktrees/task'
    fixed=excludes(nested)
    fixed['claudeMdExcludes']=[x.replace(r'\[','[[]').replace(r'\]','[]]') for x in fixed['claudeMdExcludes']]
    launch('brackets-character-class-control',nested,fixed,'composer')
    home=LAB/'normal'; ancestor(home)
    nested=home/'projects/proj/.claude/worktrees/task'; git_init(nested)
    launch('raw-normal-none',nested,excludes(nested),'composer',raw=[])
    launch('raw-normal-inline',nested,excludes(nested),'composer',raw=['--settings='+json.dumps({'feedbackDrafts':'off','claudeMdExcludes':['project/**']})])
    settings=LAB/'caller.json'; settings.write_text(json.dumps({'feedbackDrafts':'off','claudeMdExcludes':['project/**']}))
    launch('raw-normal-file',nested,excludes(nested),'composer',raw=['--settings',str(settings)])
finally:
    tmux('kill-server')
    (EVIDENCE/'exclusion-consumer-isolation.json').write_text(json.dumps(results,indent=2))
    (EVIDENCE/'exclusion-consumer-isolation.html').write_text('<!doctype html><meta charset="utf-8"><title>Exclusion consumer boundary</title><style>body{background:#121212;color:#eee;font:15px monospace;margin:24px}pre{background:#191919;padding:20px;overflow:auto}</style>'+''.join('<h2>'+html.escape(n)+'</h2><pre>'+html.escape(s)+'</pre>' for n,s in screens))
    shutil.rmtree(LAB,ignore_errors=True)
