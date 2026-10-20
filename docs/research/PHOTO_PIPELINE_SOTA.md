# Photo pipeline state of the art (research, 2026-10-19)

Condensed from three research passes: pro-editor pipelines, on-device ML/GPU techniques, and a map of this app's pipeline. Licenses marked "verify" were not confirmed against the LICENSE file; check before shipping. GPL/NC projects are reference only: reimplement from papers, never copy code or weights.

## 1. How the best editors order their pipeline

darktable (scene-referred, `src/common/iop_order.c`) and the docs' rationale:

1. CFA stage: black/white level, white balance, highlight reconstruction, CA, hot pixels, raw denoise, then demosaic.
2. Linear camera RGB until the input profile: profiled denoise, lens, geometry, retouch (noise is still Poisson-Gaussian, optics assume linear light).
3. Scene-referred linear working RGB (Rec.2020): chromatic adaptation, local contrast, sharpen/diffuse, color grading. Unbounded, nothing clips.
4. One display transform: filmic rgb, sigmoid or AgX. Never stack two.
5. Display-referred tail: legacy tools, vignette, grain, output profile, dither.

Docs: https://docs.darktable.org/usermanual/5.6/en/darkroom/pixelpipe/the-pixelpipe-and-module-order/

## 2. Color

- Camera profiles: Adobe DNG dual-illuminant matrices plus HueSatMap/LookTable (DNG spec 1.7 ch. 6; Adobe DNG SDK `dng_color_spec.cpp`).
- WB as a CAT (CAT16 / Bradford) in linear, before tone. darktable `channelmixerrgb.c`.
- Hue/sat edits in a perceptual space: Oklab/OkLCh (https://bottosson.github.io/posts/oklab/), JzAzBz, CAM16/Hellwig JMh (ACES 2.0).
- Grading: three-way wheels on chroma at constant hue (Lightroom Color Grading, darktable color balance rgb). Hue-sector editors (Capture One, darktable color equalizer). Point Color = sampled color + range + variance.
- Gamut mapping: compress chroma toward the achromatic axis at constant perceptual hue with a soft knee (ACES 2.0 cusp-based compressor).

## 3. Tone

| Operator | Notes |
|---|---|
| filmic rgb v7 | log shaper + polynomial S-curve; `filmicrgb.c` |
| sigmoid | log-logistic, contrast + skew, per-channel with hue preservation; `sigmoid.c` |
| AgX | inset matrix, log2 encode, sigmoid, outset matrix; https://github.com/sobotka/AgX |
| ACES 2.0 OT | JMh tonescale + chroma compression + gamut compression; https://github.com/aces-aswf/aces-core |
| OpenDRT | https://github.com/jedypod/open-display-transform |

Local tone: tone equalizer (log-luminance mask smoothed with guided filter, 9 EV bands via Gaussian RBF; `toneequal.c`), local Laplacian (Paris 2011, Aubry 2014; Halide `apps/local_laplacian`, MIT), Filmulator.

Apple: `CIRAWFilter.boostAmount`, `localToneMapAmount`, `extendedDynamicRangeAmount`. https://developer.apple.com/documentation/coreimage/cirawfilter

## 4. Detail

- Denoise: variance-stabilized profiled NLM/wavelet (darktable `denoiseprofile.c`); commercial = neural, on mosaic data (DxO DeepPRIME XD2/XD3, Adobe Denoise).
- Capture sharpening: Richardson-Lucy deconvolution with Gaussian PSF in linear after demosaic (RawTherapee `capturesharpening.cc`). Diffuse-or-sharpen (anisotropic diffusion) in darktable.
- Super resolution: Adobe SR, Pixelmator ML SR, Real-ESRGAN.

## 5. Masks, lens, retouch, HDR

- Masks: AI (subject, sky, people parts, objects, depth) + range (luma, color, depth) + drawn, combinable add/subtract/intersect; masks belong to the framework, not individual tools (darktable `blend.c`).
- Lens: lensfun (LGPL lib, CC-BY-SA DB): distortion, TCA, vignetting. Auto-upright: LSD lines, vanishing points, homography (Lee 2012).
- Retouch: Poisson / mean-value-coordinates heal, PatchMatch, LaMa for large removals.
- HDR: edit above 1.0 on EDR, export SDR base + gain map (ISO 21496-1; Ultra HDR https://github.com/google/libultrahdr).

## 6. On-device ML shortlist (Apple silicon, commercially safe)

| Area | Pick | License | Size / note |
|---|---|---|---|
| Promptable masks | SAM 2.1 tiny/small Core ML (apple/coreml-sam2.1-small) | Apache-2.0 | encode once, decode per click |
| Depth | Depth Anything V2 Small (apple/coreml-depth-anything-v2-small) | Apache-2.0 | ~50 MB; B/L/G are CC-BY-NC, avoid |
| Matting | BiRefNet (lite) | MIT | hair-level edges |
| Face parsing | BiSeNet face-parsing | MIT | 19 classes |
| Inpaint | LaMa (big-lama Core ML ports) | Apache-2.0 | ~187 MB; crop, fill, transfer high frequencies back |
| Super-res | Real-ESRGAN `realesr-general-x4v3` | BSD-3 | fast on ANE |
| Denoise | NAFNet / SCUNet / Restormer | MIT / Apache / MIT | NAFNet FP16 edge artifacts reported; retune normalization |
| Auto tone | HDRNet / image-adaptive 3D LUT (FiveK) | Apache / verify | low-res net, full-res LUT/grid apply |
| WB | FFCC | Apache-2.0 | tiny, portable |

Avoid shipping: MAT (CC BY-NC), SegFormer weights (NC), Depth Anything V2 B/L/G (NC), RVM (GPL), hdr-plus-swift (GPL), darktable/RawTherapee code (GPL).

ANE guidance: convs + SimpleGate beat window attention; FP16 needs care around norms; tile with overlap; palettize to 6/8-bit; predict grids/LUTs/masks at <=1K and apply at full res in Metal.

## 7. Quality evaluation

Metrics: NVIDIA FLIP (BSD-3), SSIMULACRA2, Butteraugli, LPIPS, DeltaE2000/ITP. Golden-image rule: compare in linear float or 16-bit, use tolerances (GPU/ANE results differ across chips), store diff heatmaps.

## 8. This app (main @ 0d3283a, plus redesign branch)

Weakest areas, in order: generic Core Image tone core (no Whites/Blacks, opaque `CIHighlightShadowAdjust`, shoulder RAW-only); sRGB working/output gamut with naive HSL and warmth applied after curves; 8-bit sRGB preview and export with no metadata or output sharpening; preview/export disagree on pixel-radius filters and vignette is applied before crop; minimal detail tools; basic heal; thin local adjustments; no image-quality regression tests.

## References

- darktable https://github.com/darktable-org/darktable, RawTherapee https://github.com/Beep6581/RawTherapee, ART https://github.com/artpixls/ART, vkdt https://github.com/hanatos/vkdt
- ACES 2.0 gamut compression https://draftdocs.acescentral.com/output-transforms/technical-details/gamut-compression
- Ultra HDR https://developer.android.com/media/platform/hdr-image-format
- Depth Pro https://github.com/apple/ml-depth-pro, LaMa https://github.com/advimman/lama, BiRefNet https://github.com/ZhengPeng7/BiRefNet
