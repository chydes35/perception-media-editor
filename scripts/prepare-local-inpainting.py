#!/usr/bin/env python3
"""Download only the pinned safetensors components for the local feasibility probe."""
import argparse
import concurrent.futures
import hashlib
from pathlib import Path
import time
import urllib.request

MODEL = "stable-diffusion-v1-5/stable-diffusion-inpainting"
REVISION = "8a4288a76071f7280aedbdb3253bdb9e9d5d84bb"
WEIGHTS = {
    "unet/diffusion_pytorch_model.fp16.safetensors": "24b788b4a777748377cc20364eea4ae113c8c42f4468c16bc8c02fdae5492af9",
    "vae/diffusion_pytorch_model.fp16.safetensors": "4fbcf0ebe55a0984f5a5e00d8c4521d52359af7229bb4d81890039d2aa16dd7c",
    "text_encoder/model.fp16.safetensors": "77795e2023adcf39bc29a884661950380bd093cf0750a966d473d1718dc9ef4e",
}
CONFIGS = ["README.md", "scheduler/scheduler_config.json", "unet/config.json", "vae/config.json",
           "text_encoder/config.json", "tokenizer/merges.txt", "tokenizer/vocab.json",
           "tokenizer/tokenizer_config.json", "tokenizer/special_tokens_map.json"]


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    def fetch(relative):
        target = args.output / relative
        expected = WEIGHTS.get(relative)
        if target.exists() and (not expected or digest(target) == expected):
            print(f"Cached: {relative}", flush=True)
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".download")
        url = f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{relative}"
        print(f"Downloading: {relative}", flush=True)
        started = last = time.monotonic()
        count = 0
        with urllib.request.urlopen(url, timeout=90) as response, partial.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                count += len(chunk)
                if time.monotonic() - last > 20:
                    print(f"{relative}: {count / 1e6:.0f} MB", flush=True)
                    last = time.monotonic()
        if expected and digest(partial) != expected:
            raise RuntimeError(f"Integrity check failed: {relative}")
        partial.replace(target)
        print(f"Verified: {relative} ({time.monotonic() - started:.1f}s)", flush=True)

    for path in CONFIGS:
        fetch(path)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        for result in pool.map(fetch, WEIGHTS):
            pass
    (args.output / "revision.txt").write_text(f"{MODEL}\n{REVISION}\n")


if __name__ == "__main__":
    main()
