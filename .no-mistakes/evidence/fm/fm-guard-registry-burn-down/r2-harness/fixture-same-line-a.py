import os
import subprocess
WRITER = os.path.join("/synthetic", "fm-guard-event.sh")

def record(guard, decision):
    subprocess.run([WRITER, guard, decision])

# R2-1 same-line sibling scopes (round-2 review finding). S = expect site, N = expect none.
def s01_list_pair(other, denied):
    a, b = [record("S01", "deny") for g in denied], [y for y in other]

def s02_set_pair(other, denied):
    a, b = {record("S02", "deny") for g in denied}, {y for y in other}

def s03_dict_pair(other, denied):
    a, b = {g: record("S03", "deny") for g in denied}, {y: 1 for y in other}

def s04_genexpr_pair(other, denied):
    a, b = list(record("S04", "deny") for g in denied), list(y for y in other)

def s05_lambda_pair(other, denied):
    a, b = (lambda: record("S05", "deny")), (lambda: 0)
    a()

def s06_lambda_second(other, denied):
    a, b = (lambda: 0), (lambda: record("S06", "deny"))
    b()

def s07_mixed_first_shadows(other, denied):
    a, b = [record for record in other], [record("S07", "deny") for g in denied]

def n01_list_pair_shadowed(other, denied):
    a, b = [record("N01", "deny") for record in denied], [y for y in other]

def n02_genexpr_pair_shadowed(other, denied):
    a, b = list(record("N02", "deny") for record in denied), list(y for y in other)

def n03_lambda_pair_shadowed(other, denied):
    a, b = (lambda record: record("N03", "deny")), (lambda: 0)
    a(print)

def n04_walrus_lambda_pair(other, denied):
    a, b = (lambda: (record := print) and record("N04", "deny")), (lambda: 0)
    a()

# Round-1 test finding T1 fixture (s5b), one function per case.
def t01_sibling_comprehension_then_call(other, denied):
    names = [record for record in other]
    record("T01", "deny")

def t02_sibling_comprehension_then_comprehension(other, denied):
    names = [y for record in other for y in [record]]
    calls = [record("T02", "deny") for g in denied]

def t03_control_no_sibling(other, denied):
    record("T03", "deny")

def t04_control_generator_sibling(other, denied):
    names = list(y for record in other for y in [record])
    record("T04", "deny")
