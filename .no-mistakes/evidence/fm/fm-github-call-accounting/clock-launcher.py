"""Real owner `run`, real ps, wall clock scaled. Only time.time is scaled: cadences stay real.
argv: owner_path scale real_seconds"""
import runpy,sys,time
owner_path,scale,duration=sys.argv[1],float(sys.argv[2]),float(sys.argv[3])
real=time.time; t0=real()
BASE=1794000000.0
time.time=lambda:BASE+(real()-t0)*scale
owner=runpy.run_path(owner_path)
owner["run"](owner["private_root"](),duration)
