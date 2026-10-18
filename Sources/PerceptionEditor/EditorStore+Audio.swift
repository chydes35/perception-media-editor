import Foundation

/// One clip's share of the timeline level analysis.
struct AudioAnalysisInput: Hashable, Sendable {
    var clipID: UUID
    var url: URL
    /// The clip's source span, in seconds of file time.
    var sourceRange: ClosedRange<Double>
    /// Where the clip starts and ends on the timeline, in seconds.
    var timelineStart: Double
    var timelineEnd: Double
    /// Clip gain plus master gain.
    var gainDecibels: Double

    var key: AudioAnalysisKey { AudioAnalysisKey(url: url, sourceRange: sourceRange, gainDecibels: gainDecibels) }
}

struct AudioAnalysisKey: Hashable, Sendable {
    var url: URL
    var sourceRange: ClosedRange<Double>
    var gainDecibels: Double
}

extension EditorStore {
    /// Why the Audio screen shows an empty state; nil when there is something to measure.
    enum AudioEmptyReason: Equatable {
        /// The timeline has no clips.
        case noClips
        /// Every clip's media is offline or gone from the project.
        case offline
        /// The last analysis found no readable audio in any clip.
        case noAudio
    }

    var audioEmptyReason: AudioEmptyReason? {
        let clips = project.timelineClips
        guard !clips.isEmpty else { return .noClips }
        let online = clips.contains { clip in timelineAsset(for: clip).map { !isMissing($0) } ?? false }
        guard online else { return .offline }
        if let counts = audioAnalysisCounts, counts.measured == 0, counts.withoutAudio > 0 { return .noAudio }
        return nil
    }

    /// Clips that would be heard (enabled, not muted) but whose media is offline or gone, so the
    /// analysis could not measure them.
    var audioOfflineClipCount: Int {
        project.timelineClips.filter { clip in
            clip.isEnabled && !clip.isMuted && (timelineAsset(for: clip).map(isMissing) ?? true)
        }.count
    }

    /// Clips that are heard: enabled, not muted, online, and with clip and master gain above the
    /// silent floor. Muted or silent clips cannot clip, so they are not read.
    func audioAnalysisInputs() -> [AudioAnalysisInput] {
        let master = project.masterGainDecibels
        guard master > ClipAudioAdjustments.minimumGainDecibels else { return [] }
        let rate = project.sequenceFrameRate
        return project.timelineClips.compactMap { clip in
            guard clip.isEnabled, !clip.isMuted,
                  let asset = timelineAsset(for: clip), !isMissing(asset) else { return nil }
            let gain = (project.audioAdjustmentsByClipID[clip.id] ?? .neutral).gainDecibels
            guard gain > ClipAudioAdjustments.minimumGainDecibels else { return nil }
            let start = project.timelineStartSeconds(of: clip)
            return AudioAnalysisInput(
                clipID: clip.id,
                url: asset.url,
                sourceRange: clip.sourceStartSeconds ... clip.sourceStartSeconds + clip.durationSeconds,
                timelineStart: start,
                timelineEnd: start + rate.seconds(ofFrames: project.timelineFrames(of: clip)),
                gainDecibels: gain + master
            )
        }
    }

    /// Analyzes every heard clip with its clip gain plus the master gain, one clip at a time and off
    /// the main actor (the analyzer reads on a utility queue), then publishes the merged result in
    /// timeline time: the loudest peak and every clipped spot. A newer refresh or an edit cancels it.
    func refreshAudioLevels() async {
        audioLevelsDebounceTask?.cancel()
        audioLevelsDebounceTask = nil
        audioLevelsTask?.cancel()
        let inputs = audioAnalysisInputs()
        let provider = audioLevelProvider
        let generation = projectGeneration
        if audioLevelsCacheGeneration != generation {
            audioLevelsCache = [:]
            audioLevelsCacheGeneration = generation
        }
        audioLevelsInputs = inputs
        let task = Task { [weak self] in
            guard let self else { return }
            await self.analyzeAudio(inputs, provider: provider, generation: generation)
        }
        audioLevelsTask = task
        await task.value
    }

    private func analyzeAudio(
        _ inputs: [AudioAnalysisInput],
        provider: @Sendable (URL, ClosedRange<Double>?, Double) async throws -> AudioLevels,
        generation: UUID
    ) async {
        guard !inputs.isEmpty else {
            audioLevels = nil
            audioAnalysisCounts = project.timelineClips.isEmpty ? nil : (0, 0)
            isAnalyzingAudio = false
            return
        }
        isAnalyzingAudio = true
        var results: [(AudioAnalysisInput, AudioLevels)] = []
        var withoutAudio = 0
        for input in inputs {
            if Task.isCancelled { return }
            if let cached = audioLevelsCache[input.key] {
                results.append((input, cached))
                continue
            }
            do {
                let levels = try await provider(input.url, input.sourceRange, input.gainDecibels)
                if audioLevelsCache.count >= 128 { audioLevelsCache = [:] }
                audioLevelsCache[input.key] = levels
                results.append((input, levels))
            } catch is CancellationError {
                return
            } catch {
                // No audio track, or unreadable: nothing of this clip can clip.
                withoutAudio += 1
            }
        }
        guard !Task.isCancelled, generation == projectGeneration else { return }
        audioLevels = results.isEmpty ? nil : Self.timelineLevels(results)
        audioAnalysisCounts = (results.count, withoutAudio)
        isAnalyzingAudio = false
    }

    /// Maps each clip's clipped spots from file time into timeline time (clamped to the clip),
    /// sorts and merges spots closer than the analyzer's merge gap; the peak is the loudest clip's.
    static func timelineLevels(_ results: [(AudioAnalysisInput, AudioLevels)]) -> AudioLevels {
        var ranges: [ClosedRange<Double>] = []
        for (input, levels) in results {
            for range in levels.clippedRanges {
                let lower = max(range.lowerBound, input.sourceRange.lowerBound)
                let upper = min(range.upperBound, input.sourceRange.upperBound)
                guard lower <= upper else { continue }
                let offset = input.timelineStart - input.sourceRange.lowerBound
                let start = lower + offset
                let end = min(upper + offset, input.timelineEnd)
                guard start <= end else { continue }
                ranges.append(start ... end)
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound - last.upperBound <= AudioLevelAnalyzer.mergeGap {
                merged[merged.count - 1] = last.lowerBound ... max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        let peak = results.map(\.1.peakDecibels).max() ?? AudioLevelAnalyzer.floorDecibels
        return AudioLevels(peakDecibels: peak, clippedRanges: merged)
    }

    /// Re-analyzes shortly after an edit while the Audio screen is shown. The running analysis is
    /// cancelled at once; a slider drag collapses into one analysis after it settles. Inputs that
    /// match the current result are skipped.
    func scheduleAudioLevelRefresh() {
        guard workspace == .videoAudio else { return }
        let inputs = audioAnalysisInputs()
        if inputs == audioLevelsInputs { return }
        audioLevelsTask?.cancel()
        audioLevelsDebounceTask?.cancel()
        audioLevelsDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.workspace == .videoAudio else { return }
            self.audioLevelsDebounceTask = nil
            await self.refreshAudioLevels()
        }
    }

    /// Moves the playhead to the start of the next clipped spot after it, wrapping to the first.
    func jumpToNextClippedSpot() {
        guard let ranges = audioLevels?.clippedRanges, let first = ranges.first else { return }
        // Seeks land on whole frames, so a spot within half a frame of the playhead counts as here.
        let tolerance = project.sequenceFrameRate.frameSeconds / 2
        let position = timelinePlaybackPositionSeconds
        let target = ranges.first { $0.lowerBound > position + tolerance } ?? first
        seekTimeline(to: target.lowerBound)
    }

    /// Master gain for the whole mix, clamped to −60…+24 dB (NaN ignored). Rebuilds the preview mix
    /// and, on the Audio screen, re-measures the clipped spots.
    func setMasterGainDecibels(_ decibels: Double) {
        guard decibels.isFinite else { return }
        let clamped = min(ClipAudioAdjustments.maximumGainDecibels, max(ClipAudioAdjustments.minimumGainDecibels, decibels))
        guard clamped != project.masterGainDecibels else { return }
        project.masterGainDecibels = clamped
        rebuildTimelinePlayback()
        statusMessage = "Master gain \(String(format: "%+.1f dB", clamped))"
    }

    /// Entering the Audio screen shows the timeline (its transport and meters need timeline
    /// playback, keeping the play state), starts the meters and measures the clips; leaving stops both.
    func updateAudioScreen(enteringFrom previous: Workspace) {
        if workspace == .videoAudio {
            guard previous != .videoAudio else { return }
            if let measured = audioLevelsCacheGeneration, measured != projectGeneration {
                // Another project was opened since the last analysis: show nothing stale.
                audioLevels = nil
                audioAnalysisCounts = nil
                audioLevelsInputs = nil
            }
            if !project.timelineClips.isEmpty, !isTimelinePlayback {
                let wasPlaying = isVideoPlaying
                if let clip = selectedTimelineClip { selectedVideoAssetID = clip.assetID }
                needsPlaybackRefresh = false
                rebuildTimelinePlayback(
                    autoplay: wasPlaying,
                    seekTo: selectedTimelineClip.map(project.timelineStartSeconds(of:)) ?? 0
                )
            }
            if audioEmptyReason == nil || audioEmptyReason == .noAudio {
                audioMeterModel.start { [weak self] in self?.isVideoPlaying ?? false }
            }
            scheduleAudioLevelRefresh()
        } else if previous == .videoAudio {
            audioMeterModel.stop()
            audioLevelsDebounceTask?.cancel()
            audioLevelsDebounceTask = nil
            audioLevelsTask?.cancel()
            audioLevelsTask = nil
            if isAnalyzingAudio {
                // The result is incomplete; measure again on return.
                isAnalyzingAudio = false
                audioLevelsInputs = nil
            }
        }
    }
}
