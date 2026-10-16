// Tests/PerceptionEditorTests/ProxyGeneratorTests.swift
@preconcurrency import AVFoundation
import Foundation
import Testing
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

    @Test func smallFilesAndMissingFiles() throws {
        let temp = try TempDirectory()
        let tiny = try temp.file("tiny.mov", bytes: 10, seed: 1)
        #expect(try ProxyFingerprint.key(for: tiny).count == 64)
        #expect(throws: (any Error).self) { try ProxyFingerprint.key(for: temp.url.appendingPathComponent("gone.mov")) }
    }
}
