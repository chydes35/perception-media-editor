import sys, struct
path, w, h = sys.argv[1], 3840, 2160
d = open(path, 'rb').read()
Y = memoryview(d)[:w*h*2].cast('H'); U = memoryview(d)[w*h*2:w*h*3].cast('H'); V = memoryview(d)[w*h*3:w*h*4].cast('H')
out = []
for gy in range(8):
    for gx in range(8):
        x = ((gx*2+1)*w//16) & ~1; y = (gy*2+1)*h//16
        out.append(f"{Y[y*w+x]},{U[y*(w//2)+x//2]},{V[y*(w//2)+x//2]}")
print(" ".join(out))
