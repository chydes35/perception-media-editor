#!/usr/bin/env python3
"""Offline MPS inpainting feasibility probe; never overwrites the input photograph."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import threading
import time

# Downloading is a separate explicit preparation step. Inference cannot fetch anything.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"


def rect(value):
    result = tuple(int(x) for x in value.split(","))
    if len(result) != 4 or result[2] <= 0 or result[3] <= 0:
        raise argparse.ArgumentTypeError("Expected x,y,width,height in oriented source pixels")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--crop", type=rect, required=True)
    parser.add_argument("--selection", type=rect, required=True)
    parser.add_argument("--prompt", required=True)
    parser.add_argument("--negative", default="object, balloon, text, watermark")
    parser.add_argument("--steps", type=int, default=20)
    parser.add_argument("--seed", type=int, default=17)
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.steps <= 30 or not 1 <= args.timeout <= 600:
        parser.error("Probe is bounded to 1–30 steps and at most 600 seconds")
    outputs = {"before.png", "selection.png", "generated.png", "after.png", "full-result.png", "comparison.png", "metrics.json"}
    if args.image.resolve().parent == args.output.resolve() and args.image.name in outputs:
        parser.error("Output files must not overwrite the input photograph")
    args.output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    metrics = {"status": "starting", "resolution": [512, 512], "steps": args.steps,
               "seed": args.seed, "crop": args.crop, "selection": args.selection, "offline": True}
    peak = {"gpu_allocated_bytes": 0, "gpu_driver_bytes": 0}

    def timeout():
        result = dict(metrics, **peak, status="timeout", total_seconds=time.monotonic() - started)
        (args.output / "metrics.json").write_text(json.dumps(result, indent=2) + "\n")
        print("STOP: local probe exceeded its time limit", flush=True)
        os._exit(124)

    watchdog = threading.Timer(args.timeout, timeout)
    watchdog.daemon = True
    watchdog.start()
    import numpy as np
    import torch
    from PIL import Image, ImageDraw, ImageFilter, ImageOps
    from diffusers import AutoencoderKL, DDIMScheduler, StableDiffusionInpaintPipeline, UNet2DConditionModel
    from transformers import CLIPTextModel, CLIPTokenizer

    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is unavailable; this probe requires the Mac's local GPU")
    source = ImageOps.exif_transpose(Image.open(args.image)).convert("RGB")
    x, y, w, h = args.crop
    sx, sy, sw, sh = args.selection
    if x < 0 or y < 0 or x + w > source.width or y + h > source.height:
        parser.error("Crop must be inside the oriented source image")
    if sx < x or sy < y or sx + sw > x + w or sy + sh > y + h:
        parser.error("Selection must be inside the crop")
    before = source.crop((x, y, x + w, y + h))
    mask = Image.new("L", before.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((sx - x, sy - y, sx - x + sw - 1, sy - y + sh - 1),
                                          radius=min(sw, sh) // 8, fill=255)
    # Blur inward only, so no pixel outside the selected footprint can be replaced.
    blend = Image.fromarray(np.minimum(np.asarray(mask), np.asarray(mask.filter(ImageFilter.GaussianBlur(3)))))
    before.save(args.output / "before.png")
    mask.save(args.output / "selection.png")

    def swap():
        return subprocess.check_output(["/usr/sbin/sysctl", "vm.swapusage"], text=True).strip()

    metrics.update(device=f"MPS / {os.uname().machine}", swap_before=swap(), status="loading")
    print("Loading local safetensors components…", flush=True)
    load_start = time.monotonic()
    options = dict(torch_dtype=torch.float16, variant="fp16", use_safetensors=True, local_files_only=True)
    pipeline = StableDiffusionInpaintPipeline(
        vae=AutoencoderKL.from_pretrained(args.model / "vae", **options),
        text_encoder=CLIPTextModel.from_pretrained(args.model / "text_encoder", **options),
        tokenizer=CLIPTokenizer.from_pretrained(args.model / "tokenizer", local_files_only=True),
        unet=UNet2DConditionModel.from_pretrained(args.model / "unet", **options),
        scheduler=DDIMScheduler.from_pretrained(args.model / "scheduler", local_files_only=True),
        # This controlled removal benchmark only uses the supplied photograph and prompt.
        # A shipping general-purpose generator would need its own output review policy.
        safety_checker=None, feature_extractor=None, requires_safety_checker=False,
    ).to("mps")
    pipeline.enable_attention_slicing()
    pipeline.set_progress_bar_config(disable=True)
    metrics["load_seconds"] = time.monotonic() - load_start
    stop = threading.Event()

    def sample():
        while not stop.wait(0.5):
            peak["gpu_allocated_bytes"] = max(peak["gpu_allocated_bytes"], torch.mps.current_allocated_memory())
            peak["gpu_driver_bytes"] = max(peak["gpu_driver_bytes"], torch.mps.driver_allocated_memory())

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    infer_start = time.monotonic()

    def step(pipe, index, timestep, kwargs):
        metrics.update(completed_steps=index + 1, inference_elapsed_seconds=time.monotonic() - infer_start)
        if index == 0 or (index + 1) % 5 == 0:
            print(f"Step {index + 1}/{args.steps}: {time.monotonic() - infer_start:.1f}s", flush=True)
        return kwargs

    print("Generating locally…", flush=True)
    metrics["status"] = "generating"
    with torch.inference_mode():
        generated = pipeline(prompt=args.prompt, negative_prompt=args.negative,
                             image=before.resize((512, 512), Image.Resampling.LANCZOS),
                             mask_image=mask.resize((512, 512), Image.Resampling.NEAREST),
                             height=512, width=512, num_inference_steps=args.steps, guidance_scale=7.5,
                             generator=torch.Generator(device="cpu").manual_seed(args.seed),
                             callback_on_step_end=step).images[0]
    torch.mps.synchronize()
    metrics["inference_seconds"] = time.monotonic() - infer_start
    stop.set()
    sampler.join()
    generated.save(args.output / "generated.png")
    if np.asarray(generated).max() < 10:
        raise RuntimeError("Generated image is black; do not treat this as a successful result")
    after = Image.composite(generated.resize(before.size, Image.Resampling.LANCZOS), before, blend)
    changed = np.any(np.asarray(after) != np.asarray(before), axis=2)
    outside = np.asarray(mask) == 0
    metrics["changed_pixels_outside_selection"] = int(np.count_nonzero(changed & outside))
    if metrics["changed_pixels_outside_selection"]:
        raise RuntimeError("Compositing changed pixels outside the selection")
    after.save(args.output / "after.png")
    full = source.copy()
    full.paste(after, (x, y))
    full.save(args.output / "full-result.png")
    comparison = Image.new("RGB", (before.width * 2, before.height))
    comparison.paste(before, (0, 0))
    comparison.paste(after, (before.width, 0))
    comparison.save(args.output / "comparison.png")
    metrics.update(peak)
    metrics["process_peak_rss_bytes"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    metrics["swap_after"] = swap()
    metrics["total_seconds"] = time.monotonic() - started
    metrics["status"] = "completed"
    (args.output / "metrics.json").write_text(json.dumps(metrics, indent=2) + "\n")
    watchdog.cancel()
    print(json.dumps(metrics, indent=2), flush=True)


if __name__ == "__main__":
    main()
