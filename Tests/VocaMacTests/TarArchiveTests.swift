// TarArchiveTests.swift
// VocaMac Tests
//
// In-process .tar.bz2 extraction, which the App Store build uses for
// sherpa-onnx model archives because it can't start /usr/bin/tar. Archives
// are made with the system tar and bzip2, so the reader is checked against
// what real tools write.

import XCTest
@testable import VocaMac

final class TarArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TarArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Run a tool, sending its standard output to `output` when given.
    private func run(_ tool: String, _ arguments: [String], output: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // No AppleDouble "._" entries from bsdtar.
        process.environment = ["COPYFILE_DISABLE": "1"]
        var handle: FileHandle?
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            handle = try FileHandle(forWritingTo: output)
            process.standardOutput = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try handle?.close()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))")
    }

    /// Relative path → contents of every file under `root`.
    private func files(under root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(relative)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }

    /// A model-like folder: binary weights that don't fill a whole block, an
    /// empty file, a path longer than 100 characters, and (where the format
    /// allows it) a file name longer than 100 characters.
    private func makeSource(longFileName: Bool) throws -> URL {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let model = source.appendingPathComponent("model", isDirectory: true)
        let deep = model
            .appendingPathComponent(String(repeating: "d", count: 60), isDirectory: true)
            .appendingPathComponent(String(repeating: "e", count: 60), isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data((0..<1500).map { UInt8($0 % 251) }).write(to: model.appendingPathComponent("encoder.onnx"))
        try Data("a 1\nb 2\n".utf8).write(to: model.appendingPathComponent("tokens.txt"))
        try Data().write(to: model.appendingPathComponent("empty.bin"))
        try Data(repeating: 7, count: 512).write(to: deep.appendingPathComponent("weights.bin"))
        if longFileName {
            try Data("long".utf8).write(to: model.appendingPathComponent(String(repeating: "n", count: 120) + ".txt"))
        }
        return source
    }

    /// A ustar header block with a valid checksum.
    private func header(name: String, size: Int, type: UInt8 = UInt8(ascii: "0")) -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int) {
            for (index, byte) in text.utf8.enumerated() { block[offset + index] = byte }
        }
        put(name, at: 0)
        put("0000644", at: 100)
        put(String(format: "%011lo", size), at: 124)
        block[156] = type
        put("ustar", at: 257)
        put("00", at: 263)
        for index in 148..<156 { block[index] = UInt8(ascii: " ") }
        put(String(format: "%06lo", block.reduce(0) { $0 + Int($1) }), at: 148)
        block[154] = 0
        return Data(block)
    }

    /// `data` padded with zeros to whole 512-byte blocks.
    private func padded(_ data: Data) -> Data {
        data + Data(count: (512 - data.count % 512) % 512)
    }

    // MARK: - Round trips with the system tar

    func testExtractsWhatSystemTarWritesInEachFormat() throws {
        for format in ["ustar", "pax", "gnutar"] {
            let source = try makeSource(longFileName: format != "ustar")
            let archive = directory.appendingPathComponent("model-\(format).tar.bz2")
            try run("/usr/bin/tar", ["-c", "-j", "--format", format, "-f", archive.path, "-C", source.path, "model"])
            let output = directory.appendingPathComponent("out-\(format)", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

            try TarArchive.extractBZip2(at: archive, into: output)

            XCTAssertEqual(try files(under: output), try files(under: source), format)
            // The decompressed tar written next to the files is gone.
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), ["model"], format)
            try FileManager.default.removeItem(at: source)
        }
    }

    func testSkipsTheArchiveRootEntry() throws {
        let source = try makeSource(longFileName: false)
        let archive = directory.appendingPathComponent("dot.tar.bz2")
        // "-C source ." starts the archive with a "./" entry.
        try run("/usr/bin/tar", ["-c", "-j", "-f", archive.path, "-C", source.path, "."])
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try TarArchive.extractBZip2(at: archive, into: output)

        XCTAssertEqual(try files(under: output), try files(under: source))
    }

    // MARK: - bzip2

    func testDecompressesConcatenatedStreams() throws {
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        try Data("first half, ".utf8).write(to: first)
        try Data("second half".utf8).write(to: second)
        let firstCompressed = directory.appendingPathComponent("first.bz2")
        let secondCompressed = directory.appendingPathComponent("second.bz2")
        try run("/usr/bin/bzip2", ["-c", first.path], output: firstCompressed)
        try run("/usr/bin/bzip2", ["-c", second.path], output: secondCompressed)
        let joined = directory.appendingPathComponent("joined.bz2")
        try (Data(contentsOf: firstCompressed) + Data(contentsOf: secondCompressed)).write(to: joined)
        let result = directory.appendingPathComponent("joined.txt")

        try TarArchive.decompressBZip2(at: joined, to: result)

        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "first half, second half")
    }

    func testTruncatedArchiveThrowsAndLeavesNothingBehind() throws {
        let source = try makeSource(longFileName: false)
        let archive = directory.appendingPathComponent("model.tar.bz2")
        try run("/usr/bin/tar", ["-c", "-j", "-f", archive.path, "-C", source.path, "model"])
        let whole = try Data(contentsOf: archive)
        try whole.prefix(whole.count / 2).write(to: archive)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        XCTAssertThrowsError(try TarArchive.extractBZip2(at: archive, into: output)) { error in
            guard case .decompressionFailed = error as? TarArchiveError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: output.path), [])
    }

    func testGarbageAfterABzip2HeaderThrows() throws {
        let corrupt = directory.appendingPathComponent("corrupt.tar.bz2")
        try (Data([0x42, 0x5A, 0x68, 0x39]) + Data(repeating: 0xAB, count: 4096)).write(to: corrupt)

        XCTAssertThrowsError(try TarArchive.extractBZip2(at: corrupt, into: directory))
    }

    // MARK: - Tar

    func testRefusesPathsOutsideTheDestination() throws {
        for name in ["../evil.txt", "model/../../evil.txt", "/tmp/evil.txt"] {
            let tar = directory.appendingPathComponent("evil.tar")
            try (header(name: name, size: 4) + padded(Data("evil".utf8)) + Data(count: 1024)).write(to: tar)
            let output = directory.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

            XCTAssertThrowsError(try TarArchive.extract(at: tar, into: output)) { error in
                XCTAssertEqual(error as? TarArchiveError, .unsafePath(name))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("evil.txt").path))
        }
    }

    func testFileCutShortThrowsTruncated() throws {
        let tar = directory.appendingPathComponent("short.tar")
        try (header(name: "model/weights.bin", size: 2048) + Data(repeating: 1, count: 100)).write(to: tar)

        XCTAssertThrowsError(try TarArchive.extract(at: tar, into: directory)) { error in
            XCTAssertEqual(error as? TarArchiveError, .truncated)
        }
    }

    func testBadChecksumThrowsMalformedHeader() throws {
        var block = header(name: "model/tokens.txt", size: 0)
        block[0] = UInt8(ascii: "x")
        let tar = directory.appendingPathComponent("bad.tar")
        try (block + Data(count: 1024)).write(to: tar)

        XCTAssertThrowsError(try TarArchive.extract(at: tar, into: directory)) { error in
            XCTAssertEqual(error as? TarArchiveError, .malformedHeader)
        }
    }

    func testSkipsLinksAndAppleDoubleFiles() throws {
        let tar = directory.appendingPathComponent("links.tar")
        let data = header(name: "model/link", size: 0, type: UInt8(ascii: "2"))
            + header(name: "model/._tokens.txt", size: 3) + padded(Data("abc".utf8))
            + header(name: "model/tokens.txt", size: 3) + padded(Data("xyz".utf8))
            + Data(count: 1024)
        try data.write(to: tar)
        let output = directory.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try TarArchive.extract(at: tar, into: output)

        XCTAssertEqual(try files(under: output), ["model/tokens.txt": Data("xyz".utf8)])
    }

    func testParsesPaxRecords() {
        // Each record's length counts its own digits, the space and the newline.
        let records = TarArchive.paxRecords(Data("28 path=some/long/name.onnx\n11 size=12\n".utf8))

        XCTAssertEqual(records, ["path": "some/long/name.onnx", "size": "12"])
    }

    func testPaxRecordsStopAtAMalformedLength() {
        XCTAssertEqual(TarArchive.paxRecords(Data("99 path=x\n".utf8)), [:])
        XCTAssertEqual(TarArchive.paxRecords(Data("nonsense".utf8)), [:])
    }
}
