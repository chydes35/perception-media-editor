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

import CoreImage
import Metal
import simd

/// LUTs through `MediaColorRenderer` on the GPU, against `CubeLUT.evaluate` and the analytic tables.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct LUTRenderTests {
    /// A 3D LUT from a function of normalized (r, g, b).
    static func table(size: Int, domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = .one, _ f: (SIMD3<Double>) -> SIMD3<Double>) -> CubeLUT {
        var values: [Float] = []
        for b in 0 ..< size { for g in 0 ..< size { for r in 0 ..< size {
            let out = f(SIMD3(Double(r), Double(g), Double(b)) / Double(size - 1))
            values += [Float(out.x), Float(out.y), Float(out.z)]
        } } }
        return CubeLUT(kind: .threeD(size: size), domainMin: domainMin, domainMax: domainMax, values: values)
    }

    /// Registers the LUT under a fresh hash and renders `colors` through it as a creative LUT.
    static func render(_ colors: [SIMD3<Float>], _ lut: CubeLUT, intensity: Double = 1) -> [SIMD3<Float>] {
        let hash = LUTLibrary.hash(Data(UUID().uuidString.utf8))
        LoadedLUTs.shared.insert(lut, hash: hash)
        var adjustments = PhotoAdjustments()
        adjustments.lut = LUTApplication(reference: LUTReference(contentHash: hash, displayName: "Test"), intensity: intensity)
        return HSLPrecisionTests.render(colors, adjustments)
    }

    static func randomColors(_ count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var generator = SeededGenerator(seed: seed)
        return (0 ..< count).map { _ in
            SIMD3<Float>(Float.random(in: 0 ... 1, using: &generator), Float.random(in: 0 ... 1, using: &generator), Float.random(in: 0 ... 1, using: &generator))
        }
    }

    static func worst(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> Float {
        zip(a, b).map { simd_abs($0 - $1).max() }.max() ?? .infinity
    }

    @Test func anIdentityLUTChangesNothing() {
        let colors = Self.randomColors(4096, seed: 3)
        let output = Self.render(colors, Self.table(size: 33) { $0 })
        let error = Self.worst(output, colors)
        #expect(error <= 0.5 / 1023, "Identity LUT moved colors by \(error * 1023) of 1023")
    }

    @Test func aChannelSwapWithGammaMatchesTheInterpolationAndTheMath() {
        let lut = Self.table(size: 17) { c in SIMD3(c.z * c.z, c.x * c.x, c.y * c.y) }
        let colors = Self.randomColors(4096, seed: 5)
        let output = Self.render(colors, lut)
        let interpolated = colors.map { SIMD3<Float>(lut.evaluate(SIMD3<Double>($0))) }
        let exact = colors.map { c in SIMD3<Float>(c.z * c.z, c.x * c.x, c.y * c.y) }
        let againstInterpolation = Self.worst(output, interpolated), againstMath = Self.worst(output, exact)
        print("LUT 17³ swap+gamma: \(againstInterpolation * 1023) vs tetrahedral reference, \(againstMath * 1023) vs the function, of 1023")
        #expect(againstInterpolation <= 0.5 / 1023)
        // Linear interpolation of x² between nodes 1/16 apart is off by at most (1/16)²/8.
        #expect(againstMath <= Float(1.0 / 256 / 8) + 0.5 / 1023)
    }

    /// Large tables (Apple's Apple Log LUT is 65³) must look up the right lattice points: in a
    /// 65² × 65 table image, coordinates past 2048 lost precision and picked the neighbouring red
    /// entry (gate G11 found up to 14 of 1023 on a real frame).
    @Test(arguments: [33, 65])
    func largeTablesMatchTheInterpolation(size: Int) {
        let lut = Self.table(size: size) { c in SIMD3(c.z * c.z, c.x * c.x, c.y * c.y) }
        let colors = Self.randomColors(8192, seed: 11)
        let output = Self.render(colors, lut)
        let interpolated = colors.map { SIMD3<Float>(lut.evaluate(SIMD3<Double>($0))) }
        let error = Self.worst(output, interpolated)
        print("LUT \(size)³ swap+gamma: \(error * 1023) of 1023 against the tetrahedral reference")
        #expect(error <= 0.5 / 1023, "\(size)³: \(error * 1023) of 1023")
    }

    @Test func latticePointsComeOutExactly() {
        let lut = Self.table(size: 9) { c in SIMD3(sin(c.x * 1.3), c.y * c.z, 1 - c.x) }
        var colors: [SIMD3<Float>] = []
        for b in 0 ..< 9 { for g in stride(from: 0, to: 9, by: 2) { for r in stride(from: 0, to: 9, by: 3) {
            colors.append(SIMD3(Float(r), Float(g), Float(b)) / 8)
        } } }
        let output = Self.render(colors, lut)
        let expected = colors.map { c -> SIMD3<Float> in
            let index = SIMD3<Int>(Int((c.x * 8).rounded()), Int((c.y * 8).rounded()), Int((c.z * 8).rounded()))
            return lut.entry(r: index.x, g: index.y, b: index.z)
        }
        #expect(Self.worst(output, expected) <= 0.5 / 1023)
    }

    @Test func intensityZeroIsUntouchedAndHalfIsHalfway() {
        let colors = Self.randomColors(1024, seed: 7)
        let lut = Self.table(size: 17) { 1 - $0 }
        let none = HSLPrecisionTests.render(colors, PhotoAdjustments())
        #expect(Self.render(colors, lut, intensity: 0) == none, "Intensity 0 must be bit-identical to no LUT")
        let half = Self.render(colors, lut, intensity: 0.5)
        let expected = colors.map { ($0 + (1 - $0)) / 2 }
        #expect(Self.worst(half, expected) <= 0.5 / 1023)
    }

    @Test func theDomainScalesTheInput() {
        // Domain 0…2: an input of 1.0 is the middle of the table.
        let lut = Self.table(size: 5, domainMax: SIMD3(repeating: 2)) { c in c * 0.5 }
        let output = Self.render([SIMD3(repeating: 1)], lut)
        #expect(Self.worst(output, [SIMD3(repeating: 0.25)]) <= 0.5 / 1023)
    }

    @Test func oneDimensionalLUTsInterpolatePerChannel() {
        let size = 4100 // More than one 4096-entry row of the table image.
        var values: [Float] = []
        for i in 0 ..< size {
            let x = Double(i) / Double(size - 1)
            values += [Float(x * x), Float(sqrt(x)), Float(1 - x)]
        }
        let lut = CubeLUT(kind: .oneD(size: size), values: values)
        let colors = Self.randomColors(4096, seed: 9)
        let output = Self.render(colors, lut)
        let expected = colors.map { SIMD3<Float>(lut.evaluate(SIMD3<Double>($0))) }
        #expect(Self.worst(output, expected) <= 0.5 / 1023)
    }

    @Test func aLUTThatIsNotLoadedRendersWithoutIt() {
        var adjustments = PhotoAdjustments()
        adjustments.lut = LUTApplication(reference: LUTReference(contentHash: String(repeating: "f", count: 64), displayName: "Gone"))
        let colors = Self.randomColors(64, seed: 11)
        #expect(HSLPrecisionTests.render(colors, adjustments) == HSLPrecisionTests.render(colors, PhotoAdjustments()))
    }
}
