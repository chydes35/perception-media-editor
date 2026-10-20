# Export recipes: formats, metadata, output sharpening

Status: active (E1 implemented; UI check and batch run open)  
Roadmap: [Phase 4 delivery](../../docs/ROADMAP.md), image-quality program Q2 ([SOTA research](../../docs/research/PHOTO_PIPELINE_SOTA.md))  
Owner: lead agent

## User outcome and acceptance

Today every delivered photo is an 8-bit sRGB JPEG or PNG with no copyright, no output sharpening and no saved settings. After this plan the photographer picks (or saves) a named **recipe** and every export, one photo or a batch, follows it.

Milestones, each shippable on its own:

- **E1 (this plan's first pass):** recipe model and persistence; formats JPEG (8-bit), TIFF (16-bit), PNG (16-bit), HEIC (10-bit); sRGB output; long edge; output sharpening scaled to the output size (none, low, standard, high); metadata (keep camera EXIF/TIFF, copyright and creator written into TIFF/IPTC, optional removal of GPS location, default removal on); built-in recipes; Export workspace controls; the single-photo export uses the same engine.
- **E2 (separate pass):** a true Display P3 render. Process 2's display transform and OkLCh color kernel gain a target-gamut parameter so colors beyond sRGB survive to a P3 export. Process 1 photos stay sRGB-gamut (a P3 tag on sRGB data would add nothing, so it is not offered for them).
- **E3 (separate pass):** HDR export with an ISO 21496-1 gain map.

Acceptance for E1:

1. Each format writes a decodable file with the recipe's bit depth, dimensions and an embedded sRGB profile; TIFF and PNG are 16-bit.
2. Camera EXIF (exposure, lens, capture date) survives; orientation is normalized (pixels are already upright); GPS is absent when "Remove location" is on and present when off and the source has it.
3. Copyright and creator appear in the TIFF dictionary and IPTC (`CopyrightNotice`, `By-line`) when set, and are absent when empty.
4. Output sharpening is deterministic, grows local contrast on a resized edge, never moves a flat area, and its radius follows the output's long edge so a 2048 px and a 6000 px export look alike.
5. Existing batch behavior is unchanged for the default recipe: names, collisions, atomic publication, original protection, cancellation, failure continuation (the existing `BatchExport*` tests keep passing unmodified except for extension handling).
6. Recipes persist across launches, can be saved, renamed-by-saving and deleted; built-ins cannot be deleted.
7. Peak memory for a full-resolution S5 export in the 16-bit formats stays within the 8 GB M1 budget (measured, recorded below).

Out of scope for E1: watermark, Display P3 and Adobe RGB, HDR, video export, upload targets, contact sheets.

## Current state and affected contracts

- `BatchExport.swift`: `BatchExportRecipe` (quality, long edge, suffix, `validate()`), `BatchExportPlanner` (names always `.jpg`), `BatchPhotoExporter` seam used by tests.
- `EditorStore+Export.swift`: sequential queue, one `PhotoRenderer` per run; calls `renderer.export(type: .jpeg, quality:, longEdgePixels:)`.
- `PhotoRenderer.export` (PhotoRenderer.swift): full decode, `MediaColorRenderer.render(includesGeometry: true)`, optional Lanczos resize, then `CIContext.writeJPEGRepresentation` / `writePNGRepresentation(.RGBA8)` in sRGB. Metadata is whatever Core Image carries over; **not verified** and not controlled. Verified first in step 1.
- `EditorStore.exportSelectedPhoto()` (save panel, JPEG/PNG) calls the same `PhotoRenderer.export`.
- `ExportFileSafety` protects originals and publishes atomically (temporary file in the destination folder, then link/rename); it takes any extension.
- `ExportWorkspace.swift`: batch recipe controls (quality, long edge, suffix).
- `.pmedit` schema: **not touched.** Recipes are user-level settings in `UserDefaults` (like user presets), not project data, so no migration.
- Rendering contract: the finished photo comes from `MediaColorRenderer.render`, which already branches on `processVersion`; export does not change tone or color.

## Implementation steps

1. Discovery test: what metadata does the current export write? Record it here. (Decides how much of the metadata path must be built rather than preserved.)
2. `ExportRecipe` model (Codable): format, quality, long edge, sharpening, metadata options, suffix; extend `BatchExportRecipe` rather than replace it, with defaults that reproduce today's behavior.
3. `ExportWriter`: render to a `CGImage` at the format's depth, build the metadata dictionary from the source's properties, write with ImageIO to the temporary URL that `ExportFileSafety` supplies.
4. `OutputSharpening`: Core Image unsharp mask on luminance after the resize, radius a share of the long edge, strength by level.
5. Planner chooses the extension from the format; single-photo export reuses the engine.
6. `ExportRecipeRepository` (UserDefaults, JSON), built-in recipes, Export workspace controls (recipe picker, format, quality, size, sharpening, copyright, creator, remove location, save/delete).
7. Tests, real-RAW check on the ivy shoot, memory measurement, docs, commit.

## Safety and performance

- Originals: unchanged path; every write still goes through `ExportFileSafety.writeAtomically` with the project's original URLs protected.
- Cancellation: unchanged; the renderer checks between steps and the atomic writer checks before and after the write.
- Memory: a 24 MP frame is 96 MB at 8-bit and 192 MB at 16-bit as RGBA; one image is materialized at a time and caches are cleared after each file (existing `defer { clearRenderCaches() }`). The 16-bit formats are the risk on the 8 GB machine, so peak footprint is measured with a real RW2 and recorded.
- Metadata privacy: location is removed by default. Copyright/creator come from the recipe only; nothing is read from or written to the original file.

## Verification

| Gate | Required check | Result and evidence |
| --- | --- | --- |
| Static/build | `git diff --check`; Swift build | PASS — `git diff --check` clean; debug test build clean (2026-10-19). Release app bundle NOT rebuilt since the UI landed. |
| Unit/integration | Format/depth/profile, metadata (keep, strip GPS, copyright), sharpening, planner extensions, recipe persistence, existing batch tests; full suite | PASS — 20 new tests (`ExportRecipeTests.swift`) and the 10 existing batch tests; full suite 765 tests with only the two known timing-sensitive `PresetHoverPreviewTests` failing (they fail on unmodified `5494275` too). |
| Runtime/UI | Export workspace: pick a recipe, export a batch, open the files | PASS (2026-10-20, built app, ivy1year1 project): picking "Web, 2048 px" filled format, quality, long edge, sharpening and suffix; typing copyright/creator showed the Modified marker; Export Selected Photos wrote `P1107261_web.jpg` to a chosen folder ("1 saved, 0 failed"); the file read back at 2048×1731 (source 6000×4000, cropped), 8-bit sRGB, copyright and creator in TIFF and IPTC, exposure/date/focal length equal to the RW2's, body serial number removed, orientation 1, EXIF dimensions equal to the file's. Save Recipe persisted to `UserDefaults` and Delete Recipe removed it and fell back to the default. GPS removal was not exercised with a real file (this frame has no GPS; covered by unit tests). One photo only; no multi-photo batch run. |
| Media quality | Real RW2 exports in each format, compared with the preview | Files PASS: one ivy-shoot RW2 (4000×6000, process 2) exported in all four formats decodes at the right size and depth (JPEG 8, TIFF 16, PNG 16, HEIC 10), keeps exposure data, loses GPS and serial number. Visual comparison with the preview NOT VERIFIED. |
| Performance | Peak footprint of a full-resolution 16-bit export on the 8 GB M1 | PASS for one frame — peak process footprint 454 MB after JPEG, TIFF, PNG and HEIC in sequence (146 MB after JPEG alone). Batch of 36 (2026-10-20, ivy1year1, `EditorStore.startBatchExport`, "Web, 2048 px", one renderer, your project's own edits): **36 saved, 0 failed, 134.6 s total (3.74 s per photo), 32.3 MB written, peak process memory 179 MB**; the same 36 forced to process 2: 134.5 s, 176 MB, 0 failed. Every output passed a check of long edge 2048, no GPS, no serial number, exposure data present. This is the test process's peak, not the whole app's (the app adds its own preview and thumbnail caches), and 36 is not 100–200: memory is flat per file because caches are cleared after each photo, so a 150-photo run should take roughly 9 minutes, but that is an extrapolation. 100–200-frame whole-app run NOT VERIFIED. |

## Decisions, discoveries, and remaining work

- **Discovery (step 1, 2026-10-19):** the current export already carries source EXIF/TIFF through Core Image, **including the full GPS dictionary** (and `BodySerialNumber` on RW2 exports), and keeps stale `PixelXDimension`/`PixelYDimension` from the source after a crop or resize. So privacy is a real gap today, not a missing feature. The plan therefore builds metadata by editing the source's property dictionary and handing it to Core Image with `CIImage.settingProperties`, and keeps the existing CIContext writers (no custom CGImage pipeline). The RW2 source's embedded profile is Display P3 (irrelevant to rendering; the render comes from the working space).
- "Remove location" is widened to "Remove location and camera serial number", still default ON.
- Recipes are user-level, not project-level: the same "Web 2048" recipe should apply to every shoot, and keeping them out of `.pmedit` avoids a schema change.
- Remove location defaults to ON: the photographer shares family and client work.
- P3 is deferred to E2 on purpose. Offering a P3 tag on process-1 data would change nothing visible, and a real P3 render needs the process-2 gamut work described above.
- **Steps 2-6 done (2026-10-19):** `ExportOptions.swift` (formats, output sharpening, metadata options and builder), `BatchExportRecipe` extended in place (Codable, defaults reproduce the old behavior except that location and serial number are now removed), `PhotoRenderer.export(recipe:)` sharing one render helper with the old `export(type:)` (which other tests still use, unchanged), `ExportRecipeLibrary` (4 built-ins, user recipes in `UserDefaults`), `ExportRecipeEditor` in the Export workspace, single-photo export using the selected recipe with the format taken from the file extension.
- **Sharpening discovery:** Core Image's luminance sharpen leaves a sub-quantization offset on flat areas (30-60 of 65,535 at the three levels); harmless, so the test bound is half an 8-bit step. The input is edge-clamped so the frame border is not read as an edge.
- **Known limits:** TIFF and PNG carry an opaque alpha channel (Core Image's 16-bit writers take RGBA), so TIFF files are about 183 MB per 24 MP frame uncompressed; TIFF compression and an alpha-free writer are follow-ups. Sharpening is luminance-only with no edge mask yet.
- **Remaining for E1:** a multi-photo batch in the app and the 100–200-frame run; then move this plan to `plans/completed/` or fold E2 (Display P3) into it.

