# Local generative removal feasibility trial

This is a standalone experiment on the 8 GB M1 MacBook Air. It is not integrated into PerceptionEditor build 14. The app and original RAW files are unchanged.

## Scope

Evaluate one established 512 × 512 inpainting model on a small photographic selection, using local Metal/MPS inference. Stop each trial after five minutes rather than expanding into a new model/runtime project. The test photo is a 1536 px preview of a local Lumix RW2 indoor scene; the selected object is the foreground yellow balloon and its shadow. This does not establish full-resolution RAW quality.

Model: [Stable Diffusion 1.5 Inpainting](https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-inpainting), pinned mirror revision `8a4288a76071f7280aedbdb3253bdb9e9d5d84bb`. Its 9-channel UNet is trained for masked inpainting, rather than using ordinary image-to-image generation. The three required half-precision safetensors weight files are verified against their published SHA-256 values. Runtime dependencies are pinned in `scripts/local-inpainting-requirements.txt`; an exact installed dependency snapshot is stored with the experiment.

Inference uses `local_files_only=True`, `HF_HUB_OFFLINE=1`, and `TRANSFORMERS_OFFLINE=1`. The preparation script downloads public model assets separately. No photograph is uploaded. The controlled benchmark does not load the separate output classifier; a general-purpose shipping feature would require a separate model/license/output-policy review.

## Reproduce

Use Python 3.11 and keep the runtime and model on the external SSD:

```sh
PME_PROBE_ROOT='/Volumes/ExSSD1/Codex Projects/Perception Edit/.build/local-inpainting'
python3.11 -m venv "$PME_PROBE_ROOT/venv"
PIP_CACHE_DIR="$PME_PROBE_ROOT/pip-cache" "$PME_PROBE_ROOT/venv/bin/python" -m pip install -r scripts/local-inpainting-requirements.txt
python3 scripts/prepare-local-inpainting.py "$PME_PROBE_ROOT/model"

HF_HOME="$PME_PROBE_ROOT/hf-cache" TORCH_HOME="$PME_PROBE_ROOT/torch-cache" \
PYTHONPYCACHEPREFIX="$PME_PROBE_ROOT/pycache" \
PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.8 PYTORCH_MPS_LOW_WATERMARK_RATIO=0.6 \
"$PME_PROBE_ROOT/venv/bin/python" -u scripts/local-inpainting-probe.py \
  --model "$PME_PROBE_ROOT/model" \
  --image "$PME_PROBE_ROOT/source-preview.png" \
  --output "$PME_PROBE_ROOT/balloon-seed17" \
  --crop '640,512,512,512' --selection '831,861,149,151' \
  --prompt 'gray patterned carpet floor, continuation of the surrounding carpet, indoor photograph' \
  --steps 20 --seed 17 --timeout 300
```

Crop and selection coordinates are in the oriented input image. The probe composites generated pixels only within the selected footprint and checks that every pixel outside it is unchanged. Inputs are never overwritten. Outputs include before/after/comparison PNGs, a full preview result, the selection mask, and timing/memory JSON. Later runs reuse the downloaded model and runtime.

Memory measurements distinguish process peak resident memory from sampled MPS tensor/driver allocation during inference; these can overlap and must not be added as total RAM. System swap snapshots also include other applications. The Mac already had several gigabytes of swap in use before the trial.

## Result

**Deferred until the core photo editor is complete.** The first run hit its 300-second watchdog and exited with status 124 without producing a finished generated image. It reached step 5 of 20. The first denoising step took 101.6 seconds; step 5 finished at 182.8 seconds of inference, so the next four steps together took another 81.2 seconds. This was not just an initial compilation delay.

System swap was approximately 4.8 GB before inference, rose to approximately 8.4 GB during the run, and was approximately 7.9 GB just after the process exited. These are system-wide observations under the Mac's existing workload, not isolated model memory measurements. The failed run did not reach the final sampler report, so no peak GPU/RSS value is claimed. A finished removal image and photographic quality assessment are unavailable.

The model occupies approximately 2.0 GiB and the isolated runtime approximately 762 MiB on the external SSD, plus dependency/cache files. The three weight hashes passed, runtime imports succeeded, and MPS availability was confirmed. The before image, selection mask, dependency snapshot, model revision, execution log, and observed-result JSON are saved under `.build/local-inpainting` on the external SSD. The probe now also writes partial metrics when its watchdog fires on a future run; that enhancement was syntax-checked but not followed by another expensive inference run.

This result applies to the tested Diffusers/PyTorch/SD 1.5 combination on this Mac under its current workload. It does not establish that every local inpainting model is impractical. A native Core ML or quantized approach would require another integration/optimization experiment, which is deferred per the user's request.

## Work needed for app integration

- A painted generation selection, progress/cancel, variations, and accept/discard controls.
- A durable generated-patch store, project schema, undo/redo, and recovery if patch files are missing.
- Source-coordinate placement through rotation, crop, preview, and full export, with exact preservation outside the selection.
- Defined behavior when RAW white balance or other development settings change after generation.
- Larger-area resolution, seam/grain/color matching, and representative photographic quality tests.
- A distributable runtime/model setup with an explicit memory budget and license review.

Complete the feasibility trial before committing to those implementation tasks.
