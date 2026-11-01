import os
import subprocess
WRITER = os.path.join("/synthetic", "fm-guard-event.sh")

def record(guard, decision):
    subprocess.run([WRITER, guard, decision])

# 3.10+ match syntax; EXPECT NO SITE for M01-M03, SITE for M04
def m01_match_capture(other, denied):
    match other:
        case [record, *_]:
            pass
    names = [record for record in other]
    return [record("M01", "deny") for g in denied]

def m02_match_rest(other, denied):
    match {}:
        case {**record}:
            pass
    names = [record for record in other]
    return [record("M02", "deny") for g in denied]

def m03_match_star(other, denied):
    match [1]:
        case [*record]:
            pass
    names = [record for record in other]
    return [record("M03", "deny") for g in denied]

def m04_match_unrelated(other, denied):
    match other:
        case [first, *_]:
            pass
    names = [record for record in other]
    return [record("M04", "deny") for g in denied]
