import subprocess, sys, time
burn = 'import time\nwhile time.process_time() < 0.05:\n    pass\n'
for _ in range(int(sys.argv[1])):
    subprocess.run([sys.executable, '-c', burn])
    time.sleep(0.45)
sys.exit(7)
