// GGUFMetadata.swift
// VocaMac
//
// Minimal reader for the key/value header at the front of a GGUF file.
//
// Only the header is parsed (magic, version, counts, metadata pairs), never
// tensor data, so it works on the first few hundred KB of a file and fails
// cleanly on a truncated one. VocaMac uses it to check a cleanup model's
// `general.architecture` before llama.cpp loads it: LLM.swift reuses the KV
// cache between calls, which is wrong for hybrid attention/recurrent
// architectures (see AGENTS.md → Dependencies).

import Foundation

struct GGUFMetadata: Equatable {

    enum ReadError: Error, Equatable {
        case notGGUF
        case unsupportedVersion(UInt32)
        case truncated
        case malformed
    }

    enum Value: Equatable {
        case string(String)
        case integer(Int64)
        case unsigned(UInt64)
        case float(Double)
        case bool(Bool)
        case array([Value])
    }

    let version: UInt32
    let values: [String: Value]

    var architecture: String? {
        if case .string(let name)? = values["general.architecture"] { return name }
        return nil
    }

    // MARK: - Architectures

    /// Architectures measured to work with LLM.swift's KV-cache reuse.
    /// Others that are not hybrid may load, but are logged as unmeasured.
    static let measuredCleanupArchitectures: Set<String> = [
        "qwen2", "qwen3", "mistral3", "llama", "gemma3", "granite",
    ]

    /// Hybrid attention/recurrent architectures that break LLM.swift's cache
    /// reuse: output goes empty after the first call, and reset aborts.
    static let hybridArchitectures: Set<String> = [
        "qwen35", "qwen35moe", "qwen3next", "granitehybrid", "lfm2", "jamba", "mamba", "mamba2",
        "rwkv6", "rwkv6qwen2", "rwkv7", "arwkv7", "nemotron_h", "falcon-h1", "plamo2",
    ]

    /// Whether a cleanup model with this architecture may be loaded.
    static func isCleanupArchitectureAllowed(_ architecture: String?) -> Bool {
        guard let architecture else { return false }
        return !hybridArchitectures.contains(architecture)
    }

    // MARK: - Reading

    /// Bytes read from disk; enough for the header of every catalog model.
    static let headerReadLength = 2 * 1024 * 1024

    /// Read the header of a file on disk. A tokenizer vocabulary can run
    /// past the bytes read; the pairs before it (including the
    /// architecture, which writers put first) are still returned.
    static func read(fileAt url: URL) throws -> GGUFMetadata {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: headerReadLength) ?? Data()
        return try parse(data, allowTruncation: true)
    }

    /// Caps so garbage bytes cannot ask for enormous allocations.
    private static let maximumPairs: UInt64 = 100_000
    private static let maximumStringLength: UInt64 = 16 * 1024 * 1024
    private static let maximumArrayCount: UInt64 = 10_000_000

    /// Arrays longer than this (token lists) are skipped rather than kept.
    private static let maximumKeptArrayCount: UInt64 = 1_024

    static func parse(_ data: Data, allowTruncation: Bool = false) throws -> GGUFMetadata {
        var reader = Reader(bytes: [UInt8](data))
        guard try reader.uint32() == 0x4655_4747 else { throw ReadError.notGGUF } // "GGUF"
        let version = try reader.uint32()
        guard version == 2 || version == 3 else { throw ReadError.unsupportedVersion(version) }
        _ = try reader.uint64() // tensor count
        let pairCount = try reader.uint64()
        guard pairCount <= maximumPairs else { throw ReadError.malformed }
        var values: [String: Value] = [:]
        do {
            for _ in 0..<pairCount {
                let key = try reader.string()
                let type = try reader.uint32()
                values[key] = try reader.value(ofType: type, depth: 0)
            }
        } catch ReadError.truncated where allowTruncation && !values.isEmpty {
            // Keep the pairs read before the end of the buffer.
        }
        return GGUFMetadata(version: version, values: values)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else { throw ReadError.truncated }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }

        mutating func little<T: FixedWidthInteger>(_: T.Type) throws -> T {
            var result: T = 0
            for (shift, byte) in try take(MemoryLayout<T>.size).enumerated() {
                result |= T(truncatingIfNeeded: byte) << (shift * 8)
            }
            return result
        }

        mutating func uint32() throws -> UInt32 { try little(UInt32.self) }
        mutating func uint64() throws -> UInt64 { try little(UInt64.self) }

        mutating func string() throws -> String {
            let length = try uint64()
            guard length <= GGUFMetadata.maximumStringLength else { throw ReadError.malformed }
            return String(decoding: try take(Int(length)), as: UTF8.self)
        }

        mutating func value(ofType type: UInt32, depth: Int) throws -> Value {
            switch type {
            case 0: return .unsigned(UInt64(try little(UInt8.self)))
            case 1: return .integer(Int64(try little(Int8.self)))
            case 2: return .unsigned(UInt64(try little(UInt16.self)))
            case 3: return .integer(Int64(try little(Int16.self)))
            case 4: return .unsigned(UInt64(try little(UInt32.self)))
            case 5: return .integer(Int64(try little(Int32.self)))
            case 6: return .float(Double(Float(bitPattern: try little(UInt32.self))))
            case 7: return .bool(try little(UInt8.self) != 0)
            case 8: return .string(try string())
            case 9:
                guard depth < 4 else { throw ReadError.malformed }
                let elementType = try uint32()
                let count = try uint64()
                guard count <= GGUFMetadata.maximumArrayCount else { throw ReadError.malformed }
                let keep = count <= GGUFMetadata.maximumKeptArrayCount
                var elements: [Value] = []
                for _ in 0..<count {
                    let element = try value(ofType: elementType, depth: depth + 1)
                    if keep { elements.append(element) }
                }
                return .array(elements)
            case 10: return .unsigned(try little(UInt64.self))
            case 11: return .integer(try little(Int64.self))
            case 12: return .float(Double(bitPattern: try little(UInt64.self)))
            default: throw ReadError.malformed
            }
        }
    }
}
