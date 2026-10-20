import Foundation
import Testing
@testable import PerceptionEditor

@MainActor
struct IngestFlowTests {
    private func makeCard(_ temp: TempDirectory, name: String = "card", dates: [String]) throws -> URL {
        for (index, date) in dates.enumerated() {
            try writeTestJPEG(
                to: try temp.subdirectory("\(name)/DCIM/100_PANA").appendingPathComponent("P10000\(index + 1).JPG"),
                captureDate: date
            )
        }
        return temp.url.appendingPathComponent(name)
    }

    private func waitForIngest(_ store: EditorStore) async throws {
        let deadline = Date().addingTimeInterval(TestDeadline.event)
        while store.ingest.isRunning || store.ingest == .idle {
            #expect(Date() < deadline, "Ingest did not finish")
            if Date() >= deadline { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func importingACardCreatesASavedShootReadyToCull() async throws {
        let temp = try TempDirectory()
        // Named out of capture order: P100001 was taken last.
        let card = try makeCard(temp, dates: ["2026:06:14 14:30:00", "2026:06:14 14:10:00", "2026:06:14 14:20:00"])
        let shoots = try temp.subdirectory("Shoots")
        let backup = try temp.subdirectory("Backup")
        let store = EditorStore()

        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "Test Shoot", date: Date(timeIntervalSince1970: 1_790_000_000), root: shoots),
            backupRoot: backup
        ))
        try await waitForIngest(store)

        guard case .finished(let summary) = store.ingest else {
            Issue.record("Expected a finished import, got \(store.ingest)")
            return
        }
        #expect(summary.copied == 3)
        #expect(summary.failures.isEmpty)
        #expect(summary.backup == .completed(copied: 3, alreadyPresent: 0))

        // The shoot folder, project file, originals, and backup all exist.
        let projectURL = try #require(store.projectURL)
        #expect(projectURL.lastPathComponent == "Test Shoot.pmedit")
        #expect(projectURL.deletingLastPathComponent().lastPathComponent.hasSuffix(" Test Shoot"))
        #expect(FileManager.default.fileExists(atPath: projectURL.path))
        let originals = try #require(store.originalsFolder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: originals.path).count == 3)
        let backedUp = backup.appendingPathComponent(projectURL.deletingLastPathComponent().lastPathComponent + "/Originals")
        #expect(try FileManager.default.contentsOfDirectory(atPath: backedUp.path).count == 3)

        // The project already holds the photos, with metadata, in capture order.
        #expect(store.project.name == "Test Shoot")
        let photos = store.allPhotos
        #expect(photos.count == 3)
        #expect(photos.map(\.filename) == ["P100002.JPG", "P100003.JPG", "P100001.JPG"])
        #expect(photos.allSatisfy { $0.pixelWidth == 400 && $0.pixelHeight == 300 && $0.captureDate != nil })
        #expect(photos.allSatisfy { $0.url.path.hasPrefix(originals.path) })

        // It was saved to disk, so nothing depends on remembering to press ⌘S.
        let saved = try ProjectDocument().load(from: projectURL)
        #expect(saved.media.count == 3)
        #expect(!store.hasUnsavedChanges)

        // Starting to cull selects the first photo in capture order and shows a preview.
        store.beginCullingAfterImport()
        #expect(store.workspace == .cull)
        #expect(store.selectedAssetID == photos[0].id)
        let deadline = Date().addingTimeInterval(TestDeadline.event)
        while store.loupeImage == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.loupeImage != nil)
    }

    @Test func addingAnotherCardToTheShootSkipsWhatIsAlreadyThere() async throws {
        let temp = try TempDirectory()
        let first = try makeCard(temp, name: "card1", dates: ["2026:06:14 14:10:00", "2026:06:14 14:20:00"])
        let shoots = try temp.subdirectory("Shoots")
        let store = EditorStore()

        store.startIngest(ImportRequest(
            source: first,
            destination: .newShoot(name: "Two Cards", date: Date(timeIntervalSince1970: 1_790_000_000), root: shoots),
            backupRoot: nil
        ))
        try await waitForIngest(store)
        #expect(store.allPhotos.count == 2)

        // A second card whose first file is identical to one already imported.
        let second = temp.url.appendingPathComponent("card2/DCIM/100_PANA")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: first.appendingPathComponent("DCIM/100_PANA/P100001.JPG"),
            to: second.appendingPathComponent("P100001.JPG")
        )
        try writeTestJPEG(to: second.appendingPathComponent("P100009.JPG"), captureDate: "2026:06:14 15:00:00")

        store.ingest = .idle
        store.startIngest(ImportRequest(
            source: temp.url.appendingPathComponent("card2"),
            destination: .currentShoot,
            backupRoot: nil
        ))
        try await waitForIngest(store)

        guard case .finished(let summary) = store.ingest else {
            Issue.record("Expected a finished import, got \(store.ingest)")
            return
        }
        #expect(summary.copied == 1)
        #expect(summary.alreadyPresent == 1)
        #expect(store.allPhotos.count == 3)
        #expect(Set(store.allPhotos.map(\.filename)).count == 3)
    }

    @Test func anEmptyFolderReportsAClearFailure() async throws {
        let temp = try TempDirectory()
        let empty = try temp.subdirectory("empty")
        let store = EditorStore()

        store.startIngest(ImportRequest(
            source: empty,
            destination: .newShoot(name: "Nothing", date: .now, root: try temp.subdirectory("Shoots")),
            backupRoot: nil
        ))
        try await waitForIngest(store)

        guard case .failed(let message) = store.ingest else {
            Issue.record("Expected a failure, got \(store.ingest)")
            return
        }
        #expect(message.contains("No photos"))
    }

    @Test func aDisconnectedShootsDriveFailsBeforeCreatingAnything() async throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp, dates: ["2026:06:14 14:10:00"])
        let store = EditorStore()
        let missing = "NoSuchDrive-\(UUID().uuidString)"

        store.startIngest(ImportRequest(
            source: card,
            destination: .newShoot(name: "X", date: .now, root: URL(fileURLWithPath: "/Volumes/\(missing)/Shoots")),
            backupRoot: nil
        ))

        guard case .failed(let message) = store.ingest else {
            Issue.record("Expected a failure, got \(store.ingest)")
            return
        }
        #expect(message.contains(missing))
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(missing)"))
        #expect(store.projectURL == nil)
    }
}
