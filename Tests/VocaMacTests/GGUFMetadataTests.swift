// GGUFMetadataTests.swift
// VocaMac
//
// Reading a cleanup model's architecture from its GGUF header.

import XCTest
@testable import VocaMac

final class GGUFMetadataTests: XCTestCase {

    // MARK: Building headers

    private struct Writer {
        var data = Data()
        mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        mutating func string(_ value: String) {
            u64(UInt64(value.utf8.count))
            data.append(contentsOf: Array(value.utf8))
        }
        mutating func stringPair(_ key: String, _ value: String) {
            string(key); u32(8); string(value)
        }
        mutating func u32Pair(_ key: String, _ value: UInt32) {
            string(key); u32(4); u32(value)
        }
    }

    private func header(version: UInt32 = 3, pairs: Int, body: (inout Writer) -> Void) -> Data {
        var writer = Writer()
        writer.data.append(contentsOf: Array("GGUF".utf8))
        writer.u32(version)
        writer.u64(291) // tensors
        writer.u64(UInt64(pairs))
        body(&writer)
        return writer.data
    }

    // MARK: Parsing

    func testReadsArchitectureAndValues() throws {
        let data = header(pairs: 3) {
            $0.stringPair("general.architecture", "qwen2")
            $0.u32Pair("qwen2.context_length", 32_768)
            $0.string("tokenizer.ggml.tokens"); $0.u32(9); $0.u32(8); $0.u64(2)
            $0.string("hello"); $0.string("world")
        }
        let metadata = try GGUFMetadata.parse(data)
        XCTAssertEqual(metadata.version, 3)
        XCTAssertEqual(metadata.architecture, "qwen2")
        XCTAssertEqual(metadata.values["qwen2.context_length"], .unsigned(32_768))
        XCTAssertEqual(metadata.values["tokenizer.ggml.tokens"], .array([.string("hello"), .string("world")]))
    }

    func testRejectsAFileThatIsNotGGUF() {
        let html = Data("<!DOCTYPE html><html>Not found</html>".utf8)
        XCTAssertThrowsError(try GGUFMetadata.parse(html)) {
            XCTAssertEqual($0 as? GGUFMetadata.ReadError, .notGGUF)
        }
    }

    func testRejectsVersionOne() {
        let data = header(version: 1, pairs: 0) { _ in }
        XCTAssertThrowsError(try GGUFMetadata.parse(data)) {
            XCTAssertEqual($0 as? GGUFMetadata.ReadError, .unsupportedVersion(1))
        }
    }

    func testTruncatedHeaderThrowsUnlessPartialIsAllowed() throws {
        var data = header(pairs: 2) {
            $0.stringPair("general.architecture", "llama")
            $0.stringPair("general.name", "a long model name")
        }
        data.removeLast(5)
        XCTAssertThrowsError(try GGUFMetadata.parse(data)) {
            XCTAssertEqual($0 as? GGUFMetadata.ReadError, .truncated)
        }
        XCTAssertEqual(try GGUFMetadata.parse(data, allowTruncation: true).architecture, "llama")
    }

    func testGarbageLengthsAreRejectedWithoutAllocating() {
        let data = header(pairs: 1) {
            $0.u64(UInt64.max) // key length
        }
        XCTAssertThrowsError(try GGUFMetadata.parse(data)) {
            XCTAssertEqual($0 as? GGUFMetadata.ReadError, .malformed)
        }
    }

    // MARK: Architectures

    func testHybridArchitecturesAreRefused() {
        XCTAssertFalse(GGUFMetadata.isCleanupArchitectureAllowed("qwen35"))
        XCTAssertFalse(GGUFMetadata.isCleanupArchitectureAllowed("granitehybrid"))
        XCTAssertFalse(GGUFMetadata.isCleanupArchitectureAllowed(nil))
        for architecture in GGUFMetadata.measuredCleanupArchitectures {
            XCTAssertTrue(GGUFMetadata.isCleanupArchitectureAllowed(architecture), architecture)
        }
    }

    /// Every downloaded catalog model must be an architecture that works.
    /// Skipped for models not downloaded on this machine.
    func testDownloadedCatalogModelsHaveAllowedArchitectures() throws {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VocaMac/models/cleanup")
        var checked = 0
        for kind in CleanupModelKind.allCases {
            let url = directory.appendingPathComponent(kind.descriptor.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let architecture = try GGUFMetadata.read(fileAt: url).architecture
            XCTAssertTrue(GGUFMetadata.measuredCleanupArchitectures.contains(architecture ?? ""),
                          "\(kind.descriptor.displayName): \(architecture ?? "nil")")
            checked += 1
        }
        if checked == 0 { throw XCTSkip("No cleanup models downloaded on this machine") }
    }
}
