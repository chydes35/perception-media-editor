# Editor Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the six flat tabs with a Photo | Video bar and a left rail of large step buttons, split the video screen into Cut, Color and Audio, and add beat markers to the Cut timeline.

**Architecture:** `Workspace` stays the identity of a screen, so the existing guards (`workspace == .photo`) keep working. A new `EditorCategory` plus a per-category step list drive the new shell. The Video screen is split by extracting its shared pieces (media bin, viewer, timeline) so Cut, Color and Audio compose them. Scopes, histogram, curves and HSL reuse existing views behind a small "what am I editing" abstraction so they work for video clips.

**Tech Stack:** Swift 6.1, SwiftUI, Metal (runtime-compiled shader strings, no `.metal` files), AVFoundation, Swift Testing. macOS 15, CLT only.

**Spec:** `docs/superpowers/specs/2026-10-17-editor-redesign-design.md`

**Test command** (CLT-only Mac; the plan's `run-tests <Suite>`):
`SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing --filter <Suite>`

## Global Constraints

- Photo | Video along the top; Photo steps Import, Cull, Develop, Export; Video steps Import, Cut, Color, Audio, Export (spec, "Decisions the owner made").
- Agents is a smaller top-bar button, reachable from Photo and Video.
- The look follows the Mac's light and dark setting; both must look right. Never force an appearance.
- Minimum rail button height 56 pt, top-bar button height 36 pt.
- Photo tools do not change; old `.pmedit` projects open unchanged. Any model change bumps `EditorProject.currentSchemaVersion` (11 today) with a tested migration, and updates `docs/DATA_MODEL.md`.
- Originals are never written. Heavy work (scopes, waveforms, beat analysis) stays off the main actor, cancellable, memory-bounded for the 8 GB M1.
- Audio: 24-bit now; analysis reads decoded float samples so 32-bit float can be added later without redoing screens.
- No fake controls: a rail step exists only once its screen works.
- Done means: tests pass, and the owner-visible behavior is walked through in the running app on the target Mac (light and dark), reported PASS/FAIL/NOT VERIFIED per `AGENTS.md`. Update `docs/CURRENT_STATUS.md`, `ARCHITECTURE.md` and `TESTING_STRATEGY.md` with each part.

## Review Focus

Inputs and conditions the spec implies but does not name; each has a test in the owning task.
1. A schema 11 project with clip volumes opens in the new build with the same loudness (Task 9).
2. Color or Audio opened with no clips, no selection, or offline media: an empty state, no crash, no scopes running (Tasks 7 and 11).
3. A clip with no audio track, or digital silence: meters at floor, no clipped spots, no divide-by-zero in dB math (Task 10).
4. A 4-minute 24-bit song: beat analysis streams it in bounded memory and can be cancelled (Task 13).
5. Switching Photo/Video or leaving Color during playback: playback pauses, scopes turn off, previous screen state restored (Tasks 2 and 7).

## File Structure

| File | Responsibility |
| --- | --- |
| Create `Sources/PerceptionEditor/EditorNavigation.swift` | `EditorCategory`, `RailStep`, step lists, `Workspace.category`, `EditorMetrics` |
| Create `Sources/PerceptionEditor/EditorShell.swift` | `CategoryBar`, `StepRail`, button styles; `RootView` composes them |
| Modify `RootView.swift`, `EditorStore.swift`, `EditorModels.swift`, `PerceptionEditorApp.swift` | Wire the shell, category state, menu, undo guards |
| Create `Sources/PerceptionEditor/VideoParts.swift` | Extracted `VideoMediaBin`, `VideoViewer`, `VideoTimeline` from `VideoWorkspace.swift` |
| Create `Sources/PerceptionEditor/VideoColorWorkspace.swift` | Color screen |
| Create `Sources/PerceptionEditor/VideoAudioWorkspace.swift`, `AudioLevelAnalyzer.swift` | Audio screen and level/clipping analysis |
| Create `Sources/PerceptionEditor/VideoExportWorkspace.swift` | Video Export step (hosts `TimelineExportControls`) |
| Create `Sources/PerceptionEditor/BeatDetector.swift`, `SnapPoints.swift` | Beat analysis and snapping |
| Modify `ToneCurveEditor.swift`, `HSLPanel` (in `PhotoWorkspace.swift`) | Edit through `AdjustmentEditing` |
| Modify `ScopeRenderer.swift`, `MetalShaderSources.swift`, `ScopeModel.swift` | Histogram from the scope capture |
| Tests | `EditorNavigationTests`, `AdjustmentEditingTests`, `ScopeRendererTests` (extend), `AudioLevelAnalyzerTests`, `ProjectMigration12Tests`, `BeatDetectorTests`, `SnapPointsTests` |

---

# Part 1: The new shell and look

### Task 1: Navigation model

**Files:** Create `EditorNavigation.swift`; modify `EditorModels.swift` (`Workspace`), `EditorStore.swift`; Test `EditorNavigationTests.swift`.

**Interfaces:**
- Produces: `enum EditorCategory: String, CaseIterable, Identifiable, Sendable { case photo = "Photo", video = "Video" }`; `struct RailStep: Identifiable, Equatable { let id: String; let title: String; let symbol: String; let workspace: Workspace }`; `EditorCategory.steps: [RailStep]`; `Workspace.category: EditorCategory?` (nil for `.library`, `.agents`); `Workspace.videoExport` (new case); on the store `@Published private(set) var category: EditorCategory`, `func requestCategoryChange(to: EditorCategory)`, `func requestStepChange(_ step: RailStep)`, `func openAgents()`, `func closeAgents()`.

- [ ] **Step 1: Write failing tests** in `EditorNavigationTests` (`@MainActor`, serialized): `photoStepsAreImportCullDevelopExport` (titles and workspaces `[.library, .cull, .photo, .export]`); `videoStepsStartWithImportCutAndExport` (Part 1 list: `.library`, `.video`, `.videoExport`; Tasks 7 and 11 append Color and Audio); `changingCategoryReturnsToTheLastStepUsedThere` (photo→`.cull`, to video, back: `store.workspace == .cull`); `programmaticWorkspaceChangesKeepTheCategoryInSync` (`store.workspace = .cull` makes `category == .photo`; `.video` makes `.video`; `.library` leaves it alone); `agentsReturnsToWhereYouWere`.
- [ ] **Step 2: Run** `run-tests EditorNavigationTests`; expect compile failure (types missing).
- [ ] **Step 3: Implement** the interfaces above. `workspace.didSet` already calls `workspaceDidChange()`; add the category sync there. `requestStepChange` goes through `requestWorkspaceChange` (keep its deferral so SwiftUI picker updates stay legal). Remember last workspace per category in a dictionary.
- [ ] **Step 4: Run** the suite plus `WorkspaceTransitionTests`; expect PASS.
- [ ] **Step 5: Commit** `Task 1: category and step navigation model`.

### Task 2: Shell views, metrics and appearance

**Files:** Create `EditorShell.swift`; modify `RootView.swift`; Test `EditorNavigationTests` (add metrics).

**Interfaces:**
- Consumes: Task 1.
- Produces: `enum EditorMetrics { static let railButtonHeight: CGFloat = 56; static let categoryButtonHeight: CGFloat = 36; static let railWidth: CGFloat = 96 }`; `struct CategoryBar: View`, `struct StepRail: View`; `RailButtonStyle`, `CategoryButtonStyle` (`ButtonStyle`s).

- [ ] **Step 1: Tests:** `metricsMeetTheSpecMinimums` (`railButtonHeight >= 56`, `categoryButtonHeight >= 36`); `switchingCategoryPausesVideoPlayback` and `leavingAVideoScreenPausesPlayback` (a store with a playing timeline: after `requestCategoryChange(to: .photo)` or a step change away from a video screen, `isVideoPlaying == false`).
- [ ] **Step 2: Run, see it fail; Step 3: implement.** `CategoryBar`: Photo | Video large buttons, project name field, Agents button (symbol, smaller), no global Import/Export. `StepRail`: the current category's steps as large buttons, selected state uses the accent gradient. Use only semantic colors (`Color(nsColor:)`, `.primary`, materials) so light and dark both work; do not set `preferredColorScheme`. `RootView.body` becomes `CategoryBar` over `HStack { StepRail; workspace }` over the status bar. Switching category or leaving Color/Audio pauses playback (call the store's existing pause path).
- [ ] **Step 4: Run tests; build** (`swift build`). Expect PASS.
- [ ] **Step 5: Commit** `Task 2: category bar, step rail and metrics`.

### Task 3: Per-step Import and Export, menu and guards

**Files:** Modify `LibraryWorkspace.swift`, `ExportWorkspace.swift`, `PerceptionEditorApp.swift`, `VideoWorkspace.swift`; create `VideoExportWorkspace.swift`; Test `EditorNavigationTests`.

**Interfaces:**
- Consumes: `Workspace.videoExport`, `TimelineExportControls` (private in `VideoWorkspace.swift`, make internal).
- Produces: `struct VideoExportWorkspace: View`; `Workspace.isVideo: Bool` (true for `.video`, `.videoExport`, and later `.videoColor`, `.videoAudio`).

- [ ] **Step 1: Test** `isVideoCoversEveryVideoScreen` and `undoIsDisabledOnVideoScreens` (move the `store.workspace == .video` checks in `PerceptionEditorApp.swift:40,43,50` to `isVideo`).
- [ ] **Step 2: Implement.** The Import step is `LibraryWorkspace` with the import actions (card or folder, add files in place) in its header; for Video's Import it opens on the Video section of the sidebar. Photo Export is the existing `ExportWorkspace` (it must carry its own export button now that the top bar has none). Video Export hosts `TimelineExportControls` plus the last-export reveal, and its entry leaves the Cut toolbar. The Workspace menu lists the steps of both categories with ⌘-number shortcuts.
- [ ] **Step 3: Run** all of `EditorNavigationTests`, `TimelineExportStoreTests`, `WorkspaceTransitionTests`; expect PASS.
- [ ] **Step 4: Walk through** (running app, light and dark): both categories, every step reachable in two clicks, Agents from both, an existing `.pmedit` opens, Photo develop behaves as before. Record in `docs/CURRENT_STATUS.md`.
- [ ] **Step 5: Commit** `Task 3: Import and Export per category`.

---

# Part 2: Cut, Color and Audio

### Task 4: Extract shared video pieces

**Files:** Create `VideoParts.swift`; modify `VideoWorkspace.swift`.

**Interfaces:**
- Produces: `struct VideoMediaBin: View`, `struct VideoViewer: View` (viewer, transport, and the scope panel slot), `struct VideoTimeline: View` (today's `EditorTimelineView`), each taking only `@EnvironmentObject EditorStore`.

- [ ] **Step 1:** Run the video suites first as the baseline: `run-tests TimelineVideoCompositorTests`, `TimelineFrameExactTests`, `TimelineExporterTests`; all PASS.
- [ ] **Step 2: Move** (no behavior change) the three views out of `VideoWorkspace.swift`; `VideoWorkspace` composes them with the existing inspector. **Step 3:** rerun the same suites; PASS. Build.
- [ ] **Step 4: Commit** `Task 4: extract video bin, viewer and timeline`.

### Task 5: Editing target abstraction

**Files:** Modify `ToneCurveEditor.swift`, `PhotoWorkspace.swift` (`HSLPanel`); Test `AdjustmentEditingTests.swift`.

**Interfaces:**
- Produces: `struct AdjustmentEditing { var current: PhotoAdjustments; var update: (@MainActor (inout PhotoAdjustments) -> Void) -> Void }`; `EnvironmentValues.adjustmentEditing: AdjustmentEditing?` (nil means the selected photo); `EditorStore.videoAdjustmentEditing: AdjustmentEditing` (reads `selectedVideoAdjustments`, writes `updateSelectedVideoAdjustments`).

- [ ] **Step 1: Tests:** `videoCurveEditsLandOnTheSelectedClip` (select a timeline clip, update curves through `videoAdjustmentEditing`; `project.videoAdjustmentsByClipID[id]?.curves` changed and the photo adjustments did not); `photoEditorStillEditsThePhoto` (no environment value: `store.selectedAdjustments` changes).
- [ ] **Step 2: Run; fails. Step 3: Implement** — `ToneCurveEditor` and `HSLPanel` read `current` and write through `update` from the environment, falling back to the photo accessors.
- [ ] **Step 4: Run** `AdjustmentEditingTests`, `ColorGradingTests`, `PhotoAdjustmentTests`; PASS. **Step 5: Commit.**

### Task 6: Histogram from the scope capture

**Files:** Modify `MetalShaderSources.swift`, `ScopeRenderer.swift`, `ScopeModel.swift`; Test `ScopeRendererTests.swift`.

**Interfaces:**
- Produces: `ScopeAnalysis.histogram: HistogramData` (256 bins per channel, normalized 0…1 like the photo histogram); `ScopeModel.histogram: HistogramData`; kernel `histogramAccumulate` (atomic bins over the 512-wide capture, same dispatch as `waveformAccumulate`).

- [ ] **Step 1: Tests:** `aFlatGreyFrameFillsOneHistogramBin` (all three channels peak at the grey's code bin, other bins 0); `barsPutEachChannelWhereTheyBelong` (75% bars: red peak bins at 0 and 191 only at the red-carrying bars' share of pixels).
- [ ] **Step 2–4:** Run (fail); add the kernel and `analyze` output; run `ScopeRendererTests` (PASS). `ScopeModel` publishes it with the images. GPU cost stays under G9's 2 ms (measure with the existing scope timing; record in `docs/PERFORMANCE_TARGETS.md`).
- [ ] **Step 5: Commit.**

### Task 7: Color screen

**Files:** Create `VideoColorWorkspace.swift`; modify `EditorNavigation.swift` (add `.videoColor`, append the Color step), `RootView.swift`, `EditorStore.swift`; Test `EditorNavigationTests`.

**Interfaces:**
- Consumes: Tasks 4, 5, 6; `SourceColorPicker`, `ScopePanel`.
- Produces: `Workspace.videoColor`; `EditorStore.videoBeforeAfter: Bool` (when true the preview recipe for the selected clip is built with `.neutral` adjustments and no source-color transform; export is unaffected).

- [ ] **Step 1: Tests:** `colorStepIsInTheVideoRail`; `scopesRunOnlyWhileTheColorScreenIsShown` (entering `.videoColor` turns `scopesVisible` on, leaving restores the previous value); `beforeAfterBuildsANeutralPreviewRecipe` (compose with the flag, read the instruction's `recipe.adjustments == .neutral` and `inputLUT == nil`, `ocioInput == nil`); `colorWithNoClipShowsAnEmptyState` (no selected clip: no scope capture is enabled).
- [ ] **Step 2–4: Implement.** Layout per the approved mockup: viewer with before/after, a scope strip with mode chips (waveform, RGB parade, histogram, vectorscope) under it, and a right panel with source color, `ToneCurveEditor` (video editing), the light and color sliders, and `HSLPanel`. Provide `\.adjustmentEditing = store.videoAdjustmentEditing` to the panel.
- [ ] **Step 5: Walk through** on `P1107210` (V-Log): scopes and curves update live while grading; Automatic, ACES, As recorded and a LUT all show; both appearances. **Step 6: Commit.**

### Task 8: Trim the Cut screen

**Files:** Modify `VideoWorkspace.swift` (now the Cut screen).

- [ ] **Step 1:** Remove the color and audio sliders from the Cut inspector (they live in Color and Audio now); keep Media, Timeline Clip, and the toolbar tools (select, trim, split, ripple delete). **Step 2:** Rerun the Task 4 baseline suites (PASS) and `TimelineExportStoreTests`. **Step 3: Walk through** trim, split and ripple delete on real clips; frame-exact cuts unchanged. **Step 4: Commit** `Task 8: Cut screen`.

### Task 9: Audio gain model (schema 12)

**Files:** Modify `EditorModels.swift`, `ProjectDocument.swift`, `TimelineCompositionService.swift`, `EditorStore.swift`, `docs/DATA_MODEL.md`; Test `ProjectMigration12Tests.swift`.

**Interfaces:**
- Produces: `ClipAudioAdjustments.gainDecibels: Double` (default 0, range −60…+24); `EditorProject.masterGainDecibels: Double` (default 0); `static func decibels(forVolume: Double) -> Double` and `linearGain(forDecibels:) -> Double`; `currentSchemaVersion = 12`.

- [ ] **Step 0: Spike (no product code):** does `AVMutableAudioMixInputParameters.setVolume` with values above 1.0 amplify on this Mac? Measure with a 24-bit tone (peak level before and after, via `AVAssetReader`). Record the result in the design's "Left to the builder"; if it does not amplify, apply gain by processing samples (an `AVAudioMix` tap or a re-render) and say so in `ARCHITECTURE.md`.
- [ ] **Step 1: Tests:** `schema11VolumesBecomeEquivalentGain` (volume 0.5 migrates to −6.02 dB, volume 1.0 to 0, volume 0 to the −60 dB floor); `schema12ProjectsRoundTrip`; `schema11ProjectOpensAndSavesAsSchema12`; `newerSchemasAreStillRefused`; `gainAboveZeroIsAllowed` (+12 dB survives `updateSelectedAudioAdjustments`, which currently clamps volume to 0…1).
- [ ] **Step 2–4:** Run (fail); implement the fields, the migration in the decoder, the composition change (volume and fade math from linear gain), and master gain in the mix. Run `ProjectMigration12Tests`, `ProjectDocumentTests`, `ProjectMigration11Tests`, `TimelineVideoCompositorTests`; PASS.
- [ ] **Step 5: Commit** `Task 9: gain in dB and master gain (schema 12)`.

### Task 10: Level and clipping analysis

**Files:** Create `AudioLevelAnalyzer.swift`; Test `AudioLevelAnalyzerTests.swift`.

**Interfaces:**
- Produces: `struct AudioLevels: Equatable, Sendable { var peakDecibels: Double; var clippedRanges: [ClosedRange<Double>] }` (seconds); `enum AudioLevelAnalyzer { static func analyze(url: URL, range: ClosedRange<Double>?, gainDecibels: Double) async throws -> AudioLevels }`; clipped means a sample at or above 0 dBFS (`abs(sample) >= 1.0`) after gain, adjacent samples merged into one range.

- [ ] **Step 1: Tests** (generate 24-bit PCM WAV fixtures in a temp directory): `aQuietToneDoesNotClip` (peak ≈ −12 dBFS, no ranges); `aHotToneReportsItsClippedSpots` (two bursts at +3 dB over full scale give two ranges at the right times ±1 ms); `gainPushesAQuietToneIntoClipping` (−6 dBFS tone with +12 dB gain clips); `silenceIsAtTheFloor` (peak is the floor value, no NaN or −infinity); `aFileWithNoAudioTrackThrowsNoAudio`; `24BitFilesDecodeToTheSameLevelsAs16Bit` (same tone in 16 and 24 bit within 0.1 dB).
- [ ] **Step 2–4:** Run (fail); implement with `AVAssetReader` decoding to 32-bit float (streamed, never loading the whole file); run PASS.
- [ ] **Step 5: Commit.**

### Task 11: Audio screen

**Files:** Create `VideoAudioWorkspace.swift`; modify `EditorNavigation.swift` (add `.videoAudio`, append Audio step), `RootView.swift`, `EditorStore.swift`; Test `EditorNavigationTests`.

**Interfaces:**
- Consumes: Tasks 4, 9, 10, `AudioWaveformService`.
- Produces: `Workspace.videoAudio`; `EditorStore.audioLevels: AudioLevels?`, `func refreshAudioLevels() async`, `func jumpToNextClippedSpot()`.

- [ ] **Step 1: Tests:** `audioStepIsInTheVideoRail`; `clippedSpotsFollowTheMasterAndClipGain` (stub analyzer results; raising master gain changes the count); `jumpToNextClippedSpotMovesThePlayheadAndWraps`; `audioWithNoClipsShowsAnEmptyState`.
- [ ] **Step 2–4: Implement** per the approved mockup: L/R meters with a clip light (live during playback through the audio path chosen in Task 9's spike), master gain in dB, clipped count and jump button, per-clip gain, waveforms with clipped spots in red (from `audioLevels`, recomputed off the main actor and cancelled on edits). **Step 5: Walk through** with a loud clip: clipping is flagged, lowering gain clears it. **Step 6: Commit.**

---

# Part 3: Beats on the Cut timeline

### Task 12: Beat schema and snapping logic

**Files:** Modify `EditorModels.swift` (`MediaAsset.beatGrid`, schema 13), `docs/DATA_MODEL.md`; create `SnapPoints.swift`; Test `SnapPointsTests.swift`, `ProjectMigration12Tests` (extend as 13).

**Interfaces:**
- Produces: `struct BeatGrid: Codable, Equatable, Sendable { var tempo: Double; var beats: [Double]; var nudgeSeconds: Double }` (beats in seconds from the file start; `nudgeSeconds` is the owner's offset); `enum SnapPoints { static func snapped(_ time: Double, to beats: [Double], within: Double) -> Double? ; static func beats(in grid: BeatGrid, division: BeatDivision) -> [Double] }`; `enum BeatDivision: String, Codable { case half, whole, double }` (the "Beat grid: 1/2" chip).

- [ ] **Step 1: Tests:** `snapsToTheNearestBeatWithinTheThreshold`; `returnsNilOutsideTheThreshold`; `halfDivisionAddsBeatsBetweenTheOnes` and `doubleDivisionKeepsEveryOtherBeat`; `nudgeShiftsEveryBeat`; `schema12ProjectsOpenWithoutBeatGrids`.
- [ ] **Step 2–4:** Run (fail); implement; PASS. **Step 5: Commit** `Task 12: beat grid model and snapping`.

### Task 13: Beat detection

**Files:** Create `BeatDetector.swift`; Test `BeatDetectorTests.swift`.

**Interfaces:**
- Produces: `enum BeatDetector { static func detect(url: URL) async throws -> BeatGrid }`, cancellable, decoding a mono 22.05 kHz float stream (bounded memory).

- [ ] **Step 1: Tests:** `aClickTrackAt120BPMGivesHalfSecondBeats` (every detected beat within 20 ms of the truth, tempo within 1 BPM); `aTrackWithAnIntroOffsetKeepsItsPhase` (clicks starting at 0.31 s); `cancellationStopsPromptly` (cancelled task returns within 1 s on a long synthetic file); `aFourMinute24BitFileKeepsMemoryBounded` (peak footprint increase under 100 MB while detecting).
- [ ] **Step 2–4:** Run (fail); implement (the method is the builder's choice: onset-strength envelope then tempo and phase estimation). Run PASS. **Step 5: Real check:** a real song the owner chooses: markers line up with an audible beat; record NOT VERIFIED if no song is supplied. **Step 6: Commit.**

### Task 14: Beats and snapping in the Cut UI

**Files:** Modify `VideoParts.swift` (`VideoTimeline`), `VideoWorkspace.swift`, `EditorStore.swift`; Test `SnapPointsTests` (extend).

**Interfaces:**
- Consumes: Tasks 12, 13.
- Produces: `EditorStore.snapToBeats: Bool`, `beatDivision: BeatDivision`, `func analyzeBeats(for assetID: UUID) async`, `func snappedEditTime(_ seconds: Double) -> Double` (used by trim, move and split; returns the input when snapping is off or no grid).

- [ ] **Step 1: Tests:** `editsSnapToBeatsOnlyWhenEnabled`; `snappedTimesStayOnWholeFrames` (the snapped time is converted to the sequence frame grid, so frame-exactness is kept); `trimAndSplitGoThroughTheSnap` (split at a time near a beat lands on the beat's frame).
- [ ] **Step 2–4:** Implement the toolbar chips ("Snap to beats", "Beat grid"), beat markers on the timeline over the song's waveform, the snap flag shown while dragging, and the grid nudge. Run `SnapPointsTests`, `TimelineFrameExactTests`, `TimelineExporterTests`; PASS.
- [ ] **Step 5: Walk through** cutting a short piece to a real song; frame-exact export still passes G6's synthetic suites. **Step 6: Commit** `Task 14: beat markers and snapping`. Update `docs/CURRENT_STATUS.md`, `ROADMAP.md`, `ARCHITECTURE.md`, `TESTING_STRATEGY.md`; run the full suite.
