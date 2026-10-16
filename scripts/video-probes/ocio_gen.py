import sys, json, PyOpenColorIO as o
out = sys.argv[1]
c = o.Config.CreateFromFile("ocio://studio-config-latest")
jobs = {
  "vlog_to_linrec709": o.ColorSpaceTransform(src="V-Log V-Gamut", dst="Linear Rec.709 (sRGB)"),
  "linrec709_to_rec1886_aces20": o.DisplayViewTransform(src="Linear Rec.709 (sRGB)", display="Rec.1886 Rec.709 - Display", view="ACES 2.0 - SDR 100 nits (Rec.709)"),
  "builtin_vlog_to_ap0": o.BuiltinTransform("PANASONIC_VLOG-VGAMUT_to_ACES2065-1"),
}
meta = {}
for name, t in jobs.items():
    proc = c.getProcessor(t)
    gpu = proc.getDefaultGPUProcessor()
    desc = o.GpuShaderDesc.CreateShaderDesc(language=o.GpuLanguage.GPU_LANGUAGE_MSL_2_0, functionName="ocio_"+name, resourcePrefix=name+"_")
    gpu.extractGpuShaderInfo(desc)
    open(f"{out}/{name}.metal","w").write(desc.getShaderText())
    tex = [(t.textureName, t.width, t.height) for t in desc.getTextures()]
    tex3 = [(t.textureName, t.edgeLen) for t in desc.get3DTextures()]
    cpu = proc.getDefaultCPUProcessor()
    probes = [[0.0,0.0,0.0],[0.125,0.125,0.125],[433/1023]*3,[0.5,0.5,0.5],[0.6,0.4,0.3],[0.9,0.9,0.9]]
    meta[name] = {"textures": tex, "textures3d": tex3, "uniforms": len(desc.getUniforms()), "cpu": {str(p): cpu.applyRGB(p) for p in probes}}
json.dump(meta, open(f"{out}/meta.json","w"), indent=1)
print(json.dumps(meta, indent=1))
# Texture payloads and a denser CPU golden set for the GPU comparison.
import struct, random
random.seed(7)
inputs = [[random.random()*1.1 for _ in range(3)] for _ in range(4096)]
for name, t in jobs.items():
    proc = c.getProcessor(t); desc = o.GpuShaderDesc.CreateShaderDesc(language=o.GpuLanguage.GPU_LANGUAGE_MSL_2_0, functionName="ocio_"+name, resourcePrefix=name+"_")
    proc.getDefaultGPUProcessor().extractGpuShaderInfo(desc)
    for tx in desc.getTextures():
        vals = [float(v) for v in tx.getValues().ravel()]
        open(f"{out}/{tx.textureName}.f32","wb").write(struct.pack(f"{len(vals)}f", *vals))
        print(tx.textureName, tx.width, tx.height, tx.channel, len(vals))
    cpu = proc.getDefaultCPUProcessor()
    open(f"{out}/{name}.golden.f32","wb").write(b"".join(struct.pack("6f", *i, *cpu.applyRGB(i)) for i in inputs))
