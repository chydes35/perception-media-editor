import Foundation
import Testing
@testable import PerceptionEditor

struct CubeLUTParserTests {
    /// An identity 3D LUT of `size` points per side, red varying fastest.
    static func identityText(size: Int, header: String = "") -> String {
        var lines = [header, "LUT_3D_SIZE \(size)"]
        for b in 0 ..< size { for g in 0 ..< size { for r in 0 ..< size {
            let scale = Double(size - 1)
            lines.append("\(Double(r) / scale) \(Double(g) / scale) \(Double(b) / scale)")
        } } }
        return lines.joined(separator: "\n")
    }

    @Test func aMinimalIdentityParses() throws {
        let lut = try CubeLUT(parsing: Self.identityText(size: 2))
        #expect(lut.kind == .threeD(size: 2))
        #expect(lut.values.count == 8 * 3)
        #expect(lut.domainMin == SIMD3(repeating: 0) && lut.domainMax == SIMD3(repeating: 1))
        // Red varies fastest: the second row is (1, 0, 0).
        #expect(Array(lut.values[3 ..< 6]) == [1, 0, 0])
    }

    @Test func titlesCommentsBlankLinesAndWindowsLineEndingsAreFine() throws {
        let text = "# Exported by a tool\r\nTITLE \"Film Look\"\r\n\r\n" + Self.identityText(size: 2).replacingOccurrences(of: "\n", with: "\r\n") + "\r\n# trailing comment\r\n"
        let lut = try CubeLUT(parsing: text)
        #expect(lut.title == "Film Look")
        #expect(lut.kind == .threeD(size: 2))
    }

    @Test func scientificNotationAndNegativeValuesParse() throws {
        var rows = ["LUT_3D_SIZE 2"]
        for _ in 0 ..< 8 { rows.append("1.5e-3 -2.0E-1 +0.25") }
        let lut = try CubeLUT(parsing: rows.joined(separator: "\n"))
        #expect(lut.values[0] == 0.0015 && lut.values[1] == -0.2 && lut.values[2] == 0.25)
    }

    @Test func domainsAreRead() throws {
        let lut = try CubeLUT(parsing: "DOMAIN_MIN 0 -0.1 0\nDOMAIN_MAX 1 1.5 2\n" + Self.identityText(size: 2))
        #expect(lut.domainMin == SIMD3(0, -0.1, 0) && lut.domainMax == SIMD3(1, 1.5, 2))
    }

    @Test func oneDimensionalLUTsParse() throws {
        let lut = try CubeLUT(parsing: "LUT_1D_SIZE 4\n0 0 0\n0.1 0.2 0.3\n0.5 0.5 0.5\n1 1 1")
        #expect(lut.kind == .oneD(size: 4))
        #expect(lut.values.count == 12)
    }

    @Test(arguments: [
        ("0 0 0\n1 1 1", "size"),
        ("LUT_3D_SIZE 1\n0 0 0", "between"),
        ("LUT_3D_SIZE 66\n0 0 0", "between"),
        ("LUT_1D_SIZE 70000\n0 0 0", "between"),
        ("LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n0 0 0\n1 1 1", "both"),
        ("LUT_3D_SIZE 2\n0 0 0\n1 1 1", "8"),
        ("LUT_1D_SIZE 2\n0 0 0\n0.5 0.5 0.5\n1 1 1", "2"),
        ("LUT_1D_SIZE 2\n0 0 0\nnan 0 0", "line 3"),
        ("LUT_1D_SIZE 2\n0 0 0\ninf 1 1", "line 3"),
        ("LUT_1D_SIZE 2\n0 0 0\n0,5 0,5 0,5", "line 3"),
        ("LUT_1D_SIZE 2\n0 0 0\n1 1", "line 3"),
        ("DOMAIN_MIN 0 0 1\nDOMAIN_MAX 1 1 1\nLUT_1D_SIZE 2\n0 0 0\n1 1 1", "domain")
    ] as [(String, String)])
    func malformedFilesAreRejectedWithAReadableReason(text: String, mention: String) {
        do {
            _ = try CubeLUT(parsing: text)
            Issue.record("Accepted a malformed LUT: \(text.prefix(40))")
        } catch {
            let message = error.localizedDescription
            #expect(message.lowercased().contains(mention.lowercased()), "“\(message)” should mention \(mention)")
        }
    }

    @Test func filesOver64MBAreRefusedBeforeReading() throws {
        let temp = try TempDirectory()
        let url = temp.url.appendingPathComponent("huge.cube")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CubeLUT.maximumFileBytes + 1))
        try handle.close()
        #expect(throws: CubeLUTError.self) { _ = try CubeLUT(contentsOf: url) }
    }

    static let panasonicURL = URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT/Panasonic/V-Log to V-709.cube")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: CubeLUTParserTests.panasonicURL.path)))
    func panasonicsVLogToV709Parses() throws {
        let lut = try CubeLUT(contentsOf: Self.panasonicURL)
        #expect(lut.kind == .threeD(size: 33))
        #expect(lut.values.count == 33 * 33 * 33 * 3)
        // The file's first row: code-value black maps to 0.015625.
        #expect(Array(lut.values[0 ..< 3]) == [0.015625, 0.015625, 0.015625])
    }
}

struct LUTLibraryTests {
    /// A small LUT whose bytes are unique to the caller, so tests never share a content hash.
    static func writeLUT(_ url: URL, tag: String = UUID().uuidString) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("# \(tag)\n" + CubeLUTParserTests.identityText(size: 3)).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func importingCopiesTheFileAndLeavesTheSourceAlone() throws {
        let temp = try TempDirectory()
        let source = try Self.writeLUT(temp.url.appendingPathComponent("Downloads/Film Look.cube"))
        let before = try Data(contentsOf: source)
        let library = LUTLibrary(directory: temp.url.appendingPathComponent("Library"))
        let reference = try library.importLUT(from: source)

        #expect(reference.displayName == "Film Look")
        #expect(reference.contentHash == LUTLibrary.hash(before))
        #expect(try Data(contentsOf: source) == before, "The source file must never change")
        #expect(FileManager.default.fileExists(atPath: library.directory.appendingPathComponent("\(reference.contentHash).cube").path))
        #expect(library.references() == [reference])
        #expect(LUTLibrary(directory: library.directory).references() == [reference], "The index survives a new library instance")
    }

    @Test func theSameBytesImportedTwiceAreOneLUT() throws {
        let temp = try TempDirectory()
        let first = try Self.writeLUT(temp.url.appendingPathComponent("a/One.cube"), tag: "same-\(UUID())")
        let second = temp.url.appendingPathComponent("b/Copy of One.cube")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first, to: second)
        let library = LUTLibrary(directory: temp.url.appendingPathComponent("Library"))
        let a = try library.importLUT(from: first), b = try library.importLUT(from: second)
        #expect(a == b, "Same content, same LUT, keeping the first name")
        #expect(library.references().count == 1)
    }

    @Test func aBadFileIsRefusedAndNothingIsStored() throws {
        let temp = try TempDirectory()
        let bad = temp.url.appendingPathComponent("bad.cube")
        try "LUT_3D_SIZE 2\n0 0 0".write(to: bad, atomically: true, encoding: .utf8)
        let library = LUTLibrary(directory: temp.url.appendingPathComponent("Library"))
        #expect(throws: CubeLUTError.self) { try library.importLUT(from: bad) }
        #expect(library.references().isEmpty)
    }

    @Test func aProjectFindsItsOwnCopyWhenTheLibraryIsGone() throws {
        let temp = try TempDirectory()
        let source = try Self.writeLUT(temp.url.appendingPathComponent("V-Log to V-709.cube"))
        let library = LUTLibrary(directory: temp.url.appendingPathComponent("Library"))
        let reference = try library.importLUT(from: source)
        let shoot = temp.url.appendingPathComponent("2026-10-16 Ballgame", isDirectory: true)
        try library.copy([reference], intoProjectFolder: shoot)
        let copy = shoot.appendingPathComponent("LUTs").appendingPathComponent(LUTLibrary.projectFileName(for: reference))
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(copy.lastPathComponent.hasPrefix(String(reference.contentHash.prefix(12)) + "-V-Log to V-709"))

        // Another Mac: an empty library, nothing loaded in memory.
        LoadedLUTs.shared.remove(reference.contentHash)
        let elsewhere = LUTLibrary(directory: temp.url.appendingPathComponent("Other Library"))
        #expect(elsewhere.load(reference, projectFolder: shoot) != nil)

        // A copy whose bytes changed is not trusted.
        LoadedLUTs.shared.remove(reference.contentHash)
        try "# edited\n".appending(try String(contentsOf: copy, encoding: .utf8)).write(to: copy, atomically: true, encoding: .utf8)
        #expect(elsewhere.load(reference, projectFolder: shoot) == nil)
    }

    @Test func aMissingLUTLoadsAsNothing() {
        let library = LUTLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID())"))
        #expect(library.load(LUTReference(contentHash: String(repeating: "0", count: 64), displayName: "Gone"), projectFolder: nil) == nil)
    }
}

struct LUTModelTests {
    private let reference = LUTReference(contentHash: String(repeating: "a", count: 64), displayName: "Film Look")

    @Test func aPhotosLUTRoundTripsAndOldFilesHaveNone() throws {
        var adjustments = PhotoAdjustments(exposure: 0.2)
        adjustments.lut = LUTApplication(reference: reference, intensity: 0.4)
        let decoded = try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(adjustments))
        #expect(decoded == adjustments)
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure": 0.2}"#.utf8))
        #expect(old.lut == nil)
    }

    @Test func presetsPasteAndSyncLeaveEachPhotosLUTAlone() {
        var source = PhotoAdjustments(exposure: 0.5)
        source.lut = LUTApplication(reference: reference)
        var target = PhotoAdjustments()
        let other = LUTReference(contentHash: String(repeating: "b", count: 64), displayName: "Other")
        target.lut = LUTApplication(reference: other, intensity: 0.7)
        let result = target.applying(source, groups: Set(AdjustmentGroup.allCases))
        #expect(result.exposure == 0.5)
        #expect(result.lut == target.lut, "A preset never carries or removes a LUT")
        #expect(source.lookOnly.lut == nil)
        #expect(result.changeSummary(from: target) == "Exposure")
    }

    @Test func sourceColorLUTsRoundTripAndAreListedWithCreativeOnes() throws {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/clips/P1.MOV"), kind: .video)
        var project = EditorProject(name: "LUTs", media: [asset])
        project.colorInputByAssetID[asset.id] = .lut(reference)
        let photo = UUID()
        var adjustments = PhotoAdjustments()
        let creative = LUTReference(contentHash: String(repeating: "c", count: 64), displayName: "Creative")
        adjustments.lut = LUTApplication(reference: creative)
        project.adjustmentsByAssetID[photo] = adjustments
        #expect(project.referencedLUTs == [reference, creative])
        let document = ProjectDocument()
        let decoded = try document.project(from: document.data(for: project))
        #expect(decoded.colorInput(for: asset.id) == .lut(reference))
    }
}
