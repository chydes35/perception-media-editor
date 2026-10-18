import AppKit
import Metal
import SwiftUI

/// Turns the scope tap's captures into images for the scope panel. Analysis runs on its own
/// queue with its own command queue; captures that arrive while one is being analyzed collapse
/// into the newest, so the scopes never queue up behind playback.
@MainActor
final class ScopeModel: ObservableObject {
    @Published private(set) var waveform: CGImage?
    @Published private(set) var vectorscope: CGImage?
    @Published private(set) var histogram = HistogramData.empty
    /// GPU time of the last analysis, and how often the images are updating.
    @Published private(set) var gpuMilliseconds = 0.0
    @Published private(set) var updatesPerSecond = 0.0
    @Published var waveformMode = WaveformMode.luma

    private let worker = ScopeWorker()
    private var recentUpdates: [TimeInterval] = []

    func start(tap: ScopeTap = .shared) {
        worker.mode = waveformMode
        tap.setListener { [worker, weak self] texture in
            worker.analyze(texture) { analysis in
                Task { @MainActor in self?.show(analysis) }
            }
        }
    }

    func stop(tap: ScopeTap = .shared) {
        tap.setListener(nil)
        waveform = nil
        vectorscope = nil
        histogram = .empty
        recentUpdates = []
        updatesPerSecond = 0
    }

    func modeChanged() {
        worker.mode = waveformMode
        // A paused frame is not rendered again, so analyze the last capture in the new mode.
        if let latest = ScopeTap.shared.latest {
            worker.analyze(latest) { [weak self] analysis in Task { @MainActor in self?.show(analysis) } }
        }
    }

    private func show(_ analysis: ScopeAnalysis) {
        waveform = analysis.waveformImage
        vectorscope = analysis.vectorscopeImage
        histogram = analysis.histogram
        gpuMilliseconds = analysis.gpuMilliseconds
        let now = ProcessInfo.processInfo.systemUptime
        recentUpdates = recentUpdates.filter { now - $0 < 1 } + [now]
        updatesPerSecond = Double(recentUpdates.count)
    }
}

/// Analyzes captures one at a time, off the main actor. While one is analyzed, only the newest
/// capture waits; older ones are skipped.
final class ScopeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PerceptionEditor.scopes", qos: .userInitiated)
    private let lock = NSLock()
    private var running = false
    private var pending: (texture: MTLTexture, completion: @Sendable (ScopeAnalysis) -> Void)?
    private var renderer: ScopeRenderer?
    private var currentMode = WaveformMode.luma

    var mode: WaveformMode {
        get { lock.withLock { currentMode } }
        set { lock.withLock { currentMode = newValue } }
    }

    func analyze(_ texture: MTLTexture, completion: @escaping @Sendable (ScopeAnalysis) -> Void) {
        let start = lock.withLock { () -> Bool in
            pending = (texture, completion)
            if running { return false }
            running = true
            return true
        }
        if start { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let job = lock.withLock { () -> (MTLTexture, @Sendable (ScopeAnalysis) -> Void, WaveformMode)? in
                guard let next = pending else {
                    running = false
                    return nil
                }
                pending = nil
                return (next.texture, next.completion, currentMode)
            }
            guard let (texture, completion, mode) = job else { return }
            if renderer == nil { renderer = try? ScopeRenderer() }
            if let analysis = try? renderer?.analyze(texture, mode: mode) { completion(analysis) }
        }
    }
}

/// The scope panel under the viewer: waveform (luma or RGB parade) and vectorscope.
struct ScopePanel: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject var model: ScopeModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Picker("Waveform", selection: $model.waveformMode) {
                    ForEach(WaveformMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: model.waveformMode) { model.modeChanged() }

                Picker("Measure", selection: $store.scopeSource) {
                    ForEach(ScopeTap.Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .help("Output measures the graded picture. Source measures the decoded code values as recorded, before the input LUT and grade.")

                Spacer()
                Text(String(format: "%.0f Hz · %.2f ms GPU", model.updatesPerSecond, model.gpuMilliseconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                ScopeImageView(image: model.waveform)
                    .aspectRatio(2, contentMode: .fit)
                ScopeImageView(image: model.vectorscope)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Shows a scope image through a layer, so updates at 15 Hz don't rebuild SwiftUI images.
struct ScopeImageView: NSViewRepresentable {
    var image: CGImage?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.contentsGravity = .resize
        view.layer?.magnificationFilter = .linear
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.contents = image
    }
}
