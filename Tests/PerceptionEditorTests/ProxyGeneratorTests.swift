// Tests/PerceptionEditorTests/ProxyGeneratorTests.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import PerceptionEditor

struct ProxyFingerprintTests {
    @Test func sameBytesAtDifferentPathsShareAKey() throws {
        let temp = try TempDirectory()
        let a = try temp.file("card/P1.MOV", bytes: 3_000_000, seed: 7)
        let b = temp.url.appendingPathComponent("shoot/P1.MOV")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: a, to: b)
        #expect(try ProxyFingerprint.key(for: a) == ProxyFingerprint.key(for: b))
    }

    @Test func changedTailChangesTheKey() throws {
        let temp = try TempDirectory()
        let url = try temp.file("P1.MOV", bytes: 3_000_000, seed: 7)
        let before = try ProxyFingerprint.key(for: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: 2_999_999)
        try handle.write(contentsOf: Data([0xAB]))
        try handle.close()
        #expect(try ProxyFingerprint.key(for: url) != before)
    }

    @Test func smallFilesAndMissingFiles() throws {
        let temp = try TempDirectory()
        let tiny = try temp.file("tiny.mov", bytes: 10, seed: 1)
        #expect(try ProxyFingerprint.key(for: tiny).count == 64)
        #expect(throws: (any Error).self) { try ProxyFingerprint.key(for: temp.url.appendingPathComponent("gone.mov")) }
    }
}

struct ProxyGeneratorTests {
    @Test func generationRunsAtUtilityQoS() {
        #expect(ProxyGenerator.workQoS == .utility, "Proxy generation is background work; it must not compete with editing")
    }

    @Test func sizeFitsInsideTheLimitWithEvenDimensionsAndNeverUpscales() {
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 3840, height: 2160)) == CGSize(width: 1920, height: 1080))
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 4096, height: 2160)) == CGSize(width: 1920, height: 1012))
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 2160, height: 3840)) == CGSize(width: 608, height: 1080))
        #expect(ProxyGenerator.proxySize(for: CGSize(width: 1280, height: 720)) == CGSize(width: 1280, height: 720))
    }

    @Test func proxyKeepsFramesTimingColorAndLeavesTheSourceUntouched() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("P1.MOV"), frames: 48)
        let sourceBytes = try Data(contentsOf: source)
        let destination = temp.url.appendingPathComponent("proxy.mov")

        let info = try await ProxyGenerator.generate(
            source: source, destination: destination, maximumSize: CGSize(width: 320, height: 180)
        )

        #expect(info.frameCount == 48)
        #expect(info.pixelWidth == 320 && info.pixelHeight == 180)
        #expect(try Data(contentsOf: source) == sourceBytes, "The original must never change")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("proxy.partial.mov").path))

        let sourceTrack = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)[0]
        let proxyTrack = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)[0]
        let sourceRange = try await sourceTrack.load(.timeRange)
        let proxyRange = try await proxyTrack.load(.timeRange)
        #expect(proxyRange.start == sourceRange.start)
        #expect(abs(proxyRange.duration.seconds - sourceRange.duration.seconds) < 1.0 / 24)

        let proxyFormat = try await proxyTrack.load(.formatDescriptions)[0]
        #expect(CMFormatDescriptionGetMediaSubType(proxyFormat) == kCMVideoCodecType_AppleProRes422Proxy)
        #expect(CMFormatDescriptionGetExtension(proxyFormat, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String))
        #expect(CMFormatDescriptionGetExtension(proxyFormat, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String))
    }

    @Test func cancellationLeavesNoFiles() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("P1.MOV"), frames: 240, width: 1920, height: 1080)
        let destination = temp.url.appendingPathComponent("proxy.mov")
        let job = Task { try await ProxyGenerator.generate(source: source, destination: destination) }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        await #expect(throws: CancellationError.self) { _ = try await job.value }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0.hasPrefix("proxy") }
        #expect(leftovers.isEmpty)
    }

    /// Blocking AVFoundation sample I/O must stay off the cooperative pool: with more jobs than
    /// pool threads, a blocked pool hangs every job and unrelated async work along with it.
    @Test(.timeLimit(.minutes(1)))
    func concurrentGenerationsDoNotStarveThePool() async throws {
        enum Child: Sendable { case frames(Int), tick }
        enum Outcome: Sendable { case finished(frames: [Int], ticked: Bool), failed(String), timedOut }

        let temp = try TempDirectory()
        var sources: [URL] = []
        for index in 0 ..< 12 {
            sources.append(try await writeTestMovie(
                to: temp.url.appendingPathComponent("S\(index).MOV"), frames: 48, width: 640, height: 360
            ))
        }
        let jobs = sources

        let outcome = await withTaskGroup(of: Outcome.self) { race -> Outcome in
            race.addTask {
                do {
                    return try await withThrowingTaskGroup(of: Child.self) { group -> Outcome in
                        for (index, source) in jobs.enumerated() {
                            group.addTask {
                                let info = try await ProxyGenerator.generate(
                                    source: source,
                                    destination: temp.url.appendingPathComponent("proxy-\(index).mov"),
                                    maximumSize: CGSize(width: 320, height: 180)
                                )
                                return .frames(info.frameCount)
                            }
                        }
                        group.addTask {
                            try await Task.sleep(for: .milliseconds(10))
                            return .tick
                        }
                        var frames: [Int] = []
                        var ticked = false
                        for try await child in group {
                            switch child {
                            case .frames(let count): frames.append(count)
                            case .tick: ticked = true
                            }
                        }
                        return .finished(frames: frames, ticked: ticked)
                    }
                } catch {
                    return .failed(String(describing: error))
                }
            }
            race.addTask {
                try? await Task.sleep(for: .seconds(30))
                return .timedOut
            }
            let first = await race.next() ?? .timedOut
            race.cancelAll()
            return first
        }

        switch outcome {
        case .finished(let frames, let ticked):
            #expect(frames == Array(repeating: 48, count: 12))
            #expect(ticked, "Unrelated async work must still get a thread")
        case .failed(let reason):
            Issue.record("A concurrent generation failed: \(reason)")
        case .timedOut:
            Issue.record("12 concurrent generations hung for 30 s: the cooperative pool is starved")
        }
    }

    @Test func fileWithoutVideoIsRejected() async throws {
        let temp = try TempDirectory()
        let junk = try temp.file("notes.mov", bytes: 4096, seed: 3)
        await #expect(throws: (any Error).self) {
            _ = try await ProxyGenerator.generate(source: junk, destination: temp.url.appendingPathComponent("proxy.mov"))
        }
        #expect(!FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("proxy.mov").path))
    }
}
