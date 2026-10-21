#!/usr/bin/env python3
"""Summarize existing artifacts without changing measurements or source media."""
import argparse
import json
import math
from pathlib import Path
import subprocess
import run


def accelerations(report):
    result = {}
    samples = report["samples"]
    for index in range(1, len(samples)-1):
        a, b, c = samples[index-1:index+2]
        if not all(s["valid"] for s in [a,b,c]) or len({s["segment"] for s in [a,b,c]}) != 1:
            continue
        ta, tb, tc = [s["value"]/s["timescale"] for s in [a,b,c]]
        d1, d2 = tb-ta, tc-tb
        result[index] = sum((2*((c["path"][k]-b["path"][k])/d2-(b["path"][k]-a["path"][k])/d1)/(d1+d2))**2
                            for k in ["x", "y"])
    return result


def video_metadata(movie):
    return json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0",
                      "-show_entries", "stream=codec_name,pix_fmt,width,height,time_base,color_space,color_transfer,color_primaries",
                      "-of", "json", str(movie)], text=True))["streams"][0]


def first_frame(movie, width, height):
    from PIL import Image
    pixels = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(movie), "-frames:v", "1",
                                      "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"])
    return Image.frombytes("RGB", (width, height), pixels)


def summarize(root):
    rows = json.loads((root/"results.json").read_text())
    for row in rows:
        directory = root/row["name"]
        row["decode"]["wholeProcessMemory"] = run.process_memory(directory/"baseline.log")
        baseline = accelerations(json.loads((directory/"baseline-measured/motion.json").read_text()))
        series = {"baseline": baseline}
        for method, summary in row["methods"].items():
            measured = "reference-measured" if method == "vidstab" else method+"-measured"
            series[method] = accelerations(json.loads((directory/measured/"motion.json").read_text()))
            log = "reference.log" if method == "vidstab" else method+".log"
            summary["wholeProcessMemory"] = run.process_memory(directory/log)
            movie = directory/"reference.mov" if method == "vidstab" else directory/method/"diagnostic.mov"
            summary["encodedFormat"] = video_metadata(movie)
            summary["validResidualTriplets"] = len(series[method])
        # Rank only against identical frame-index triplets; reference still has a
        # documented 24-fps retiming limitation for fractional/VFR source timing.
        common = set.intersection(*(set(values) for values in series.values()))
        row["commonResidualTriplets"] = len(common)
        base = math.sqrt(sum(baseline[i] for i in common)/len(common)) if common else None
        row["baselineCommonJitterPxPerSecondSquared"] = base
        for method, summary in row["methods"].items():
            residual = math.sqrt(sum(series[method][i] for i in common)/len(common)) if common else None
            summary["commonResidualJitterPxPerSecondSquared"] = residual
            summary["commonJitterReduction"] = 1-residual/base if base and residual is not None else None
        if row["name"] == "static":
            from PIL import ImageChops, ImageStat
            width, height = row["decode"]["width"], row["decode"]["height"]
            base_image = first_frame(directory/"baseline/diagnostic.mov", width, height)
            for method, summary in row["methods"].items():
                movie = directory/"reference.mov" if method == "vidstab" else directory/method/"diagnostic.mov"
                image = first_frame(movie, width, height)
                summary["staticFirstFrameMeanAbsoluteRGBDifference255"] = ImageStat.Stat(ImageChops.difference(base_image,image)).mean
    run.save(root/"summary.json", rows)
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    rows = summarize(args.root)
    for row in rows:
        print(row["name"], row["commonResidualTriplets"],
              {name: value["commonJitterReduction"] for name,value in row["methods"].items()})
