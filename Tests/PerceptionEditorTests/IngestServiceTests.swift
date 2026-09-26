import Foundation
import Testing
@testable import PerceptionEditor

struct IngestServiceTests {
    private let megabyte = 1024 * 1024

    private func makeCard(_ temp: TempDirectory) throws -> URL {
        try temp.file("card/DCIM/100_PANA/P1000001.RW2", bytes: 5 * megabyte + 123, seed: 1)
        try temp.file("card/DCIM/100_PANA/P1000002.RW2", bytes: 2 * megabyte, seed: 2)
        try temp.file("card/DCIM/100_PANA/P1000003.JPG", bytes: 300_000, seed: 3)
        return temp.url.appendingPathComponent("card")
    }

    private func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    // MARK: Scanning

    @Test func scanFindsOnlyMediaInPathOrder() throws {
        let temp = try TempDirectory()
        try temp.file("card/DCIM/100_PANA/P1000010.RW2", bytes: 10)
        try temp.file("card/DCIM/100_PANA/P1000002.RW2", bytes: 10)
        try temp.file("card/DCIM/100_PANA/P1000003.MOV", bytes: 10)
        try temp.file("card/DCIM/100_PANA/notes.txt", bytes: 10)
        try temp.file("card/DCIM/100_PANA/._P1000002.RW2", bytes: 10)

        let files = IngestService.scan(temp.url.appendingPathComponent("card"))

        #expect(files.map(\.url.lastPathComponent) == ["P1000002.RW2", "P1000003.MOV", "P1000010.RW2"])
        #expect(files.map(\.kind) == [.photo, .video, .photo])
    }

    @Test func kindsFollowFileType() {
        #expect(IngestService.kind(for: URL(fileURLWithPath: "/x/P1.RW2")) == .photo)
        #expect(IngestService.kind(for: URL(fileURLWithPath: "/x/P1.jpg")) == .photo)
        #expect(IngestService.kind(for: URL(fileURLWithPath: "/x/C1.MP4")) == .video)
        #expect(IngestService.kind(for: URL(fileURLWithPath: "/x/readme.txt")) == nil)
    }

    // MARK: Copying

    @Test func copiesVerifiesAndLeavesTheCardAlone() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = temp.url.appendingPathComponent("shoot/Originals")
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: stamp],
            ofItemAtPath: card.appendingPathComponent("DCIM/100_PANA/P1000002.RW2").path
        )
        let sourceBefore = try IngestService.sha256(of: card.appendingPathComponent("DCIM/100_PANA/P1000001.RW2"))

        let result = try IngestService.ingest(
            files: IngestService.scan(card),
            originals: originals,
            backupOriginals: nil
        )

        #expect(result.copiedCount == 3)
        #expect(result.alreadyPresentCount == 0)
        #expect(result.failures.isEmpty)
        #expect(names(in: originals) == ["P1000001.RW2", "P1000002.RW2", "P1000003.JPG"])

        for file in result.files {
            #expect(try IngestService.sha256(of: file.sourceURL) == IngestService.sha256(of: file.destinationURL))
        }
        // The card is untouched.
        #expect(try IngestService.sha256(of: card.appendingPathComponent("DCIM/100_PANA/P1000001.RW2")) == sourceBefore)
        // The original's timestamp carries over.
        let copiedDate = try originals.appendingPathComponent("P1000002.RW2")
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        #expect(abs(copiedDate!.timeIntervalSince(stamp)) < 1)
    }

    @Test func reimportingTheSameCardSkipsIdenticalFiles() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = temp.url.appendingPathComponent("shoot/Originals")
        let files = IngestService.scan(card)

        _ = try IngestService.ingest(files: files, originals: originals, backupOriginals: nil)
        let second = try IngestService.ingest(files: files, originals: originals, backupOriginals: nil)

        #expect(second.copiedCount == 0)
        #expect(second.alreadyPresentCount == 3)
        #expect(second.files.count == 3)
        #expect(names(in: originals).count == 3)
    }

    @Test func differentFileWithTheSameNameIsKeptAsASeparateCopy() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = try temp.subdirectory("shoot/Originals")
        // Same name and same size as the card's P1000002.RW2, different bytes.
        // Its timestamp differs from the card's, as two different photos' would.
        let existing = try temp.file(
            "shoot/Originals/P1000002.RW2", bytes: 2 * megabyte, seed: 99, modified: Date(timeIntervalSince1970: 1_600_000_000)
        )
        let existingHash = try IngestService.sha256(of: existing)

        let result = try IngestService.ingest(
            files: IngestService.scan(card),
            originals: originals,
            backupOriginals: nil
        )

        #expect(names(in: originals).contains("P1000002-1.RW2"))
        #expect(try IngestService.sha256(of: existing) == existingHash)
        #expect(result.files.first { $0.sourceURL.lastPathComponent == "P1000002.RW2" }?.destinationURL.lastPathComponent == "P1000002-1.RW2")
    }

    @Test func sameContentWithADifferentTimestampIsStillRecognisedAsAlreadyImported() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = temp.url.appendingPathComponent("shoot/Originals")
        let files = IngestService.scan(card)
        _ = try IngestService.ingest(files: files, originals: originals, backupOriginals: nil)

        // Something touched the copies (a sync tool, a restore), changing their timestamps.
        for name in names(in: originals) {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)],
                ofItemAtPath: originals.appendingPathComponent(name).path
            )
        }
        let again = try IngestService.ingest(files: files, originals: originals, backupOriginals: nil)

        #expect(again.copiedCount == 0)
        #expect(again.alreadyPresentCount == 3)
        #expect(names(in: originals).count == 3)
    }

    @Test func reimportedFilesAreStillMirroredToTheBackup() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = temp.url.appendingPathComponent("shoot/Originals")
        let backup = temp.url.appendingPathComponent("backup/Originals")
        let files = IngestService.scan(card)

        // First run without a backup, second run adds it: files recognised by timestamp
        // (no digest) must still be copied to the new backup.
        _ = try IngestService.ingest(files: files, originals: originals, backupOriginals: nil)
        let second = try IngestService.ingest(files: files, originals: originals, backupOriginals: backup)

        #expect(second.alreadyPresentCount == 3)
        #expect(second.backup == .completed(copied: 3, alreadyPresent: 0))
        #expect(names(in: backup).count == 3)
    }

    @Test func reportsProgressThroughToTheEnd() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let updates = Collector<IngestProgress>()

        _ = try IngestService.ingest(
            files: IngestService.scan(card),
            originals: temp.url.appendingPathComponent("shoot/Originals"),
            backupOriginals: nil,
            progress: { updates.add($0) }
        )

        let fractions = updates.values.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.last ?? 0 > 0.95)
        #expect(updates.values.allSatisfy { $0.phase == .copying })
    }

    @Test func aFileThatCannotBeWrittenFailsWithoutStoppingTheRest() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = try temp.subdirectory("shoot/Originals")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: originals.path)

        let result = try IngestService.ingest(
            files: IngestService.scan(card),
            originals: originals,
            backupOriginals: nil
        )

        #expect(result.copiedCount == 0)
        #expect(result.failures.count == 3)
        #expect(names(in: originals).isEmpty)
    }

    @Test func cancellingStopsCleanlyWithNoPartialFiles() async throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = temp.url.appendingPathComponent("shoot/Originals")
        let files = IngestService.scan(card)

        let task = Task.detached { () -> IngestResult in
            while !Task.isCancelled { await Task.yield() }
            return try IngestService.ingest(files: files, originals: originals, backupOriginals: nil)
        }
        task.cancel()
        let result = try await task.value

        #expect(result.wasCancelled)
        #expect(result.copiedCount == 0)
        #expect(names(in: originals).filter { $0.hasSuffix(IngestService.partialSuffix) }.isEmpty)
    }

    // MARK: Backup

    @Test func backupIsAVerifiedMirror() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let backup = temp.url.appendingPathComponent("backup/Originals")
        let phases = Collector<IngestProgress.Phase>()

        let result = try IngestService.ingest(
            files: IngestService.scan(card),
            originals: temp.url.appendingPathComponent("shoot/Originals"),
            backupOriginals: backup,
            progress: { phases.add($0.phase) }
        )

        #expect(result.backup == .completed(copied: 3, alreadyPresent: 0))
        #expect(names(in: backup) == ["P1000001.RW2", "P1000002.RW2", "P1000003.JPG"])
        for file in result.files {
            let mirrored = backup.appendingPathComponent(file.destinationURL.lastPathComponent)
            #expect(try IngestService.sha256(of: mirrored) == IngestService.sha256(of: file.destinationURL))
        }
        #expect(phases.values.contains(.backingUp))
    }

    @Test func aSecondBackupRunSkipsWhatIsAlreadyThere() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let originals = temp.url.appendingPathComponent("shoot/Originals")
        let backup = temp.url.appendingPathComponent("backup/Originals")
        let files = IngestService.scan(card)

        _ = try IngestService.ingest(files: files, originals: originals, backupOriginals: backup)
        let second = try IngestService.ingest(files: files, originals: originals, backupOriginals: backup)

        #expect(second.backup == .completed(copied: 0, alreadyPresent: 3))
    }

    @Test func aDisconnectedBackupDriveIsSkippedWithoutTouchingTheBootDrive() throws {
        let temp = try TempDirectory()
        let card = try makeCard(temp)
        let missingVolume = "NoSuchDrive-\(UUID().uuidString)"
        let backup = URL(fileURLWithPath: "/Volumes/\(missingVolume)/Shoot/Originals")

        let result = try IngestService.ingest(
            files: IngestService.scan(card),
            originals: temp.url.appendingPathComponent("shoot/Originals"),
            backupOriginals: backup
        )

        #expect(result.copiedCount == 3)
        guard case .unavailable(let reason) = result.backup else {
            Issue.record("Expected the backup to be unavailable, got \(result.backup)")
            return
        }
        #expect(reason.contains(missingVolume))
        #expect(!FileManager.default.fileExists(atPath: "/Volumes/\(missingVolume)"))
    }

    // MARK: Layout

    @Test func shootFoldersAreDatedAndSafe() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 in UTC

        #expect(ShootLayout.folderName(date: date, name: "Smith Wedding", calendar: calendar) == "2026-09-21 Smith Wedding")
        #expect(ShootLayout.folderName(date: date, name: "A/B: C", calendar: calendar) == "2026-09-21 A-B- C")
        #expect(ShootLayout.folderName(date: date, name: "  ", calendar: calendar) == "2026-09-21 Untitled Shoot")

        let folder = URL(fileURLWithPath: "/Volumes/SSD/Shoots/2026-09-21 Smith")
        #expect(ShootLayout.originals(in: folder).path.hasSuffix("2026-09-21 Smith/Originals"))
        #expect(ShootLayout.projectURL(in: folder, name: "Smith").lastPathComponent == "Smith.pmedit")
    }
}

struct IngestVerificationTests {
    @Test func aCopyThatDoesNotMatchIsDiscardedNotKept() throws {
        let temp = try TempDirectory()
        let source = try temp.file("card/P1.RW2", bytes: 3_000_000, seed: 7)
        let other = try temp.file("other.bin", bytes: 3_000_000, seed: 8)
        let wrongDigest = try IngestService.sha256(of: other)
        let destination = temp.url.appendingPathComponent("shoot/P1.RW2")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        #expect(throws: IngestError.self) {
            try IngestService.copyVerified(from: source, to: destination, expected: wrongDigest, onBytes: { _ in })
        }

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.path + IngestService.partialSuffix))
    }

    @Test func aMatchingCopyReturnsTheSourceDigest() throws {
        let temp = try TempDirectory()
        let source = try temp.file("card/P1.RW2", bytes: 3_000_000, seed: 7)
        let destination = temp.url.appendingPathComponent("shoot/P1.RW2")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let digest = try IngestService.copyVerified(from: source, to: destination, onBytes: { _ in })

        #expect(digest == (try IngestService.sha256(of: source)))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }
}
