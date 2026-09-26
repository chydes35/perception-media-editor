@preconcurrency import AVFoundation
import CryptoKit
import Foundation

actor AudioWaveformService {
    static let shared = AudioWaveformService()

    private let directory: URL
    private let fileManager: FileManager
    private var memory: [String: [Float]] = [:]

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager

        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directory = applicationSupport
                .appendingPathComponent("Perception Media Editor", isDirectory: true)
                .appendingPathComponent("Waveform Cache", isDirectory: true)
        }

        try? fileManager.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    func samples(for url: URL, sampleCount: Int = 160) async -> [Float] {
        let count = max(16, sampleCount)
        let key = cacheKey(for: url, sampleCount: count)

        if let cached = memory[key] { return cached }

        let cacheURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Float].self, from: data) {
            memory[key] = cached
            return cached
        }

        let extracted = await Task.detached(priority: .utility) {
            await Self.extractSamples(from: url, sampleCount: count)
        }.value

        memory[key] = extracted
        if let data = try? JSONEncoder().encode(extracted) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return extracted
    }

    func invalidate(url: URL) {
        let prefix = cachePrefix(for: url)
        memory = memory.filter { !$0.key.hasPrefix(prefix) }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for cacheURL in contents where cacheURL.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    private func cacheKey(for url: URL, sampleCount: Int) -> String {
        cachePrefix(for: url) + "-\(sampleCount)"
    }

    private func cachePrefix(for url: URL) -> String {
        let modificationDate = (try? url.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate?.timeIntervalSinceReferenceDate) ?? 0
        let input = Data("\(url.path)|\(modificationDate)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func extractSamples(from url: URL, sampleCount: Int) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let durationTime = try? await asset.load(.duration),
              let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first,
              let reader = try? AVAssetReader(asset: asset) else {
            return []
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 8_000
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let duration = durationTime.seconds
        guard duration.isFinite, duration > 0 else { return [] }
        var peaks = [Float](repeating: 0, count: sampleCount)

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var lengthAtOffset = 0
            var totalLength = 0
            var dataPointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(
                blockBuffer,
                atOffset: 0,
                lengthAtOffsetOut: &lengthAtOffset,
                totalLengthOut: &totalLength,
                dataPointerOut: &dataPointer
            )
            guard status == kCMBlockBufferNoErr, let dataPointer, totalLength > 0 else { continue }

            let valueCount = totalLength / MemoryLayout<Float>.size
            guard valueCount > 0 else { continue }
            let startSeconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            let bufferDuration = CMSampleBufferGetDuration(sampleBuffer).seconds
            let safeDuration = bufferDuration.isFinite && bufferDuration > 0
                ? bufferDuration
                : Double(valueCount) / 8_000

            dataPointer.withMemoryRebound(to: Float.self, capacity: valueCount) { pointer in
                for index in 0..<valueCount {
                    let fraction = valueCount > 1 ? Double(index) / Double(valueCount - 1) : 0
                    let seconds = startSeconds + safeDuration * fraction
                    let bucket = min(sampleCount - 1, max(0, Int(seconds / duration * Double(sampleCount))))
                    peaks[bucket] = max(peaks[bucket], abs(pointer[index]))
                }
            }
        }

        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return peaks }
        return peaks.map { min(1, sqrt($0 / maximum)) }
    }
}
