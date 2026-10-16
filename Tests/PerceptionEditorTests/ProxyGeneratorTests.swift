// Tests/PerceptionEditorTests/ProxyGeneratorTests.swift
@preconcurrency import AVFoundation
import Foundation
import Synchronization
import Testing
import simd
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

    /// Proxies made before the full-range fix are too bright, so their keys must not match any more.
    @Test func keyChangesWithTheProxyFormatVersion() throws {
        let temp = try TempDirectory()
        let url = try temp.file("P1.MOV", bytes: 3_000_000, seed: 7)
        #expect(ProxyFingerprint.formatVersion >= 2)
        #expect(try ProxyFingerprint.key(for: url, formatVersion: 1) != ProxyFingerprint.key(for: url))
        #expect(try ProxyFingerprint.key(for: url, formatVersion: ProxyFingerprint.formatVersion) == ProxyFingerprint.key(for: url))
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
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("P1.MOV"), frames: 24)
        let sourceBytes = try Data(contentsOf: source)
        let destination = temp.url.appendingPathComponent("proxy.mov")

        let info = try await ProxyGenerator.generate(
            source: source, destination: destination, maximumSize: CGSize(width: 320, height: 180)
        )

        #expect(info.frameCount == 24)
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

    /// The S5 records V-Log in full range. AVFoundation's own full-to-video-range conversion only adds 64
    /// to luma, so a proxy made from `x422` reads plays about 17% brighter than the original and clips
    /// above original code 876. The proxy must show the original's colors.
    @Test func fullRangeSourceProxyShowsTheOriginalsColors() async throws {
        let temp = try TempDirectory()
        guard let source = try await writeFullRangeTestMovie(to: temp.url.appendingPathComponent("VLOG.MOV")) else {
            Issue.record("This machine cannot encode a full-range 10-bit HEVC fixture")
            return
        }
        let sourceFormat = try await AVURLAsset(url: source).loadTracks(withMediaType: .video)[0].load(.formatDescriptions)[0]
        try #require(CMFormatDescriptionGetExtension(sourceFormat, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true)

        let destination = temp.url.appendingPathComponent("proxy.mov")
        _ = try await ProxyGenerator.generate(source: source, destination: destination)

        let original = try await decodedRGBGrid(source)
        let proxy = try await decodedRGBGrid(destination)
        // A ProRes proxy cannot hold colors outside 0…1, so compare what both can show.
        let clamp = { (v: SIMD3<Float>) in simd_clamp(v, SIMD3(repeating: 0), SIMD3(repeating: 1)) }
        let worst = zip(original, proxy).map { abs(clamp($0) - clamp($1)).max() }.max() ?? .infinity
        #expect(worst <= 4.0 / 1023, "Proxy colors differ from the original by up to \(worst * 1023) of 1023 levels")
    }

    @Test func fullRangeProxyIsTaggedVideoRange() async throws {
        let temp = try TempDirectory()
        guard let source = try await writeFullRangeTestMovie(to: temp.url.appendingPathComponent("VLOG.MOV")) else {
            Issue.record("This machine cannot encode a full-range 10-bit HEVC fixture")
            return
        }
        let destination = temp.url.appendingPathComponent("proxy.mov")
        _ = try await ProxyGenerator.generate(source: source, destination: destination)
        let format = try await AVURLAsset(url: destination).loadTracks(withMediaType: .video)[0].load(.formatDescriptions)[0]
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_AppleProRes422Proxy)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool != true)
    }

    @Test func cancellationLeavesNoFiles() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("P1.MOV"), frames: 24, width: 160, height: 90)
        let destination = temp.url.appendingPathComponent("proxy.mov")
        let partial = temp.url.appendingPathComponent("proxy.partial.mov")
        // The fault holds the job mid-flight after one frame, so the cancel is deterministic.
        let faults = ProxyGenerationFaults(stallAfterFrames: 1, watchdogInterval: nil)
        let job = Task { try await ProxyGenerator.generate(source: source, destination: destination, faults: faults) }
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: partial.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(FileManager.default.fileExists(atPath: partial.path), "The job must be in flight before it is cancelled")
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
                to: temp.url.appendingPathComponent("S\(index).MOV"), frames: 24, width: 160, height: 90
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
            #expect(frames == Array(repeating: 24, count: 12))
            #expect(ticked, "Unrelated async work must still get a thread")
        case .failed(let reason):
            Issue.record("A concurrent generation failed: \(reason)")
        case .timedOut:
            Issue.record("12 concurrent generations hung for 30 s: the cooperative pool is starved")
        }
    }

    /// Runs a generation that is cancelled if it has not finished by `deadline`; a cancellation
    /// therefore means the job hung.
    private func generate(
        _ source: URL, to destination: URL, faults: ProxyGenerationFaults, deadline: Duration = .seconds(8)
    ) async -> (error: (any Error)?, seconds: Double) {
        let clock = ContinuousClock()
        let started = clock.now
        let job = Task {
            try await ProxyGenerator.generate(
                source: source, destination: destination, maximumSize: CGSize(width: 320, height: 180), faults: faults
            )
        }
        let watchdog = Task { try await Task.sleep(for: deadline); job.cancel() }
        defer { watchdog.cancel() }
        do {
            _ = try await job.value
            return (nil, (clock.now - started) / .seconds(1))
        } catch {
            return (error, (clock.now - started) / .seconds(1))
        }
    }

    private func leftovers(_ temp: TempDirectory) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temp.url.path).filter { $0.hasPrefix("proxy") }
    }

    /// The loop stops when the input stops asking for data; if the writer failed meanwhile, nothing
    /// would ever call back. The status check after the loop must end the job.
    @Test func writerFailureWhenTheLoopStopsFailsTheJob() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("S.MOV"), frames: 24, width: 160, height: 90)
        let faults = ProxyGenerationFaults(
            stallAfterFrames: 1, watchdogInterval: nil, pipelineFailure: { .writeFailed("injected") }
        )
        let outcome = await generate(source, to: temp.url.appendingPathComponent("proxy.mov"), faults: faults)
        #expect(outcome.error as? ProxyError == .writeFailed("injected"), "Got \(String(describing: outcome.error))")
        #expect(outcome.seconds < 5)
        #expect(try leftovers(temp).isEmpty, "No partial file may be left behind")
    }

    /// If the writer fails after the loop has already yielded, only the watchdog can notice.
    @Test func watchdogFailsAJobWhoseWriterFailedWhileStalled() async throws {
        let temp = try TempDirectory()
        let source = try await writeTestMovie(to: temp.url.appendingPathComponent("S.MOV"), frames: 24, width: 160, height: 90)
        let checks = Mutex(0)
        let faults = ProxyGenerationFaults(stallAfterFrames: 1, pipelineFailure: {
            // Healthy when the loop stops; failed by the time the watchdog looks.
            checks.withLock { count in count += 1; return count == 1 ? nil : .writeFailed("injected") }
        })
        let outcome = await generate(source, to: temp.url.appendingPathComponent("proxy.mov"), faults: faults)
        #expect(outcome.error as? ProxyError == .writeFailed("injected"), "Got \(String(describing: outcome.error))")
        #expect(outcome.seconds < 5)
        #expect(try leftovers(temp).isEmpty, "No partial file may be left behind")
    }

    @Test func pipelineFailureReportsTheFailedSide() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(ProxyGenerator.pipelineFailure(readerStatus: .reading, readerError: nil, writerStatus: .writing, writerError: nil) == nil)
        #expect(ProxyGenerator.pipelineFailure(readerStatus: .reading, readerError: nil, writerStatus: .failed, writerError: error)
            == .writeFailed("boom"))
        #expect(ProxyGenerator.pipelineFailure(readerStatus: .failed, readerError: error, writerStatus: .writing, writerError: nil)
            == .readFailed("boom"))
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
