@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

struct FrameTimeTests {
    @Test func framesMapToExactTimes() {
        let rate = FrameRate.ntsc23976
        #expect(rate.time(ofFrame: 0) == .zero)
        #expect(rate.time(ofFrame: 1) == CMTime(value: 1001, timescale: 24000))
        #expect(rate.time(ofFrame: 33_239) == CMTime(value: 33_239 * 1001, timescale: 24000))
        #expect(rate.time(ofFrame: 1_000_000_000).value == 1_000_000_000 * 1001)
        for frame: Int64 in [0, 1, 2, 1117, 33_239, 1_000_000_000] {
            #expect(rate.frame(containing: rate.time(ofFrame: frame)) == frame)
            // Just before a frame starts, the previous frame is still showing.
            if frame > 0 {
                #expect(rate.frame(containing: CMTimeSubtract(rate.time(ofFrame: frame), CMTime(value: 1, timescale: 24000))) == frame - 1)
            }
        }
    }

    @Test func originOffsetsAreExact() {
        let rate = FrameRate(frameDuration: 1, timescale: 25)
        let origin = CMTime(value: 3600, timescale: 1)
        #expect(rate.time(ofFrame: 10, origin: origin) == CMTime(value: 3600 * 25 + 10, timescale: 25))
        #expect(rate.frame(containing: rate.time(ofFrame: 10, origin: origin), origin: origin) == 10)
    }

    @Test func trackDurationsSnapToStandardRates() {
        #expect(FrameRate(frameDuration: CMTime(value: 1001, timescale: 24000)) == .ntsc23976)
        #expect(FrameRate(frameDuration: CMTime(value: 3754, timescale: 90000)) == .ntsc23976)
        #expect(FrameRate(frameDuration: CMTime(value: 2, timescale: 50)) == FrameRate(frameDuration: 1, timescale: 25))
        #expect(FrameRate(frameDuration: CMTime(value: 1001, timescale: 60000)) == FrameRate(frameDuration: 1001, timescale: 60000))
        #expect(FrameRate(frameDuration: CMTime(value: 1001, timescale: 30000))?.framesPerSecond ?? 0 > 29.97)
        #expect(FrameRate(frameDuration: .invalid) == nil)
    }

    /// Task 13.2: an iPhone clip at 24 fps (nominal 23.9976) has one 24/600 s frame, which is exactly
    /// 1/25 s, so its minimum frame duration alone says 25 fps. The nominal rate wins when it is a
    /// standard rate; otherwise (variable-rate phone clips) the minimum duration still decides.
    @Test func aShortFrameDoesNotChangeTheRate() {
        let iPhone = FrameRate.detected(nominalFramesPerSecond: 23.997612, minimumFrameDuration: CMTime(value: 24, timescale: 600))
        #expect(iPhone == FrameRate(frameDuration: 1, timescale: 24))
        let lumix = FrameRate.detected(nominalFramesPerSecond: 23.976, minimumFrameDuration: CMTime(value: 1001, timescale: 24000))
        #expect(lumix == .ntsc23976)
        let variable = FrameRate.detected(nominalFramesPerSecond: 29.4, minimumFrameDuration: CMTime(value: 20, timescale: 600))
        #expect(variable == FrameRate(frameDuration: 1, timescale: 30))
        #expect(FrameRate.detected(nominalFramesPerSecond: 0, minimumFrameDuration: .invalid) == nil)
    }

    @Test func secondsRoundToTheNearestFrame() {
        let rate = FrameRate.ntsc23976
        #expect(rate.nearestFrame(toSeconds: 1) == 24)
        #expect(rate.nearestFrame(toSeconds: 12.5) == 300)
        #expect(FrameRate(frameDuration: 1, timescale: 25).nearestFrame(toSeconds: 0.5) == 12) // 12.5 ties to even
    }

    @Test func framesConvertBetweenRates() {
        let pal = FrameRate(frameDuration: 1, timescale: 25)
        let ntsc60 = FrameRate(frameDuration: 1001, timescale: 60000)
        #expect(FrameRate.ntsc23976.frames(240, in: .ntsc23976) == 240)
        #expect(ntsc60.frames(60, in: .ntsc23976) == 24) // 2.5× exactly
        #expect(pal.frames(25, in: .ntsc23976) == 24) // 1 s → 23.976 frames, rounded
    }
}

struct ProjectMigration11Tests {
    private let document = ProjectDocument()
    private let assetID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let clipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
    private let secondClipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    /// A schema-10 project as the app wrote it: clip times in seconds, no frame rates.
    private func schema10Project(url: String = "/Volumes/Card/P1107158.MOV") -> Data {
        Data("""
        {
          "schemaVersion": 10,
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Old Cut",
          "createdAt": "2026-10-01T12:00:00Z",
          "updatedAt": "2026-10-01T12:00:00Z",
          "media": [{ "id": "\(assetID)", "url": "file://\(url)", "kind": "video", "durationSeconds": 30.0 }],
          "adjustmentsByAssetID": [],
          "timelineClips": [
            { "id": "\(clipID)", "assetID": "\(assetID)", "videoTrack": 0, "audioTrack": 0,
              "timelineStartSeconds": 0, "sourceStartSeconds": 2.48, "durationSeconds": 4.0,
              "isEnabled": true, "isMuted": false },
            { "id": "\(secondClipID)", "assetID": "\(assetID)", "videoTrack": 0, "audioTrack": 0,
              "timelineStartSeconds": 4.0, "sourceStartSeconds": 10.0, "durationSeconds": 2.0,
              "isEnabled": true, "isMuted": true }
          ]
        }
        """.utf8)
    }

    @Test func schema10ClipsKeepTheirSecondsAndGetProvisionalFrames() throws {
        let project = try document.project(from: schema10Project())
        #expect(project.schemaVersion == 10)
        let clip = try #require(project.timelineClips.first)
        #expect(clip.legacyTiming == LegacyClipTiming(timelineStartSeconds: 0, sourceStartSeconds: 2.48, durationSeconds: 4.0))
        #expect(clip.frameRate == .ntsc23976)
        #expect(clip.sourceStartFrame == 59 && clip.durationFrames == 96)
        #expect(project.timelineClips[1].isMuted)
    }

    @Test func unconvertedClipsSaveTheirOriginalSecondsUnchanged() throws {
        let project = try document.project(from: schema10Project())
        let saved = try document.project(from: document.data(for: project))
        #expect(saved.schemaVersion == EditorProject.currentSchemaVersion)
        #expect(saved.timelineClips == project.timelineClips, "Offline clips must not be rounded twice")
        #expect(saved.timelineClips[0].legacyTiming?.sourceStartSeconds == 2.48)
    }

    @Test func knownFrameRatesConvertClipsExactlyAndRepackTheTimeline() throws {
        var project = try document.project(from: schema10Project())
        let pal = FrameRate(frameDuration: 1, timescale: 25)
        let changed = project.adoptVideoMetadata([
            assetID: VideoMetadata(durationSeconds: 30, frameRate: pal, frameCount: 750)
        ])
        #expect(changed)
        #expect(project.media[0].frameRate == pal && project.media[0].frameCount == 750)
        let first = project.timelineClips[0], second = project.timelineClips[1]
        #expect(first.legacyTiming == nil && second.legacyTiming == nil)
        #expect(first.frameRate == pal && first.sourceStartFrame == 62 && first.durationFrames == 100)
        #expect(second.sourceStartFrame == 250 && second.durationFrames == 50)
        #expect(first.timelineStartFrame == 0 && second.timelineStartFrame == 100)
        #expect(project.sequenceFrameRate == pal)

        // Reopening gives the same frames and nothing left to convert.
        let reopened = try document.project(from: document.data(for: project))
        #expect(reopened.timelineClips == project.timelineClips)
        #expect(reopened.schemaVersion == EditorProject.currentSchemaVersion)
    }

    @Test func clipsOfOfflineSourcesStayInSeconds() throws {
        var project = try document.project(from: schema10Project())
        let changed = project.adoptVideoMetadata([:])
        #expect(!changed)
        #expect(project.timelineClips.allSatisfy { $0.legacyTiming != nil })
    }

    @Test func newerSchemasAreStillRejected() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: schema10Project()) as? [String: Any])
        object["schemaVersion"] = EditorProject.currentSchemaVersion + 1
        #expect(throws: ProjectDocumentError.self) {
            try document.project(from: JSONSerialization.data(withJSONObject: object))
        }
    }

    /// End to end: opening a schema-10 project reads the movie's frame rate and converts its clips
    /// without marking the project edited.
    @MainActor
    @Test func openingAnOldProjectConvertsClipsOnceTheSourceIsRead() async throws {
        let temp = try TempDirectory()
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("P1107158.MOV"), frames: 480, width: 160, height: 90)
        let projectURL = temp.url.appendingPathComponent("Old.pmedit")
        try schema10Project(url: movie.path).write(to: projectURL)
        let suite = "pme-migration-tests-\(UUID().uuidString)"
        let store = EditorStore(
            presetRepository: UserPresetRepository(defaults: UserDefaults(suiteName: suite)!),
            proxyStore: ProxyStore(directory: try temp.subdirectory("Proxy Cache"), availableBytes: { _ in 1 << 40 }),
            proxyDefaults: UserDefaults(suiteName: suite)!
        )
        try store.loadProject(from: projectURL)
        try await waitUntil { store.project.timelineClips.allSatisfy { $0.legacyTiming == nil } }

        let asset = try #require(store.project.media.first)
        #expect(asset.frameRate == .ntsc23976 && asset.frameCount == 480)
        // Source color is backfilled in the same pass (the fixture is ProRes 422 tagged Rec. 709).
        let color = try #require(asset.sourceColor)
        #expect(color.transfer == .rec709 && color.bitDepth == 10 && color.chroma == .yuv422 && color.detectedFrom == .formatDescription)
        let first = store.project.timelineClips[0]
        #expect(first.sourceStartFrame == 59 && first.durationFrames == 96)
        #expect(store.project.timelineClips[1].timelineStartFrame == 96)
        #expect(!store.hasUnsavedChanges, "Converting old timing alone must not mark the project edited")
        store.proxyStore.cancelAll()
    }
}
