import sys, re
S = sys.argv[1]
def probe(fmt):
    d = {}
    for line in open(f"{S}/ref/probe_{fmt}.txt"):
        m = re.match(r"\s+sample\[(\d+)\]: (.*)", line)
        if m: d[int(m.group(1))] = [tuple(map(int, t.split(","))) for t in m.group(2).split()]
    return d
import subprocess
ref = {n: [tuple(map(int, t.split(","))) for t in subprocess.check_output(["python3","-I",f"{S}/probe/readraw.py",f"{S}/ref/f{n}.yuv"]).decode().split()] for n in (0,36,71)}
for fmt in ("xf22","x422"):
    p = probe(fmt)
    for n in (0,36,71):
        dy = [a[0]-b[0] for a,b in zip(p[n], ref[n])]; dc = [a[1]-b[1] for a,b in zip(p[n], ref[n])] + [a[2]-b[2] for a,b in zip(p[n], ref[n])]
        print(fmt, n, "Y diff min/max", min(dy), max(dy), "C diff min/max", min(dc), max(dc), "Y range", min(a[0] for a in p[n]), max(a[0] for a in p[n]))
