import Foundation
import Testing
@testable import PerceptionEditor

func sampleRecord(id: String = "pme-0001-aaaa", items: Int = 2) -> TransferRecord {
    var adjustments = PhotoAdjustments()
    adjustments.exposure = 0.5
    return TransferRecord(
        id: id,
        serverURL: URL(string: "http://localhost:3001")!,
        webURL: URL(string: "http://localhost:3000"),
        galleryID: "gal_1", bookingID: "book_1",
        destinationLabel: "Fixture Client — Wedding",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        jpegQuality: 0.92, longEdgePixels: nil,
        protectedOriginalPaths: ["/Volumes/Card/A.RW2"],
        stagingFolderPath: "/tmp/staging/\(id)",
        remoteTransferID: nil, status: .running, pausedReason: nil,
        items: (0..<items).map { index in
            TransferItemRecord(
                id: "asset-\(index)", position: index,
                sourcePath: "/Volumes/Card/A\(index).RW2", adjustments: adjustments,
                displayName: "A\(index).RW2", uploadFileName: "A\(index).jpg"
            )
        }
    )
}

struct TransferQueueStoreTests {
    @Test func persistsRecordsAcrossStoreInstances() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("transfers.json")
        let first = TransferQueueStore(fileURL: file)
        try await first.upsert(sampleRecord())
        try await first.update(id: "pme-0001-aaaa") { $0.items[0].phase = .rendered; $0.items[0].sha256 = "abc" }

        let second = TransferQueueStore(fileURL: file)
        let loaded = try #require(await second.record(id: "pme-0001-aaaa"))
        #expect(loaded.items[0].phase == .rendered)
        #expect(loaded.items[0].sha256 == "abc")
        #expect(loaded.items[0].adjustments.exposure == 0.5)   // immutable snapshot survives a restart
        #expect(loaded.items[1].phase == .queued)
        #expect(await second.loadWarning() == nil)
    }

    @Test func aCorruptFileIsSetAsideNotCrashedOn() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("transfers.json")
        try Data("{ not json".utf8).write(to: file)
        let store = TransferQueueStore(fileURL: file)
        #expect(await store.all().isEmpty)
        #expect(await store.loadWarning() != nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        #expect(names.contains { $0.hasPrefix("transfers.json.corrupt-") })
        try await store.upsert(sampleRecord())   // the store is usable afterwards
        #expect(await store.all().count == 1)
    }

    @Test func removeDeletesOnlyTheNamedRecordAndWritesAtomically() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("transfers.json")
        let store = TransferQueueStore(fileURL: file)
        try await store.upsert(sampleRecord(id: "pme-0001-aaaa"))
        try await store.upsert(sampleRecord(id: "pme-0002-bbbb"))
        try await store.remove(id: "pme-0001-aaaa")
        #expect(await store.all().map(\.id) == ["pme-0002-bbbb"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path) == ["transfers.json"])
    }

    @Test func theFileHoldsNoCredentialsOrUploadURLs() throws {
        var record = sampleRecord()
        record.items[0].mediaID = "m1"
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self).lowercased()
        for forbidden in ["token", "pme_", "uploadurl", "x-amz", "authorization"] {
            #expect(!json.contains(forbidden), "queue file must not contain \(forbidden)")
        }
    }

    @Test func countsAndFractionDeriveFromItemPhases() {
        var record = sampleRecord(items: 4)
        record.items[0].phase = .ready
        record.items[1].phase = .processing
        record.items[2].phase = .rendered
        record.items[3].phase = .failed
        #expect(record.counts == TransferCounts(queued: 0, rendered: 1, processing: 1, ready: 1, failed: 1))
        #expect(record.counts.total == 4)
        #expect(record.fractionComplete == 0.25)
        #expect(record.hasUnfinishedWork)
        record.items = record.items.map { var i = $0; i.phase = .ready; return i }
        #expect(!record.hasUnfinishedWork)
    }
}
