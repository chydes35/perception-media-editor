@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

/// Schema 12: clip loudness is gain in dB (−60…+24, the floor is silence) and the project has a
/// master gain. Schema-11 clip volumes migrate to the equivalent gain.
@Suite(.serialized)
struct ProjectMigration12Tests {
    private let document = ProjectDocument()
    private let assetID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
    private let halfClipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    private let fullClipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    private let silentClipID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!

    /// A schema-11 project as the app wrote it: clip audio stores a 0…1 `volume`.
    private func schema11Project(url: String = "/Volumes/Card/P1107158.MOV") -> Data {
        func clip(_ id: UUID, start: Int) -> String {
            """
            { "id": "\(id)", "assetID": "\(assetID)", "videoTrack": 0, "audioTrack": 0,
              "frameRate": { "frameDuration": 1001, "timescale": 24000 },
              "timelineStartFrame": \(start), "sourceStartFrame": 0, "durationFrames": 48,
              "isEnabled": true, "isMuted": false }
            """
        }
        return Data("""
        {
          "schemaVersion": 11,
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Schema 11 Cut",
          "createdAt": "2026-10-01T12:00:00Z",
          "updatedAt": "2026-10-01T12:00:00Z",
          "media": [{ "id": "\(assetID)", "url": "file://\(url)", "kind": "video", "durationSeconds": 30.0 }],
          "adjustmentsByAssetID": [],
          "audioAdjustmentsByClipID": [
            "\(halfClipID)", { "volume": 0.5, "pan": -0.25, "fadeInSeconds": 0.5, "fadeOutSeconds": 0.25 },
            "\(fullClipID)", { "volume": 1.0, "pan": 0, "fadeInSeconds": 0, "fadeOutSeconds": 0 },
            "\(silentClipID)", { "volume": 0, "pan": 0, "fadeInSeconds": 0, "fadeOutSeconds": 0 }
          ],
          "timelineClips": [\(clip(halfClipID, start: 0)), \(clip(fullClipID, start: 48)), \(clip(silentClipID, start: 96))]
        }
        """.utf8)
    }

    @Test func schema11VolumesBecomeEquivalentGain() throws {
        let project = try document.project(from: schema11Project())
        let half = try #require(project.audioAdjustmentsByClipID[halfClipID])
        #expect(abs(half.gainDecibels - (-6.0206)) < 0.001)
        #expect(half.pan == -0.25 && half.fadeInSeconds == 0.5 && half.fadeOutSeconds == 0.25)
        #expect(project.audioAdjustmentsByClipID[fullClipID]?.gainDecibels == 0)
        #expect(project.audioAdjustmentsByClipID[silentClipID]?.gainDecibels == ClipAudioAdjustments.minimumGainDecibels)
        #expect(project.masterGainDecibels == 0)

        #expect(ClipAudioAdjustments.decibels(forVolume: 1) == 0)
        #expect(ClipAudioAdjustments.decibels(forVolume: 0) == -60)
        #expect(ClipAudioAdjustments.decibels(forVolume: 0.0001) == -60)
        #expect(abs(ClipAudioAdjustments.linearGain(forDecibels: -6.0206) - 0.5) < 0.0001)
        #expect(abs(ClipAudioAdjustments.linearGain(forDecibels: 12) - 3.981) < 0.001)
        #expect(ClipAudioAdjustments.linearGain(forDecibels: -60) == 0, "The floor is silence, as volume 0 was")
    }

    @Test func schema12ProjectsRoundTrip() throws {
        let clip = TimelineClip(assetID: assetID, sourceStartFrame: 0, durationFrames: 96)
        var project = EditorProject(
            name: "Loud",
            audioAdjustmentsByClipID: [clip.id: ClipAudioAdjustments(gainDecibels: 12, pan: 0.3, fadeInSeconds: 1, fadeOutSeconds: 0.5)],
            timelineClips: [clip]
        )
        project.masterGainDecibels = -3.5
        let data = try document.data(for: project)
        let decoded = try document.project(from: data)
        #expect(decoded.schemaVersion == 12)
        #expect(decoded.audioAdjustmentsByClipID == project.audioAdjustmentsByClipID)
        #expect(decoded.masterGainDecibels == -3.5)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"gainDecibels\"") && text.contains("\"masterGainDecibels\""))
        #expect(!text.contains("\"volume\""), "Schema 12 does not write the legacy volume")
    }

    @Test func schema11ProjectOpensAndSavesAsSchema12() throws {
        let opened = try document.project(from: schema11Project())
        #expect(opened.schemaVersion == 11)
        let data = try document.data(for: opened)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 12)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("\"volume\""))
        let reopened = try document.project(from: data)
        #expect(reopened.schemaVersion == 12)
        #expect(reopened.audioAdjustmentsByClipID == opened.audioAdjustmentsByClipID)
        #expect(reopened.timelineClips == opened.timelineClips)
    }

    @Test func newerSchemasAreStillRefused() throws {
        #expect(EditorProject.currentSchemaVersion == 12)
        var object = try #require(try JSONSerialization.jsonObject(with: schema11Project()) as? [String: Any])
        object["schemaVersion"] = 13
        #expect(throws: ProjectDocumentError.self) {
            try document.project(from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @MainActor
    @Test func gainAboveZeroIsAllowed() {
        let store = EditorStore()
        let video = MediaAsset(url: URL(fileURLWithPath: #filePath), kind: .video)
        let clip = TimelineClip(assetID: video.id, sourceStartFrame: 0, durationFrames: 120)
        store.project.media = [video]
        store.project.timelineClips = [clip]
        store.selectedTimelineClipID = clip.id

        store.updateSelectedAudioAdjustments { $0.gainDecibels = 12 }
        #expect(store.selectedAudioAdjustments.gainDecibels == 12)
        store.updateSelectedAudioAdjustments { $0.gainDecibels = 40 }
        #expect(store.selectedAudioAdjustments.gainDecibels == 24)
        store.updateSelectedAudioAdjustments { $0.gainDecibels = -200 }
        #expect(store.selectedAudioAdjustments.gainDecibels == -60)
    }

    /// Review focus: a schema-11 project with clip volumes plays at the same loudness. The mix's
    /// volume for each migrated clip equals its old volume, fades ramp to and from that gain, and
    /// master gain multiplies on top.
    @MainActor
    @Test func migratedClipsMixAtTheirOldVolume() async throws {
        let temp = try TempDirectory()
        let movie = try await writeTestMovie(to: temp.url.appendingPathComponent("P1107158.MOV"), frames: 240, width: 160, height: 90, withAudio: true)
        var project = try document.project(from: schema11Project(url: movie.path))

        func mix(_ project: EditorProject) async throws -> AVAudioMixInputParameters {
            let result = await TimelineCompositionService.shared.makePlayerItem(
                clips: project.timelineClips, media: project.media,
                audioAdjustmentsByClipID: project.audioAdjustmentsByClipID, quality: .export,
                sequenceFrameRate: project.sequenceFrameRate, masterGainDecibels: project.masterGainDecibels
            )
            let item = try #require(result.playerItem)
            return try #require(item.audioMix?.inputParameters.first)
        }
        let rate = project.sequenceFrameRate
        func seconds(_ frame: Int64) -> CMTime { rate.time(ofFrame: frame) }

        let parameters = try await mix(project)
        // Clip 1 (volume 0.5, 0.5 s fade in, 0.25 s fade out) holds 0.5 mid-clip.
        #expect(abs(mixVolume(parameters, at: seconds(24)) - 0.5) < 0.01)
        #expect(mixVolume(parameters, at: .zero) < 0.01, "The fade starts from silence")
        let fadeInMidpoint = CMTime(seconds: 0.25, preferredTimescale: 24000)
        #expect(abs(mixVolume(parameters, at: fadeInMidpoint) - 0.25) < 0.01, "The fade ramps to the clip's gain")
        // Clip 2 (volume 1) and clip 3 (volume 0).
        #expect(abs(mixVolume(parameters, at: seconds(72)) - 1.0) < 0.01)
        #expect(mixVolume(parameters, at: seconds(120)) < 0.01)

        // Master gain multiplies with clip gain: +6.02 dB on a −6.02 dB clip is unity.
        project.masterGainDecibels = 6.0206
        let boosted = try await mix(project)
        #expect(abs(mixVolume(boosted, at: seconds(24)) - 1.0) < 0.01)
        #expect(abs(mixVolume(boosted, at: seconds(72)) - 2.0) < 0.01, "Gain above 0 dB amplifies")
        #expect(mixVolume(boosted, at: seconds(120)) < 0.01, "A silent clip stays silent")
    }

    /// The volume the mix applies at `time`, interpolating inside a ramp.
    private func mixVolume(_ parameters: AVAudioMixInputParameters, at time: CMTime) -> Double {
        var start: Float = 0, end: Float = 0
        var range = CMTimeRange.zero
        guard parameters.getVolumeRamp(for: time, startVolume: &start, endVolume: &end, timeRange: &range) else { return .nan }
        guard range.duration > .zero, range.duration.isNumeric else { return Double(start) }
        let progress = min(1, max(0, (time - range.start).seconds / range.duration.seconds))
        return Double(start) + (Double(end) - Double(start)) * progress
    }
}
