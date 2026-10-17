"""Generates the OpenColorIO Metal shaders the video compositor uses for V-Log (plan Task 9).

OCIO is not linked into the app. This script asks PyOpenColorIO for Metal (MSL 2.0) shader text
and lookup tables, and writes them as Swift constants, plus CPU golden data for the tests.

Run it by hand after changing this script or the pinned OCIO version, in a throwaway venv:

    python3 -m venv "$TMPDIR/ocio-venv"
    "$TMPDIR/ocio-venv/bin/python" -I -m pip install --require-hashes -r scripts/ocio/requirements.txt
    "$TMPDIR/ocio-venv/bin/python" -I scripts/ocio/generate-shaders.py

Outputs (paths relative to the repository root):
    Sources/PerceptionEditor/OCIOGeneratedShaders.swift   shader text, tables, versions, script hash
    Tests/Fixtures/ocio-golden.json                        seeded inputs and OCIO CPU outputs

For real gate G4 the tests call it with
    --reference-frames IN.json OUT.json
where IN.json is {"inputs": [[r, g, b], ...]} of decoded V-Log code values (code / 1023). OUT.json
gets {"linear": [...], "display": [...]}: transform 1, and transform 2 applied to transform 1.
"""

import argparse
import hashlib
import json
import random
import sys
from pathlib import Path

import numpy as np
import PyOpenColorIO as ocio

ROOT = Path(__file__).resolve().parents[2]
SWIFT_OUTPUT = ROOT / "Sources/PerceptionEditor/OCIOGeneratedShaders.swift"
GOLDEN_OUTPUT = ROOT / "Tests/Fixtures/ocio-golden.json"
CONFIG_URI = "ocio://studio-config-latest"
GOLDEN_COUNT = 4096
SEED = 20261016

# The fused kernel (input then output transform, no half-float step between) is checked against this.
COMPOSED_NAME = "vlog_vgamut_to_rec1886_aces20"

# The Swift name, the OCIO name (function name and resource prefix), and how to build the transform.
TRANSFORMS = [
    (
        "vLogVGamutToLinearRec709",
        "vlog_vgamut_to_lin_rec709",
        lambda: ocio.GroupTransform([
            ocio.BuiltinTransform("PANASONIC_VLOG-VGAMUT_to_ACES2065-1"),
            ocio.ColorSpaceTransform(src="ACES2065-1", dst="Linear Rec.709 (sRGB)"),
        ]),
    ),
    (
        "linearRec709ToRec1886ACES20",
        "lin_rec709_to_rec1886_aces20",
        lambda: ocio.DisplayViewTransform(
            src="Linear Rec.709 (sRGB)",
            display="Rec.1886 Rec.709 - Display",
            view="ACES 2.0 - SDR 100 nits (Rec.709)",
        ),
    ),
]


def script_hash():
    return hashlib.sha256(Path(__file__).read_bytes()).hexdigest()


def processors(config):
    return {ocio_name: config.getProcessor(build()) for _, ocio_name, build in TRANSFORMS}


def shader(processor, ocio_name):
    desc = ocio.GpuShaderDesc.CreateShaderDesc(
        language=ocio.GpuLanguage.GPU_LANGUAGE_MSL_2_0,
        functionName="ocio_" + ocio_name,
        resourcePrefix=ocio_name + "_",
    )
    processor.getDefaultGPUProcessor().extractGpuShaderInfo(desc)
    if list(desc.get3DTextures()):
        sys.exit(f"{ocio_name}: 3D textures are not supported by the compositor wrapper")
    if list(desc.getUniforms()):
        sys.exit(f"{ocio_name}: dynamic uniforms are not supported by the compositor wrapper")
    tables = []
    for texture in desc.getTextures():
        if texture.height != 1:
            sys.exit(f"{ocio_name}: {texture.textureName} is a 2D texture; only 1D tables are supported")
        channels = 1 if texture.channel == ocio.GpuShaderDesc.TEXTURE_RED_CHANNEL else 3
        values = [float(v) for v in np.asarray(texture.getValues(), dtype=np.float32).ravel()]
        if len(values) != texture.width * channels:
            sys.exit(f"{ocio_name}: {texture.textureName} has {len(values)} values, expected {texture.width * channels}")
        tables.append({
            "name": texture.textureName,
            "width": texture.width,
            "channels": channels,
            "interpolation": "linear" if texture.interpolation == ocio.INTERP_LINEAR else "nearest",
            "values": values,
        })
    return desc.getShaderText(), tables


def half(values):
    """Rounds to half float, as the compositor's working textures store them."""
    return [float(v) for v in np.asarray(values, dtype=np.float16)]


def apply(processor, inputs):
    # The default CPU processor uses fast pow/exp approximations (about 1e-4 relative); the golden
    # data should be OCIO's exact math.
    cpu = processor.getOptimizedCPUProcessor(ocio.OPTIMIZATION_LOSSLESS)
    return [[float(np.float32(v)) for v in cpu.applyRGB(list(rgb))] for rgb in inputs]


def golden_inputs(rng, first_processor):
    """Inputs that are exact in half float, so the GPU sees exactly what the CPU saw."""
    specials = [[0.0] * 3, [0.125] * 3, [433 / 1023] * 3, [0.5] * 3, [1.0] * 3]
    codes = [half(rgb) for rgb in specials]
    while len(codes) < GOLDEN_COUNT:
        codes.append(half([rng.uniform(-0.05, 1.1) for _ in range(3)]))
    # Transform 2 sees transform 1's output (half of the set) and plain scene-linear values.
    linear = [half(rgb) for rgb in apply(first_processor, codes[: GOLDEN_COUNT // 2])]
    while len(linear) < GOLDEN_COUNT:
        linear.append(half([rng.uniform(-0.05, 1.5) for _ in range(3)]))
    return codes, linear


def number(value):
    return format(value, ".9g")


def swift_floats(values, indent):
    lines = []
    for start in range(0, len(values), 8):
        lines.append(indent + ", ".join(number(v) for v in values[start : start + 8]) + ",")
    return "\n".join(lines)


def write_swift(version, config_name, shaders):
    out = [
        "// Generated by scripts/ocio/generate-shaders.py. Do not edit; run the script instead.",
        f"// OpenColorIO {version} (BSD-3-Clause, see Resources/ThirdPartyNotices/OpenColorIO-BSD-3.txt),",
        f"// config {config_name}.",
        "",
        "enum OCIOGeneratedShaders {",
        f'    static let ocioVersion = "{version}"',
        f'    static let configName = "{config_name}"',
        "    /// SHA-256 of the generator script that wrote this file. A test compares it with the script.",
        f'    static let scriptSHA256 = "{script_hash()}"',
        "",
    ]
    for swift_name, ocio_name, _ in TRANSFORMS:
        text, tables = shaders[ocio_name]
        out.append(f"    static let {swift_name} = OCIOShaderTransform(")
        out.append(f'        name: "{ocio_name}",')
        out.append(f'        functionName: "ocio_{ocio_name}",')
        if tables:
            out.append("        tables: [")
            for table in tables:
                out.append("            OCIOLookupTable(")
                out.append(f'                name: "{table["name"]}", width: {table["width"]}, channels: {table["channels"]},')
                out.append(f'                interpolation: .{table["interpolation"]}, values: [')
                out.append(swift_floats(table["values"], "                    "))
                out.append("                ]),")
            out.append("        ],")
        else:
            out.append("        tables: [],")
        out.append('        source: #"""')
        out.extend("        " + line if line.strip() else "" for line in text.splitlines())
        out.append('        """#')
        out.append("    )")
        out.append("")
    out.append("}")
    SWIFT_OUTPUT.write_text("\n".join(out) + "\n")


def write_golden(version, config_name, procs):
    rng = random.Random(SEED)
    first, second = (procs[name] for _, name, _ in TRANSFORMS)
    codes, linear = golden_inputs(rng, first)
    data = {
        "ocioVersion": version,
        "config": config_name,
        "seed": SEED,
        "transforms": {
            TRANSFORMS[0][1]: {"inputs": codes, "outputs": apply(first, codes)},
            TRANSFORMS[1][1]: {"inputs": linear, "outputs": apply(second, linear)},
            COMPOSED_NAME: {"inputs": codes, "outputs": apply(second, apply(first, codes))},
        },
    }
    GOLDEN_OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    # One pixel per line keeps diffs readable.
    lines = ["{"]
    for key in ("ocioVersion", "config", "seed"):
        lines.append(f"  {json.dumps(key)}: {json.dumps(data[key])},")
    lines.append('  "transforms": {')
    names = list(data["transforms"])
    for t_index, name in enumerate(names):
        lines.append(f"    {json.dumps(name)}: {{")
        for k_index, key in enumerate(("inputs", "outputs")):
            rows = data["transforms"][name][key]
            lines.append(f'      "{key}": [')
            lines.extend(
                "        [" + ", ".join(number(v) for v in rgb) + "]" + ("," if i < len(rows) - 1 else "")
                for i, rgb in enumerate(rows)
            )
            lines.append("      ]" + ("," if k_index == 0 else ""))
        lines.append("    }" + ("," if t_index < len(names) - 1 else ""))
    lines.append("  }")
    lines.append("}")
    GOLDEN_OUTPUT.write_text("\n".join(lines) + "\n")


def reference_frames(procs, input_path, output_path):
    inputs = json.loads(Path(input_path).read_text())["inputs"]
    first, second = (procs[name] for _, name, _ in TRANSFORMS)
    linear = apply(first, inputs)
    display = apply(second, linear)
    Path(output_path).write_text(json.dumps({"linear": linear, "display": display}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reference-frames", nargs=2, metavar=("IN", "OUT"))
    args = parser.parse_args()

    config = ocio.Config.CreateFromFile(CONFIG_URI)
    procs = processors(config)
    if args.reference_frames:
        reference_frames(procs, *args.reference_frames)
        return
    version = ocio.__version__
    config_name = config.getName()
    shaders = {name: shader(procs[name], name) for _, name, _ in TRANSFORMS}
    write_swift(version, config_name, shaders)
    write_golden(version, config_name, procs)
    print(f"OCIO {version}, {config_name}: wrote {SWIFT_OUTPUT.relative_to(ROOT)} and {GOLDEN_OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
