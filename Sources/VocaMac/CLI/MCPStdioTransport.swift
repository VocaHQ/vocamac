// MCPStdioTransport.swift
// VocaMac
//
// Runs the MCP server over standard input and output, and the backend it
// uses in production: the app's history files, preferences, and models.

import AppKit
import Darwin
import Foundation

// MARK: - Transport

/// Reads one JSON-RPC message per line from stdin and writes each response
/// as one line to stdout, until stdin closes.
enum MCPStdioTransport {
    /// Serve until the client closes stdin. Returns the process exit code.
    static func run(server: MCPServer) async -> Int32 {
        Darwin.fflush(nil)
        // The protocol owns stdout. Speech engines and CoreML print to it on
        // their own, so the real stdout is kept aside for responses and
        // everything else written there goes to stderr, which MCP clients
        // treat as a log.
        let protocolOutput = Darwin.dup(STDOUT_FILENO)
        guard protocolOutput >= 0 else {
            VocaLogger.error(.general, "MCP: could not keep stdout for the protocol")
            return 1
        }
        Darwin.dup2(STDERR_FILENO, STDOUT_FILENO)
        defer { Darwin.close(protocolOutput) }

        VocaLogger.info(.general, "MCP server started")
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                guard let response = await server.handle(line: line) else { continue }
                write(response + "\n", to: protocolOutput)
            }
        } catch {
            VocaLogger.error(.general, "MCP: reading stdin failed: \(error.localizedDescription)")
            return 1
        }
        VocaLogger.info(.general, "MCP server stopped: the client closed stdin")
        return 0
    }

    private static func write(_ text: String, to descriptor: Int32) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written > 0 else { return }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }
    }
}

// MARK: - Production backend

/// The MCP tools against the real app: its saved history (read only), its
/// Dictionary preferences, headless transcription, and `vocamac://` links
/// handed to the running app.
final class MCPProductionBackend: MCPBackend {
    private let transcriber: HeadlessTranscriber
    private let dictionary: DictionaryPreferences
    private let historyDirectory: URL?

    init(transcriber: HeadlessTranscriber, defaults: UserDefaults, historyDirectory: URL?) {
        self.transcriber = transcriber
        self.dictionary = DictionaryPreferences(defaults: defaults)
        self.historyDirectory = historyDirectory
    }

    func transcribe(path: String, model: String?, language: String?) async throws -> CLITranscriptionResponse {
        try await transcriber.transcribe(
            fileURL: URL(fileURLWithPath: path), modelOverride: model, languageOverride: language
        )
    }

    func listModels() -> CLIModelListResponse {
        transcriber.listModels()
    }

    func historyEntries() -> [DictationHistoryEntry] {
        guard let historyDirectory else { return [] }
        return DictationHistoryStore.readOnlyEntries(in: historyDirectory)
    }

    func dictionaryTerms() -> [String] {
        dictionary.vocabularyTerms
    }

    func dictionaryReplacements() -> [WordReplacement] {
        dictionary.replacements
    }

    func addDictionaryTerm(_ term: String, heard: String?) throws -> DictionaryPreferences.AddResult {
        let result = try dictionary.add(term: term, heard: heard)
        if result.addedTerm || result.addedReplacement {
            DictionaryPreferences.postExternalChange()
        }
        return result
    }

    func openAppLink(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
