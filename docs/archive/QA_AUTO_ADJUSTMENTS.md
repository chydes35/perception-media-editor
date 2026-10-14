# Auto basic adjustments — build 15

## Behavior

The **Auto** button sits directly beneath the histogram in the Photo workspace. It suggests exposure, contrast, highlights, shadows, white balance, and tint for the selected photo. These are ordinary editable slider values, saved in existing project schema 10. Auto creates one named history step; Undo restores the previous settings. An identical repeated suggestion creates no extra history step.

Tone analysis uses the visible crop of an as-shot source preview. Existing basic adjustments are replaced rather than compounded. Crops, rotation, masks, retouch strokes, curves, HSL, vibrance, saturation, sharpness, vignette, and RAW detail controls remain user settings.

Analysis is local on a separate actor. Decode is bounded to 512 px and rasterized once as half-float linear RGB, retaining highlight headroom without repeating RAW demosaicing for every candidate. Tone fitting evaluates 64 px samples through the same adjustment graph as preview and export. Exposure, contrast, highlights, and shadows have conservative suggestion bounds; the user retains the full slider ranges afterward.

White balance requires enough spatially distributed, consistent, low-chroma midtone evidence. Small casts and scenes without credible neutrals retain neutral/as-shot WB. Other image formats receive warmth/tint suggestions. RAW uses the camera-calibrated neutral point, limits changes from as-shot Kelvin/tint, and accepts a correction only if the preview's neutral evidence improves. Mixed lighting and intrinsically colored objects can still require manual WB.

The button shows progress and becomes **Cancel Auto** during analysis. Escape cancels. Switching photos or workspaces, starting crop/slider editing, changing settings, and undo/redo invalidate pending results. Completion also checks the project identity, source URL, and original adjustment snapshot, so relinking cannot apply an old source's suggestion.

## Verification

Final serial regression: **247 tests in 42 suites passed**. Release compilation succeeded. The staged build 15 bundle retains the sky model and passed strict code-signature verification.

Image-quality tests cover dark and bright scenes, flat tonal range, backlit whites, supported warm/green casts, strong scene colors, all-black/all-white/transparent inputs, crop-dependent suggestions, repeated Auto, RAW detail preservation, project round-trip, one-step undo/redo, and stale-result cancellation.

The first tone tests exposed exposure/shadow substitution and insufficient range expansion; the revised fitting passed the same tests. A real RAW comparison exposed repeated demosaicing; the bounded raster fix reduced the focused RAW check from tens of seconds to about two seconds on this M1 in the observed run. Timing is fixture-specific, not a general guarantee.

The portrait comparison exposed excess saturation from tonal filters. The fit now penalizes changes in linear RGB chromaticity. A focused skin-like/blue color-ratio regression failed with insufficient color preservation and passed with the corrected weight, while brightness and range tests remained green.

Real fixture comparisons use a local Lumix RW2 indoor birthday scene, an indoor portrait JPEG, and the outdoor Eiffel Tower fixture documented in [Sky QA](QA_SKY_SELECTION.md). Preview PNGs and chosen settings are saved outside the repository on the external SSD. Auto is a suggested starting point; broader camera, high/low-key, sunset, mixed-light, and intentionally stylized photo validation remains useful.

## Installed app verification

Build 15 replaced the closed build 14 on the external SSD; build 14 was retained as a backup. Both the staged and installed bundles passed strict code-signature verification.

The native Open Project check exposed a packaging issue: `.pmedit` lacked a declared content type, so saved projects were disabled in the file picker. The bundle now exports `com.perceptionmedia.project`, conforming to JSON, for that extension. After registering the updated bundle, the system reported a declared JSON-compatible type and the picker successfully opened an existing 17-photo RAW project. The executable was unchanged by this metadata fix.

In the installed app, the Photo workspace rendered the image and histogram, with Auto immediately below it. Clicking Auto on an indoor RAW portrait changed Exposure from 0 to +0.15 and Shadows from 0 to +0.44, and created one named Auto history step. Command-Z restored the prior settings and selected the Start history entry. The project remains open with those prior settings. Existing project autosave rewrote the project file during the edit/undo check, so its byte hash changed; the post-undo saved values for the tested photo were neutral again.
