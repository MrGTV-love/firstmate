import contextlib
import os
import subprocess
WRITER = os.path.join("/synthetic", "fm-guard-event.sh")

def record(guard, decision):
    subprocess.run([WRITER, guard, decision])

# ---- unshadowed: the deny call reaches the module wrapper. EXPECT SITE
def r01_sep_line(other, denied):
    names = [record for record in other]
    calls = [record("R01", "deny") for g in denied]

def r02_same_line(other, denied):
    a = [record for record in other], [record("R02", "deny") for g in denied]

def r03_set_after_list(other, denied):
    names = [record for record in other]
    calls = {record("R03", "deny") for g in denied}

def r04_dict_sibling(other, denied):
    names = {record: 1 for record in other}
    calls = {g: record("R04", "deny") for g in denied}

async def r05_async(other, denied):
    names = [record for record in other]
    return [record("R05", "deny") for g in denied]

def r06_nested_comp(other, denied):
    names = [record for record in other]
    return [[record("R06", "deny") for g in grp] for grp in [denied]]

class R07:
    def method(self, other, denied):
        names = [record for record in other]
        return [record("R07", "deny") for g in denied]

def r08_two_siblings(other, denied):
    a = [record for record in other]
    b = {record for record in other}
    return [record("R08", "deny") for g in denied]

def r09_lambda_holds_sibling(other, denied):
    f = lambda: [record for record in other]
    return [record("R09", "deny") for g in denied]

def r10_genexpr_sibling(other, denied):
    names = list(record for record in other)
    return [record("R10", "deny") for g in denied]

def r11_inner_sibling_in_outer(other, denied):
    names = [record for record in other]
    def inner():
        return [record("R11", "deny") for g in denied]
    return inner()

def r12_ifs_sibling(other, denied):
    names = [record for record in other if record]
    return [record("R12", "deny") for g in denied if g]

# ---- shadowed: the name is a real local or enclosing binding. EXPECT NO SITE
def n01_assign(other, denied):
    record = None
    names = [record for record in other]
    return [record("N01", "deny") for g in denied]

def n02_for_loop(other, denied):
    for record in other:
        pass
    names = [record for record in other]
    return [record("N02", "deny") for g in denied]

def n03_import_as(other, denied):
    import json as record
    names = [record for record in other]
    return [record("N03", "deny") for g in denied]

def n04_with_as(other, denied):
    with contextlib.nullcontext(1) as record:
        pass
    names = [record for record in other]
    return [record("N04", "deny") for g in denied]

def n05_except_as(other, denied):
    try:
        raise ValueError
    except ValueError as record:
        pass
    names = [record for record in other]
    return [record("N05", "deny") for g in denied]

def n06_nested_def(other, denied):
    def record(*a):
        return None
    names = [record for record in other]
    return [record("N06", "deny") for g in denied]

def n07_walrus_in_sibling_comp(other, denied):
    names = [(record := x) for x in other]
    return [record("N07", "deny") for g in denied]

def n08_walrus_in_genexpr(other, denied):
    names = list((record := x) for x in other)
    return [record("N08", "deny") for g in denied]

def n09_parameter(other, denied, record=None):
    names = [record for record in other]
    return [record("N09", "deny") for g in denied]

def n10_enclosing_assign(other, denied):
    record = None
    def inner():
        names = [record for record in other]
        return [record("N10", "deny") for g in denied]
    return inner()

def n11_annotation_only(other, denied):
    record: int
    names = [record for record in other]
    return [record("N11", "deny") for g in denied]

def n12_star_target(other, denied):
    first, *record = [1, 2]
    names = [record for record in other]
    return [record("N12", "deny") for g in denied]

def n13_kwonly_param(other, denied, *, record=None):
    names = [record for record in other]
    return [record("N13", "deny") for g in denied]

def n14_own_target(other, denied):
    names = [record for record in other]
    return [record("N14", "deny") for record in denied]

def n15_class_def(other, denied):
    class record:
        def __init__(self, *a):
            raise TypeError
    names = [record for record in other]
    return [record("N15", "deny") for g in denied]

def n16_walrus_in_own_if(other, denied):
    return [record("N16", "deny") for g in denied if (record := g)]
