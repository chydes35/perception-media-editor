import sys
S=sys.argv[1]; w,h=3840,2160
def load(p):
    d=open(p,'rb').read(); return memoryview(d)[:w*h*2].cast('H')
o=load(f"{S}/ref/f0.yuv")
import statistics
for f in ("x422","xf22"):
    p=load(f"{S}/ref/proxy_{f}.yuv")
    # sample a sparse grid of 20k pixels, compare stored luma vs original luma
    diffs=[]; pairs=[]
    for y in range(4,h-4,27):
        for x in range(4,w-4,29):
            diffs.append(p[y*w+x]-o[y*w+x]); pairs.append((o[y*w+x],p[y*w+x]))
    # fit p = a*o + b
    n=len(pairs); mx=sum(a for a,_ in pairs)/n; my=sum(b for _,b in pairs)/n
    a=sum((u-mx)*(v-my) for u,v in pairs)/sum((u-mx)**2 for u,_ in pairs); b=my-a*mx
    print(f, "stored-orig luma: mean %.2f median %d min %d max %d | fit stored = %.4f*orig + %.1f | stored range %d..%d"%(statistics.mean(diffs),statistics.median(diffs),min(diffs),max(diffs),a,b,min(v for _,v in pairs),max(v for _,v in pairs)))
print("expected for a correct full->video conversion: stored = 0.8563*orig + 64")
