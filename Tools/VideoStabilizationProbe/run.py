#!/usr/bin/env python3
"""Local fixture generation and sequential measurements; never writes to sources.

Requires Python/Pillow and external ffmpeg/ffprobe. No dependencies are added to the app.
Output directories must be new. Use separate processes for each native memory measurement.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random
import re
import subprocess
import time
from fractions import Fraction

REPO = Path(__file__).resolve().parents[2]
SCRATCH = REPO / ".build/video-stabilization-baseline"
PROBE = SCRATCH / "probe"
REFERENCE = SCRATCH / "vidstab-reference"


def save(path, data):
    path.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")


def command(args, log):
    with log.open("wb") as output:
        subprocess.run([str(a) for a in args], stdout=output, stderr=subprocess.STDOUT, check=True)


def sha(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def process_memory(log):
    text = log.read_text()
    result = {}
    for label, key in [("maximum resident set size", "peakRSSMiB"), ("(?:maximum|peak) memory footprint", "peakPhysicalFootprintMiB")]:
        match = re.search(r"(\d+)\s+" + label, text)
        result[key] = int(match.group(1)) / 1048576 if match else None
    return result


def telemetry():
    return {name: subprocess.run(args, text=True, capture_output=True).stdout.strip()
            for name, args in [("swap", ["sysctl", "vm.swapusage"]), ("thermal", ["pmset", "-g", "therm"])]}


def irregular_filter():
    # Set an explicit fine timebase before modifying timestamps. The source's
    # 1/24 timebase would truncate the intended sub-frame offset back to CFR.
    return "settb=expr=1/24000,setpts=N*1000+200*mod(N\\,2)"


def generate(root):
    from PIL import Image, ImageDraw
    directory = root / "fixtures"
    directory.mkdir()
    rng = random.Random(3515)
    texture = Image.new("RGB", (800, 520), (70, 80, 90))
    draw = ImageDraw.Draw(texture)
    for _ in range(2500):
        x, y = rng.randrange(800), rng.randrange(520)
        color = tuple(rng.randrange(20, 240) for _ in range(3))
        draw.rectangle((x, y, x + rng.randrange(2, 15), y + rng.randrange(2, 15)), fill=color)
    manifest = []
    for kind in ["static", "pan", "jitter", "rotation", "irregular", "low-feature", "cut"]:
        output = directory / (kind + ".mov")
        args = ["ffmpeg", "-v", "error", "-n", "-f", "rawvideo", "-pixel_format", "rgb24",
                "-video_size", "640x360", "-framerate", "24", "-i", "pipe:0", "-an"]
        if kind == "irregular":
            args += ["-vf", irregular_filter(), "-fps_mode", "vfr",
                     "-enc_time_base", "1:24000", "-video_track_timescale", "24000"]
        args += ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le",
                 "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", str(output)]
        truth = []
        with (directory / (kind + ".log")).open("wb") as log:
            process = subprocess.Popen(args, stdin=subprocess.PIPE, stderr=log)
            for i in range(120):
                t = i / 24
                x = 12 * t if kind == "pan" else 0
                y = 0
                angle = 0
                if kind in ["jitter", "irregular"]:
                    x = 8 * math.sin(2 * math.pi * 7 * t)
                    y = 5 * math.sin(2 * math.pi * 5 * t)
                if kind == "rotation":
                    angle = 0.025 * math.sin(2 * math.pi * 4 * t)
                frame = texture
                if kind == "low-feature":
                    frame = Image.new("RGB", (800, 520), (80, 80, 80))
                if kind == "cut" and i >= 60:
                    frame = texture.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                frame = frame.rotate(math.degrees(angle), Image.Resampling.BICUBIC,
                                     translate=(x, -y)).crop((80, 80, 720, 440))
                process.stdin.write(frame.tobytes())
                truth.append({"frame": i, "x": x, "y": y, "angle": angle})
            process.stdin.close()
            if process.wait() != 0:
                raise RuntimeError(f"Synthetic encoding failed: {output}")
        truth_path = directory / (kind + "-truth.json")
        save(truth_path, truth)
        manifest.append({"name": kind, "path": str(output), "duration": 5, "truth": str(truth_path)})
    save(root / "synthetic.json", manifest)


def probe(source, directory, mode, duration, render=True, edge=960):
    command(["/usr/bin/time", "-l", PROBE, source, directory, mode, 0, duration, edge,
             "render" if render else "analyze"], directory.parent / (directory.name + ".log"))
    report = json.loads((directory / "motion.json").read_text())
    if render:
        data = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=time_base:frame=pts", "-of", "json",
                          str(directory / "diagnostic.mov")], text=True))
        timebase = Fraction(data["streams"][0]["time_base"])
        encoded = [int(frame["pts"]) * timebase for frame in data["frames"]]
        source_pts = [Fraction(sample["value"], sample["timescale"]) for sample in report["samples"]]
        if encoded != [t-source_pts[0] for t in source_pts]:
            raise RuntimeError(f"Encoded timestamps differ from actual source PTS: {directory}")
        report["encodedTimestampsExact"] = True
    return report


def jitter(report):
    """RMS time-aware velocity change, px/s². Excludes rejected/cut triplets."""
    samples = report["samples"]
    squared = []
    for a, b, c in zip(samples, samples[1:], samples[2:]):
        if not all(s["valid"] for s in (a, b, c)) or len({s["segment"] for s in (a, b, c)}) != 1:
            continue
        ta, tb, tc = (s["value"] / s["timescale"] for s in (a, b, c))
        dt1, dt2 = tb-ta, tc-tb
        if min(dt1, dt2) <= 0:
            continue
        acceleration = [2 * ((c["path"][k]-b["path"][k])/dt2 - (b["path"][k]-a["path"][k])/dt1)/(dt1+dt2)
                        for k in ("x", "y")]
        squared.append(sum(x*x for x in acceleration))
    return math.sqrt(sum(squared)/len(squared)) if squared else None


def benchmark(root, manifest, reference=False):
    rows = json.loads((root / "results.json").read_text()) if (root / "results.json").exists() else []
    for fixture in manifest:
        name = fixture["name"]
        source = Path(fixture["path"])
        directory = root / name
        directory.mkdir()
        before = sha(source)
        before_telemetry = telemetry()
        decode = probe(source, directory / "baseline", "none", fixture["duration"])
        baseline = directory / "baseline/diagnostic.mov"
        measured_baseline = probe(baseline, directory / "baseline-measured", "translation", fixture["duration"], False)
        base_jitter = jitter(measured_baseline)
        row = {"name": name, "source": str(source), "duration": fixture["duration"],
               "sourceSHA256": before, "decode": {k: decode[k] for k in ["analysisSeconds", "peakSampledMemory", "width", "height"]},
               "baselineJitterPxPerSecondSquared": base_jitter, "methods": {}}
        row["decode"]["wholeProcessMemory"] = process_memory(directory / "baseline.log")
        for mode in ["translation", "homography"]:
            report = probe(baseline, directory / mode, mode, fixture["duration"])
            measured = probe(directory / mode / "diagnostic.mov", directory / (mode + "-measured"), "translation", fixture["duration"], False)
            residual = jitter(measured)
            summary = {k: report[k] for k in ["analysisSeconds", "renderSeconds", "initialMemory", "peakSampledMemory", "appliedStrength",
                                             "requiredZoom", "appliedZoom", "removedDimensionFraction", "rejected", "registrationErrors", "encodedTimestampsExact"]}
            summary.update({"frames": len(report["samples"]), "residualJitterPxPerSecondSquared": residual,
                            "jitterReduction": 1-residual/base_jitter if base_jitter and residual is not None else None,
                            "remeasureRejected": measured["rejected"]})
            summary["wholeProcessMemory"] = process_memory(directory / (mode + ".log"))
            if fixture.get("truth"):
                truth = json.loads(Path(fixture["truth"]).read_text())
                errors, angle_errors = [], []
                for i in range(1, min(len(truth), len(report["samples"]))):
                    a, b = report["samples"][i-1:i+1]
                    if a["segment"] != b["segment"] or not b["valid"]:
                        continue
                    errors.append(sum(((b["path"][k]-a["path"][k])-(truth[i][k]-truth[i-1][k]))**2 for k in ["x", "y"]))
                    angle_errors.append(((b["path"]["angle"]-a["path"]["angle"])-(truth[i]["angle"]-truth[i-1]["angle"]))**2)
                summary["motionDeltaRMSEPixels"] = math.sqrt(sum(errors)/len(errors)) if errors else None
                summary["rotationDeltaRMSEDegrees"] = math.degrees(math.sqrt(sum(angle_errors)/len(angle_errors))) if angle_errors else None
            row["methods"][mode] = summary
        if reference:
            width, height = decode["width"], decode["height"]
            raw = directory / "reference-input.yuv"
            command(["ffmpeg", "-v", "error", "-n", "-i", baseline, "-pix_fmt", "yuv420p", "-fps_mode", "passthrough",
                     "-f", "rawvideo", raw], directory / "reference-decode.log")
            command(["/usr/bin/time", "-l", REFERENCE, raw, directory / "reference-output.yuv", directory / "reference.json",
                     width, height, 12], directory / "reference.log")
            command(["ffmpeg", "-v", "error", "-n", "-f", "rawvideo", "-pixel_format", "yuv420p", "-video_size",
                     f"{width}x{height}", "-framerate", "24", "-i", directory / "reference-output.yuv", "-c:v", "libx264",
                     "-crf", "12", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                     directory / "reference.mov"], directory / "reference-encode.log")
            measured = probe(directory / "reference.mov", directory / "reference-measured", "translation", fixture["duration"], False)
            summary = json.loads((directory / "reference.json").read_text())
            summary["wholeProcessMemory"] = process_memory(directory / "reference.log")
            residual = jitter(measured)
            summary.update({"residualJitterPxPerSecondSquared": residual,
                            "jitterReduction": 1-residual/base_jitter if base_jitter and residual is not None else None,
                            "remeasureRejected": measured["rejected"],
                            "timingLimitation": "Raw reference remux is 24 fps, so irregular/VFR timing is not validated."})
            row["methods"]["vidstab"] = summary
        after = sha(source)
        row["sourceUnchanged"] = before == after
        row["systemBefore"] = before_telemetry
        row["systemAfter"] = telemetry()
        if before != after:
            raise RuntimeError("Original source hash changed")
        rows.append(row)
        save(root / "results.json", rows)
        print(f"Completed {name}: " + ", ".join(f"{k} jitter reduction={v.get('jitterReduction')}" for k,v in row["methods"].items()), flush=True)


def performance(root, source):
    directory = root / "performance"
    directory.mkdir()
    before = sha(source)
    rows = []
    for duration in [15, 30, 60, 90]:
        row = {"durationSeconds": duration, "systemBefore": telemetry()}
        for mode in ["none", "translation"]:
            name = f"{mode}-{duration}"
            report = probe(source, directory/name, mode, duration, False)
            row[mode] = {"frames": len(report["samples"]), "analysisSeconds": report["analysisSeconds"],
                         "sampledMemory": report["peakSampledMemory"], "rejected": report["rejected"],
                         "wholeProcessMemory": process_memory(directory/(name+".log"))}
        row["systemAfter"] = telemetry()
        rows.append(row)
        save(root/"performance.json", {"source": str(source), "sourceSHA256": before,
                                       "sourceUnchanged": None, "runs": rows})
        print(f"Performance {duration}s: decode {row['none']['analysisSeconds']:.3f}s, native analysis+decode {row['translation']['analysisSeconds']:.3f}s", flush=True)
    after = sha(source)
    save(root/"performance.json", {"source": str(source), "sourceSHA256": before,
                                   "sourceUnchanged": before == after, "runs": rows})
    if before != after:
        raise RuntimeError("Original source hash changed")


def comparison(root, case):
    from PIL import Image, ImageDraw
    if Path(case).name != case:
        raise ValueError("Comparison case must be a single directory name")
    directory = root/case
    overlay = directory/"comparison-labels.png"
    labels = Image.new("RGBA", (1280,720), (0,0,0,0))
    for i, title in enumerate(["Baseline diagnostic SDR", "Native translation", "Native constrained homography", "External vid.stab (24 fps)"]):
        panel = Image.new("RGBA", (320,18), (0,0,0,220))
        ImageDraw.Draw(panel).text((4,2), title, fill="white")
        labels.paste(panel.resize((640,36), Image.Resampling.NEAREST), ((i%2)*640,(i//2)*360))
    with overlay.open("xb") as file:
        labels.save(file, format="PNG")
    args = ["ffmpeg", "-v", "error", "-n"]
    for movie in ["baseline/diagnostic.mov", "translation/diagnostic.mov", "homography/diagnostic.mov", "reference.mov"]:
        args += ["-i", directory/movie]
    args += ["-loop", "1", "-i", overlay, "-filter_complex",
             "[0:v]scale=640:360[a];[1:v]scale=640:360[b];[2:v]scale=640:360[c];[3:v]scale=640:360[d];"
             "[a][b][c][d]xstack=inputs=4:layout=0_0|640_0|0_360|640_360:shortest=1[grid];[grid][4:v]overlay=shortest=1[v]",
             "-map", "[v]", "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
             "-movflags", "+faststart", directory/"comparison.mp4"]
    command(args, directory/"comparison.log")
    command(["ffmpeg", "-v", "error", "-n", "-ss", "1.5", "-i", directory/"comparison.mp4", "-frames:v", "1",
             directory/"comparison.jpg"], directory/"comparison-still.log")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "benchmark", "performance", "comparison"])
    parser.add_argument("root", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--reference", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--case", default="s5-event")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.action == "prepare":
        root.mkdir(exist_ok=False)
        generate(root)
    elif args.action == "benchmark":
        manifest = json.loads((args.manifest or root / "synthetic.json").read_text())
        benchmark(root, manifest, args.reference)
    elif args.action == "performance":
        if args.source is None:
            parser.error("performance requires --source ORIGINAL_VIDEO")
        performance(root, args.source.resolve())
    else:
        comparison(root, args.case)


if __name__ == "__main__":
    main()
