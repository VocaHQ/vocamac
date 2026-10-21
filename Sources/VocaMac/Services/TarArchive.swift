// TarArchive.swift
// VocaMac
//
// Unpacks .tar.bz2 model archives inside the process. The App Store build
// can't start /usr/bin/tar, so it decompresses with the system libbz2
// (`VocaBZip2`) and reads the tar format here.

import Foundation
import VocaMacObjC

enum TarArchiveError: LocalizedError, Equatable {
    case decompressionFailed(String)
    case truncated
    case malformedHeader
    case unsafePath(String)

    var errorDescription: String? {
        switch self {
        case .decompressionFailed(let reason):
            return reason
        case .truncated:
            return "The archive ends in the middle of a file."
        case .malformedHeader:
            return "The archive isn't a tar file, or it is damaged."
        case .unsafePath(let path):
            return "The archive holds a file outside its own folder: \(path)"
        }
    }
}

/// Extracts tar archives (ustar, GNU and pax): regular files and folders.
///
/// Links, devices and FIFOs are skipped, since model archives hold none, and
/// so are AppleDouble `._` files, which bsdtar turns into extended attributes
/// rather than files. Absolute paths and `..` are refused, so nothing can
/// land outside the destination.
enum TarArchive {
    static let blockSize = 512

    /// Type flags, from the header's byte 156.
    private enum EntryType {
        static let file = UInt8(ascii: "0")
        static let oldFile = UInt8(0)
        static let contiguousFile = UInt8(ascii: "7")
        static let directory = UInt8(ascii: "5")
        static let gnuLongName = UInt8(ascii: "L")
        static let gnuLongLinkName = UInt8(ascii: "K")
        static let paxHeader = UInt8(ascii: "x")
    }

    /// Longest GNU long-name or pax header read into memory. Real ones are a
    /// few hundred bytes; anything bigger is a damaged archive.
    private static let metadataLimit = 1 << 20

    /// Decompress the .tar.bz2 at `archive` and extract it into `directory`.
    /// The decompressed tar is written to `directory` first and removed after.
    static func extractBZip2(at archive: URL, into directory: URL) throws {
        try Task.checkCancellation()
        let tarFile = directory.appendingPathComponent(".\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: tarFile) }
        try decompressBZip2(at: archive, to: tarFile)
        try extract(at: tarFile, into: directory)
    }

    /// Decompress the bzip2 file at `source` into `destination`.
    static func decompressBZip2(at source: URL, to destination: URL) throws {
        do {
            try VocaBZip2.decompressFile(atPath: source.path, toPath: destination.path, shouldCancel: { Task.isCancelled })
        } catch {
            try Task.checkCancellation()
            throw TarArchiveError.decompressionFailed(error.localizedDescription)
        }
    }

    /// Extract the plain tar file at `tarFile` into `directory`.
    static func extract(at tarFile: URL, into directory: URL) throws {
        let fileManager = FileManager.default
        let handle = try FileHandle(forReadingFrom: tarFile)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)

        // A GNU long name or pax header describes the entry after it.
        var nextPath: String?
        var nextSize: Int?

        while true {
            try Task.checkCancellation()
            let block = try handle.read(upToCount: blockSize) ?? Data()
            // GNU tar also accepts an archive that stops without its two
            // closing zero blocks.
            if block.isEmpty || block.allSatisfy({ $0 == 0 }) { return }
            guard block.count == blockSize else { throw TarArchiveError.truncated }
            let header = try TarHeader(block)

            switch header.type {
            case EntryType.gnuLongName, EntryType.gnuLongLinkName, EntryType.paxHeader:
                guard header.size <= metadataLimit else { throw TarArchiveError.malformedHeader }
                let data = try readExactly(handle, count: header.size)
                try skipBytes(handle, count: paddingLength(after: header.size), fileSize: fileSize)
                if header.type == EntryType.gnuLongName {
                    nextPath = TarHeader.string(data)
                } else if header.type == EntryType.paxHeader {
                    let records = paxRecords(data)
                    if let path = records["path"] { nextPath = path }
                    if let size = records["size"].flatMap({ Int($0) }) { nextSize = size }
                }
                continue
            default:
                break
            }

            let path = nextPath ?? header.name
            let size = nextSize ?? header.size
            nextPath = nil
            nextSize = nil
            let target = try destination(for: path, in: directory)

            switch header.type {
            case EntryType.file, EntryType.oldFile, EntryType.contiguousFile:
                guard let target, !target.lastPathComponent.hasPrefix("._") else {
                    try skipBytes(handle, count: size + paddingLength(after: size), fileSize: fileSize)
                    continue
                }
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try copyBytes(handle, count: size, to: target)
                try skipBytes(handle, count: paddingLength(after: size), fileSize: fileSize)
            case EntryType.directory:
                if let target {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                }
                try skipBytes(handle, count: size + paddingLength(after: size), fileSize: fileSize)
            default:
                // Links, devices, FIFOs and pax global headers.
                try skipBytes(handle, count: size + paddingLength(after: size), fileSize: fileSize)
            }
        }
    }

    /// Where `path` from the archive goes inside `directory`; nil for the
    /// archive's own root ("./").
    static func destination(for path: String, in directory: URL) throws -> URL? {
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !path.hasPrefix("/"), !components.contains("..") else {
            throw TarArchiveError.unsafePath(path)
        }
        guard !components.isEmpty else { return nil }
        return components.reduce(directory) { $0.appendingPathComponent($1) }
    }

    /// The records of a pax extended header: "<length> <key>=<value>\n" each.
    static func paxRecords(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var records: [String: String] = [:]
        var start = 0
        while start < bytes.count {
            guard let space = bytes[start...].firstIndex(of: UInt8(ascii: " ")),
                  let length = Int(String(decoding: bytes[start..<space], as: UTF8.self)),
                  length > space - start, start + length <= bytes.count else { break }
            var bodyEnd = start + length
            if bodyEnd > space + 1, bytes[bodyEnd - 1] == UInt8(ascii: "\n") { bodyEnd -= 1 }
            let body = bytes[(space + 1)..<bodyEnd]
            if let equals = body.firstIndex(of: UInt8(ascii: "=")) {
                let key = String(decoding: body[..<equals], as: UTF8.self)
                records[key] = String(decoding: body[(equals + 1)...], as: UTF8.self)
            }
            start += length
        }
        return records
    }

    // MARK: - Reading

    /// Zero bytes that fill an entry's data out to whole blocks.
    private static func paddingLength(after size: Int) -> Int {
        (blockSize - size % blockSize) % blockSize
    }

    /// Exactly `count` bytes, or `.truncated`.
    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try handle.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw TarArchiveError.truncated
            }
            data.append(chunk)
        }
        return data
    }

    /// Move past `count` bytes that aren't extracted.
    private static func skipBytes(_ handle: FileHandle, count: Int, fileSize: UInt64) throws {
        guard count > 0 else { return }
        let target = try handle.offset() + UInt64(count)
        guard target <= fileSize else { throw TarArchiveError.truncated }
        try handle.seek(toOffset: target)
    }

    /// Copy the next `count` bytes into a new file at `url`, a chunk at a time.
    private static func copyBytes(_ handle: FileHandle, count: Int, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        var remaining = count
        while remaining > 0 {
            try Task.checkCancellation()
            let chunk = try readExactly(handle, count: min(remaining, 1 << 20))
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }
}

/// One 512-byte tar header.
struct TarHeader {
    var name: String
    var size: Int
    var type: UInt8

    init(_ block: Data) throws {
        let bytes = [UInt8](block)
        guard bytes.count == TarArchive.blockSize, Self.checksumMatches(bytes),
              let size = Self.number(bytes[124..<136]), size >= 0 else {
            throw TarArchiveError.malformedHeader
        }
        self.size = size
        type = bytes[156]
        name = Self.string(bytes[0..<100])
        // ustar keeps the leading folders of a long path in the prefix field.
        // GNU tar uses those bytes for other things and writes "ustar  ".
        if bytes[257..<263].elementsEqual(Array("ustar\0".utf8)) {
            let prefix = Self.string(bytes[345..<500])
            if !prefix.isEmpty { name = prefix + "/" + name }
        }
    }

    /// A NUL-terminated text field.
    static func string<Bytes: Collection>(_ field: Bytes) -> String where Bytes.Element == UInt8 {
        String(decoding: field.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// An octal number field, or a big-endian binary one when the first
    /// byte's top bit is set (GNU tar's form for sizes over 8 GB).
    static func number(_ field: ArraySlice<UInt8>) -> Int? {
        guard let first = field.first else { return nil }
        if first & 0x80 != 0 {
            var value = Int(first & 0x7F)
            for byte in field.dropFirst() {
                guard value <= Int.max >> 8 else { return nil }
                value = value << 8 | Int(byte)
            }
            return value
        }
        let text = string(field).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? 0 : Int(text, radix: 8)
    }

    /// The header's checksum: every byte added up with the checksum field
    /// itself counted as spaces. Old tars summed signed bytes, so either passes.
    static func checksumMatches(_ bytes: [UInt8]) -> Bool {
        guard let stored = number(bytes[148..<156]) else { return false }
        var unsigned = 0
        var signed = 0
        for (index, byte) in bytes.enumerated() {
            let value = (148..<156).contains(index) ? UInt8(ascii: " ") : byte
            unsigned += Int(value)
            signed += Int(Int8(bitPattern: value))
        }
        return stored == unsigned || stored == signed
    }
}
