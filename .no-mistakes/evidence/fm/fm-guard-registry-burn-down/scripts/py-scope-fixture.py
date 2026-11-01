import subprocess

def record(guard, decision):
    subprocess.run(['fm-guard-event.sh', guard, decision])

def nested_inner_binding():
    f = lambda: (record('N1-outer-deny-beside-nested-binding', 'deny'), (lambda: (record := None))); f()

def nested_outer_shadow():
    f = lambda record: (record('N2-outer-param-shadow', 'deny'), (lambda: (record := None))); f(print)

def nested_default_walrus():
    f = lambda: (record('N3-walrus-in-nested-default-binds-outer', 'deny'), (lambda x=(record := None): x)); f()

def nested_comprehension_walrus():
    f = lambda: (record('N4-walrus-in-comprehension-binds-outer', 'deny'), [(record := y) for y in ()]); f()

def siblings(denied, other):
    a, b = [record(g, 'deny') for g in denied], [x for x in other]
    c = list(record(g, 'deny') for g in denied), list(x for x in other)
    d = (lambda: record('S3-lambda-sibling', 'deny')), (lambda: 0)
    e = {record(g, 'deny') for g in denied}, {x for x in other}
    h = {g: record(g, 'deny') for g in denied}, {x: x for x in other}

def sibling_shadowed(denied):
    a, b = [record('S6-comp-target-shadow', 'deny') for record in denied], [x for x in denied]
    d = (lambda record: record('S7-lambda-param-shadow', 'deny')), (lambda: 0)

def plain():
    record('P1-plain', 'deny')
    record('P2-allow', 'allow')
