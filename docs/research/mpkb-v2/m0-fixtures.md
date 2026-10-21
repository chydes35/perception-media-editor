# Local copied-S5 fixture contract

Date: 2026-10-21. Schema `PME-MPKB-M0-FIXTURES-2`, version 2. This extends the external `M0_Fixture_Manifest_Template.json` research input; version 1's illustrative examples were never observations. The committed [template](m0-fixture-manifest.template.json) is empty and explicitly NOT POPULATED. This fixture format is independent of application `.pmedit` schema **10**.

## Enrollment and privacy

The owner supplied a local test-photo folder during this session. Nine RW2 files were copied to a separate private directory with opaque `S5-0001.RW2` through `S5-0009.RW2` basenames. No camera JPEGs were supplied. Source names/paths, SHA-256 values, safe metadata and the source-to-copy mapping remain local. Do not commit media, populated manifests, private project files, faces, EXIF GPS, capture timestamps, personal filenames, camera serials or private logs. Hashes can identify known media; they are private too.

Use directory mode 700 and file mode 600 (`umask 077` before creating artifacts). Store the private directory outside every Git checkout and outside the supplied media directory. Copy bytes, not symlinks/hardlinks. Never edit, rename, delete or write metadata into supplied originals. Original SHA-256 is recorded before testing and checked after testing separately; the validator itself never opens originals.

Per-record permissions are exact Boolean grants: `copied_from_original`, `provenance_recorded_locally`, `read_copy`, `hash_copy`, `inspect_safe_metadata`, `render_copy`, `export_derivatives`, `generate_masks`, `publish_media`, `publish_metadata_or_hashes`. First four must be true before validation reads a media copy. Rendering/export/mask grants authorize separate existing tests, not the hashing command. Both publication flags remain false. Record the owner's authorization locally; a Boolean cannot establish consent or ownership. Do not infer permission for other folders or for sharing photographs.

## Data fields

| Field | Contract |
| --- | --- |
| `fixture_id`, `format` | `S5-NNNN`; RW2/JPG/JPEG. Exact copy basename is derived from these fields; no supplied path field. |
| `scenario` | Safe category, initially `unclassified` if unknown. Required categories in template are coverage goals, not assertions. |
| `shoot_id`, `capture_pair_id` | Null until verified; otherwise opaque `SHOOT-NNNN` / `PAIR-NNNN`. A derivative JPEG is not an in-camera matched capture. |
| `camera` | Model and firmware strings only with their verification flags true and a stated evidence method. Otherwise null. Software/encoder tags alone do not establish camera firmware. |
| `exposure` | ISO, shutter seconds, aperture, exposure mode and WB mode; unknowns null; values require a verification method. EXIF enumerations must be labeled as such. |
| `capture_mode` | Value null until verified; method and explicit uncertainty. Pixel dimensions alone do not prove ordinary/high-resolution mode, bit depth, compression or dual-gain behavior. |
| `sha256`, `byte_count` | Measured copy SHA-256 and exact positive bytes. |
| `original_sha256` | Optional locally recorded source hash. Null means original comparison NOT VERIFIED; a match compares the copy to that recorded hash, not the original's current state. |
| `baseline` | Audit and measurement commit, OS/hardware/RAM/toolchain, RAW support version if actually established. Null means unknown. |
| `measurements` | Private operation results with input IDs, revision, environment, cold/warm conditions and evidence references. No invented thresholds. |

## Reproduce validation

Python 3.11+ standard library; no app/package dependencies are added. Run from the repo root:

```sh
# Structure only, no media reads; success is NOT a populated-dataset pass.
python3 scripts/m0-validate-fixtures.py \
  --manifest docs/research/mpkb-v2/m0-fixture-manifest.template.json --check-template

# Define these locally; never check their values into Git.
python3 scripts/m0-validate-fixtures.py --manifest "$M0_PRIVATE_MANIFEST" --copies "$M0_COPIES"

# Disposable synthetic integrity/permission/privacy rejection checks.
python3 scripts/test-m0-fixtures.py
```

Copy the template outside Git; set `status` to `LOCAL_PRIVATE`, remove `example_not_measured`, add records and local permissions, and hash opaque copies. Do not populate the tracked template. Validator reads only enumerated copies, streams hashes, rejects nonregular files, symlinks, hardlinks, duplicate/path-like IDs, in-repo paths, denied read/hash permissions and changed/mismatched copies. It prints IDs/status only, suppressing exception paths and JSON. Exit 0 means copy integrity checked (or template structure only), 1 rejection, 3 empty dataset NOT VERIFIED. It does not decode media or independently verify EXIF, consent, scene coverage, RAW support, capture pairing or photographic quality.

Before and after existing tests, rerun copy validation. Separately compare current supplied-original hashes with the locally recorded source map, without printing paths/hashes. Protect outputs from originals and keep derivative output directories separate from copies. `PreviewReopenTests` additionally verifies the referenced copy's before/after SHA-256.

## Connect to existing tests

Use [the existing strategy](../../TESTING_STRATEGY.md) and [gate matrix](m0-test-gates.md). For controlled full QA, clear inherited `PME_*` / `PERCEPTION_*` opt-ins and explicitly set `PME_RAW_SAMPLES` to an approved copies directory (or empty directory for synthetic-only QA). Without that override `TestSupport.RawSample` can discover a pre-existing private sample directory.

`PME_WB_RAW` selects one copy for all four `HeldRawFilterTests`. `PME_RAW_SAMPLE_DIR` selects the copied folder for `MemoryPerformanceTests` when `PME_RUN_MEMORY_PROFILE=1`. Saved-project tests require a disposable schema-10 project referencing copies only; a procedural gradient mask/heal stroke can exercise persistence but cannot establish real portrait/segmentation quality. Do not activate the portrait-candidate test unless its input actually is a representative portrait.

Highlight real-media assertions have specific sunny-frame/camera-JPEG prerequisites and some expect legacy basenames. Do not rename original photos or claim arbitrary opaque samples meet these prerequisites. Keep the existing opt-ins disabled until appropriate approved copies/mapping are available; a bounded future change may let those diagnostic tests consume opaque manifest IDs.
