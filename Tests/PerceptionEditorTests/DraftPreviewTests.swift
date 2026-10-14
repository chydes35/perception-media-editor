import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PerceptionEditor

/// Plays back a script: each preview call reports whether it was a draft, and the calls are counted.
private actor DraftScript {
    private var answers: [Bool]
    private(set) var calls = 0
    private let image: RenderedImage
    init(answers: [Bool], image: RenderedImage) { self.answers = answers; self.image = image }
    func render() -> (RenderedImage?, PhotoPreviewResult?) {
        calls += 1
        let draft = answers.isEmpty ? false : answers.removeFirst()
        return (image, PhotoPreviewResult(edited: image, histogram: .empty, isDraft: draft))
    }
}

@Suite(.serialized)
@MainActor
struct DraftPreviewTests {
    private func makeStore(answers: [Bool], delay: Duration) throws -> (EditorStore, DraftScript, TempDirectory) {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("photo.jpg"))
        let cgSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = RenderedImage(cgImage: try #require(CGImageSourceCreateImageAtIndex(cgSource, 0, nil)))
        let script = DraftScript(answers: answers, image: image)
        let store = EditorStore(previewRenderOperation: { _, _, _, _ in await script.render() })
        store.draftSettleDelay = delay
        let projectURL = temp.url.appendingPathComponent("p.pmedit")
        try ProjectDocument().save(EditorProject(name: "P", media: [MediaAsset(url: source)]), to: projectURL)
        try store.loadProject(from: projectURL)
        store.workspace = .photo
        return (store, script, temp)
    }

    private func settle(_ store: EditorStore) async throws {
        let deadline = Date().addingTimeInterval(30)
        while store.isRenderingPreview, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aDraftIsFollowedByOneExactRenderOnceInputRests() async throws {
        let (store, script, temp) = try makeStore(answers: [true, false], delay: .milliseconds(40))
        defer { withExtendedLifetime(temp) {} }
        try await settle(store)
        try await Task.sleep(for: .milliseconds(400))
        try await settle(store)
        #expect(await script.calls == 2)          // the draft, then the exact render
        try await Task.sleep(for: .milliseconds(200))
        #expect(await script.calls == 2)          // and nothing after it
        store.resetToEmptyProject(named: "Done")
    }

    @Test func newInputWhileWaitingCancelsTheExactRenderUntilInputRestsAgain() async throws {
        let (store, script, temp) = try makeStore(answers: [true, true, false], delay: .milliseconds(300))
        defer { withExtendedLifetime(temp) {} }
        try await settle(store)
        #expect(await script.calls == 1)
        store.refreshPreview()                    // the slider moved again before the delay passed
        try await settle(store)
        #expect(await script.calls == 2)
        try await Task.sleep(for: .milliseconds(900))
        try await settle(store)
        #expect(await script.calls == 3)          // one exact render, after the second rest only
        try await Task.sleep(for: .milliseconds(400))
        #expect(await script.calls == 3)
        store.resetToEmptyProject(named: "Done")
    }

    /// The next render is exact already (for example the slider returned to a value whose decode is
    /// cached), so the pending exact render from the earlier draft must not fire as well.
    @Test func inputThatRendersExactlyCancelsTheEarlierDraftsPendingRender() async throws {
        let (store, script, temp) = try makeStore(answers: [true, false], delay: .milliseconds(300))
        defer { withExtendedLifetime(temp) {} }
        try await settle(store)
        #expect(await script.calls == 1)
        store.refreshPreview()
        try await settle(store)
        #expect(await script.calls == 2)
        try await Task.sleep(for: .milliseconds(800))
        #expect(await script.calls == 2)
        store.resetToEmptyProject(named: "Done")
    }

    @Test func resettingTheProjectCancelsAPendingExactRender() async throws {
        let (store, script, temp) = try makeStore(answers: [true, false], delay: .milliseconds(150))
        defer { withExtendedLifetime(temp) {} }
        try await settle(store)
        store.resetToEmptyProject(named: "Empty")
        try await Task.sleep(for: .milliseconds(500))
        #expect(await script.calls == 1)
    }

    @Test func aNonRawFileNeverProducesADraft() async throws {
        let temp = try TempDirectory()
        let source = try writeTestJPEG(to: temp.url.appendingPathComponent("photo.jpg"), width: 600, height: 400)
        var adjustments = PhotoAdjustments.neutral
        adjustments.raw.temperature = 4200
        let result = try #require(await PhotoRenderer().preview(url: source, adjustments: adjustments, allowsDraft: true))
        #expect(!result.isDraft)
    }
}
