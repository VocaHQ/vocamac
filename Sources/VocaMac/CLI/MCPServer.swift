// MCPServer.swift
// VocaMac
//
// A Model Context Protocol server over stdio (`VocaMac --mcp`), so a local
// coding agent (Claude Code, Cursor, Codex) can transcribe files, read the
// user's dictations and Dictionary, add terms, and ask the running app to
// start or stop dictating. JSON-RPC 2.0, one message per line, no network
// listener. Like the rest of the CLI it never constructs `AppState`.

import Foundation

// MARK: - Backend

/// What the tools act on. Production reads the app's files and preferences
/// (`MCPProductionBackend`); tests inject a fake.
protocol MCPBackend: AnyObject {
    func transcribe(path: String, model: String?, language: String?) async throws -> CLITranscriptionResponse
    func listModels() -> CLIModelListResponse
    /// Saved dictations, newest first.
    func historyEntries() -> [DictationHistoryEntry]
    func dictionaryTerms() -> [String]
    func dictionaryReplacements() -> [WordReplacement]
    func addDictionaryTerm(_ term: String, heard: String?) throws -> DictionaryPreferences.AddResult
    /// Hand a `vocamac://` link to the running app. False when nothing took it.
    func openAppLink(_ url: URL) -> Bool
}

// MARK: - Server

/// Answers one JSON-RPC message at a time. Stateless apart from whether the
/// client has initialized, which only affects logging: requests before
/// `initialize` are still answered, as most servers do.
final class MCPServer {
    /// Protocol revisions this server speaks, newest first. A client asking
    /// for one of these gets it; any other gets the newest.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// JSON-RPC and MCP error codes.
    enum ErrorCode: Int {
        case parseError = -32700
        case invalidRequest = -32600
        case methodNotFound = -32601
        case invalidParams = -32602
        case internalError = -32603
        case resourceNotFound = -32002
    }

    private let backend: MCPBackend
    private let serverVersion: String
    private let encoder: JSONEncoder
    private(set) var negotiatedProtocolVersion: String?

    init(backend: MCPBackend, serverVersion: String) {
        self.backend = backend
        self.serverVersion = serverVersion
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    // MARK: Messages

    /// The response line for one input line, without its newline, or nil
    /// for a notification (and for a blank line).
    func handle(line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let message: JSONValue
        do {
            message = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
        } catch {
            return encode(Self.errorResponse(id: .null, code: .parseError, message: "Parse error: the line is not JSON."))
        }
        guard let response = await handle(message: message) else { return nil }
        return encode(response)
    }

    /// The response to one decoded message, or nil for a notification.
    func handle(message: JSONValue) async -> JSONValue? {
        guard case .object(let members) = message else {
            // Batches were removed from MCP in 2025-06-18.
            return Self.errorResponse(id: .null, code: .invalidRequest, message: "Invalid request: expected one JSON-RPC object.")
        }
        let id = members["id"]
        guard members["jsonrpc"]?.stringValue == "2.0", let method = members["method"]?.stringValue else {
            // A response from the client (it has no method) needs no answer.
            if members["method"] == nil, members["result"] != nil || members["error"] != nil { return nil }
            return Self.errorResponse(id: id ?? .null, code: .invalidRequest, message: "Invalid request: jsonrpc must be \"2.0\" and method a string.")
        }
        // A notification has no id and never gets a response.
        guard let id, Self.isValidID(id) else {
            if id != nil {
                return Self.errorResponse(id: .null, code: .invalidRequest, message: "Invalid request: id must be a string or an integer.")
            }
            handleNotification(method)
            return nil
        }
        let params = members["params"] ?? .object([:])
        do {
            let result = try await dispatch(method: method, params: params)
            return .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
        } catch let error as MCPRequestError {
            return Self.errorResponse(id: id, code: error.code, message: error.message)
        } catch {
            return Self.errorResponse(id: id, code: .internalError, message: error.localizedDescription)
        }
    }

    private static func isValidID(_ id: JSONValue) -> Bool {
        switch id {
        case .string, .int: return true
        default: return false
        }
    }

    private func handleNotification(_ method: String) {
        switch method {
        case "notifications/initialized":
            VocaLogger.info(.general, "MCP client initialized (protocol \(negotiatedProtocolVersion ?? "unknown"))")
        case "notifications/cancelled":
            // Requests are answered one at a time, so by the time this is read
            // the request it names has already been answered.
            break
        default:
            VocaLogger.debug(.general, "MCP notification ignored: \(method)")
        }
    }

    private func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize": return initialize(params: params)
        case "ping": return .object([:])
        case "tools/list": return .object(["tools": .array(MCPTools.definitions.map(\.json))])
        case "tools/call": return try await callTool(params: params)
        case "resources/list": return listResources()
        case "resources/read": return try readResource(params: params)
        case "resources/templates/list":
            return .object(["resourceTemplates": .array([MCPTools.historyResourceTemplate])])
        default:
            throw MCPRequestError(.methodNotFound, "Method not found: \(method)")
        }
    }

    // MARK: Lifecycle

    private func initialize(params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        negotiatedProtocolVersion = version
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
                "resources": .object(["listChanged": .bool(false), "subscribe": .bool(false)]),
            ]),
            "serverInfo": .object([
                "name": .string("vocamac"),
                "title": .string("VocaMac"),
                "version": .string(serverVersion),
            ]),
            "instructions": .string(MCPTools.instructions),
        ])
    }

    // MARK: Tools

    private func callTool(params: JSONValue) async throws -> JSONValue {
        guard let name = params["name"]?.stringValue else {
            throw MCPRequestError(.invalidParams, "tools/call needs a tool name.")
        }
        guard let tool = MCPTools.tool(named: name) else {
            throw MCPRequestError(.invalidParams, "Unknown tool: \(name)")
        }
        let arguments = params["arguments"] ?? .object([:])
        guard case .object = arguments else {
            throw MCPRequestError(.invalidParams, "Arguments must be an object.")
        }
        do {
            let output = try await MCPTools.run(tool, arguments: arguments, backend: backend)
            return Self.toolResult(output, isError: false)
        } catch let error as MCPRequestError {
            // Arguments that don't match the schema are the client's mistake.
            throw error
        } catch let error as MCPToolError {
            return Self.toolResult(.text(error.message), isError: true)
        } catch let error as CLIError {
            return Self.toolResult(.text("\(error.category.rawValue): \(error.message)"), isError: true)
        } catch {
            return Self.toolResult(.text(error.localizedDescription), isError: true)
        }
    }

    /// A tool's answer as MCP content: the structured value, and the same
    /// value as JSON text for clients that only read text blocks.
    private static func toolResult(_ output: MCPToolOutput, isError: Bool) -> JSONValue {
        var result: [String: JSONValue] = ["isError": .bool(isError)]
        switch output {
        case .text(let text):
            result["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
        case .structured(let value):
            result["content"] = .array([.object(["type": .string("text"), "text": .string(prettyText(value))])])
            result["structuredContent"] = value
        }
        return .object(result)
    }

    private static func prettyText(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    // MARK: Resources

    /// How many dictations `resources/list` names. Older ones are still
    /// readable by URI and searchable with the `search_history` tool.
    static let listedResourceLimit = 100

    private func listResources() -> JSONValue {
        let entries = backend.historyEntries()
            .filter { $0.status == .completed && !$0.displayText.isEmpty }
            .prefix(Self.listedResourceLimit)
        return .object(["resources": .array(entries.map(MCPTools.resourceDescriptor(for:)))])
    }

    private func readResource(params: JSONValue) throws -> JSONValue {
        guard let uri = params["uri"]?.stringValue else {
            throw MCPRequestError(.invalidParams, "resources/read needs a uri.")
        }
        guard let id = MCPTools.historyEntryID(fromURI: uri),
              let entry = backend.historyEntries().first(where: { $0.id == id }) else {
            throw MCPRequestError(.resourceNotFound, "Resource not found: \(uri)")
        }
        return .object(["contents": .array([.object([
            "uri": .string(uri),
            "mimeType": .string("text/markdown"),
            "text": .string(MCPTools.markdown(for: entry)),
        ])])])
    }

    // MARK: Encoding

    static func errorResponse(id: JSONValue, code: ErrorCode, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object(["code": .int(code.rawValue), "message": .string(message)]),
        ])
    }

    private func encode(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value), let line = String(data: data, encoding: .utf8) else {
            return #"{"error":{"code":-32603,"message":"Could not encode the response."},"id":null,"jsonrpc":"2.0"}"#
        }
        return line
    }
}

/// A request the server refuses with a JSON-RPC error.
struct MCPRequestError: Error {
    let code: MCPServer.ErrorCode
    let message: String

    init(_ code: MCPServer.ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
