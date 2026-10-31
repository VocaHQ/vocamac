// MCPTools.swift
// VocaMac
//
// The tools and resources the MCP server offers, their input schemas, and
// how each runs against an `MCPBackend`.

import Foundation

/// What a tool returns: plain text, or a JSON value (sent as structured
/// content and as the same JSON in a text block).
enum MCPToolOutput: Equatable {
    case text(String)
    case structured(JSONValue)
}

/// A tool that ran but could not do what was asked. Reported to the client
/// as a tool result with `isError`, so the agent can read why and adjust.
struct MCPToolError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// One tool as listed by `tools/list`.
struct MCPToolDefinition {
    let name: MCPToolName
    let title: String
    let description: String
    let inputSchema: JSONValue
    /// Reads only; changes nothing in VocaMac or on disk.
    let isReadOnly: Bool

    var json: JSONValue {
        .object([
            "name": .string(name.rawValue),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": .object([
                "title": .string(title),
                "readOnlyHint": .bool(isReadOnly),
                "destructiveHint": .bool(false),
                "idempotentHint": .bool(isReadOnly),
                // Nothing here reaches beyond this Mac.
                "openWorldHint": .bool(false),
            ]),
        ])
    }
}

enum MCPToolName: String, CaseIterable {
    case transcribeFile = "transcribe_file"
    case listModels = "list_models"
    case latestDictation = "latest_dictation"
    case searchHistory = "search_history"
    case dictionaryTerms = "dictionary_terms"
    case addDictionaryTerm = "add_dictionary_term"
    case startDictation = "start_dictation"
    case stopDictation = "stop_dictation"
}

enum MCPTools {
    static let instructions = """
    VocaMac is the user's on-device dictation app. Everything here stays on this Mac: \
    transcription runs locally and nothing is uploaded. Use latest_dictation or \
    search_history to read what the user dictated, dictionary_terms to learn how they \
    spell names and jargon, and add_dictionary_term when they correct a spelling. \
    start_dictation and stop_dictation ask the running app to record; the user confirms \
    the first time.
    """

    // MARK: Limits

    static let maximumResults = 50
    static let defaultSearchLimit = 10

    // MARK: Definitions

    static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: .transcribeFile,
            title: "Transcribe an audio file",
            description: "Transcribe an audio or video file on this Mac with a downloaded VocaMac speech model. "
                + "Omit model and language to use the ones selected in VocaMac. Never downloads a model.",
            inputSchema: schema(
                properties: [
                    "path": stringProperty("Absolute path to the audio or video file (a leading ~ is expanded)."),
                    "model": stringProperty("Model id from list_models, for this request only."),
                    "language": stringProperty("Language code such as en or de, or auto."),
                ],
                required: ["path"]
            ),
            isReadOnly: true
        ),
        MCPToolDefinition(
            name: .listModels,
            title: "List speech models",
            description: "Every speech model VocaMac knows, with whether it is selected, downloaded, and supported on this Mac.",
            inputSchema: schema(properties: [:], required: []),
            isReadOnly: true
        ),
        MCPToolDefinition(
            name: .latestDictation,
            title: "Latest dictations",
            description: "The user's most recent dictations from VocaMac History, newest first: the text that was typed, "
                + "what the engine heard when cleanup changed it, the app it went to, and when.",
            inputSchema: schema(
                properties: ["count": integerProperty("How many to return, 1 to \(maximumResults). Default 1.")],
                required: []
            ),
            isReadOnly: true
        ),
        MCPToolDefinition(
            name: .searchHistory,
            title: "Search dictation history",
            description: "Dictations whose text or app name contains every word of the query, newest first.",
            inputSchema: schema(
                properties: [
                    "query": stringProperty("Words to look for."),
                    "limit": integerProperty("Most results to return, 1 to \(maximumResults). Default \(defaultSearchLimit)."),
                ],
                required: ["query"]
            ),
            isReadOnly: true
        ),
        MCPToolDefinition(
            name: .dictionaryTerms,
            title: "Dictionary",
            description: "The user's Dictionary: vocabulary terms spelled their way, and replacements from what an engine "
                + "hears to what the user means.",
            inputSchema: schema(properties: [:], required: []),
            isReadOnly: true
        ),
        MCPToolDefinition(
            name: .addDictionaryTerm,
            title: "Add a Dictionary term",
            description: "Add a term to the user's Dictionary so dictation spells it their way. Give heard as well when "
                + "the engine writes it as different words (heard \"cube cuddle\", term \"kubectl\").",
            inputSchema: schema(
                properties: [
                    "term": stringProperty("The spelling to use, exactly."),
                    "heard": stringProperty("What the engine writes instead, if it differs by more than case and spacing."),
                ],
                required: ["term"]
            ),
            isReadOnly: false
        ),
        MCPToolDefinition(
            name: .startDictation,
            title: "Start dictating",
            description: "Ask the running VocaMac to start recording, as if the user pressed the dictation shortcut. "
                + "VocaMac asks the user to confirm the first time an app does this.",
            inputSchema: schema(properties: [:], required: []),
            isReadOnly: false
        ),
        MCPToolDefinition(
            name: .stopDictation,
            title: "Stop dictating",
            description: "Ask the running VocaMac to stop recording and type the transcript where the cursor is.",
            inputSchema: schema(properties: [:], required: []),
            isReadOnly: false
        ),
    ]

    static func tool(named name: String) -> MCPToolDefinition? {
        definitions.first { $0.name.rawValue == name }
    }

    // MARK: Running

    static func run(_ tool: MCPToolDefinition, arguments: JSONValue, backend: MCPBackend) async throws -> MCPToolOutput {
        switch tool.name {
        case .transcribeFile:
            let path = try requiredString("path", in: arguments)
            let response = try await backend.transcribe(
                path: expandedPath(path),
                model: try optionalString("model", in: arguments),
                language: try optionalString("language", in: arguments)
            )
            return .structured(try JSONValue.encoding(response))
        case .listModels:
            return .structured(try JSONValue.encoding(backend.listModels()))
        case .latestDictation:
            let count = try optionalInt("count", in: arguments, range: 1...maximumResults) ?? 1
            let entries = backend.historyEntries()
                .filter { $0.status == .completed && !$0.isCommandEdit && !$0.displayText.isEmpty }
                .prefix(count)
            return .structured(.object(["dictations": .array(entries.map(json(for:)))]))
        case .searchHistory:
            let query = try requiredString("query", in: arguments)
            let limit = try optionalInt("limit", in: arguments, range: 1...maximumResults) ?? defaultSearchLimit
            let matches = DictationHistoryStore.entries(backend.historyEntries(), matching: query)
                .filter { !$0.displayText.isEmpty }
                .prefix(limit)
            return .structured(.object(["dictations": .array(matches.map(json(for:)))]))
        case .dictionaryTerms:
            let replacements = backend.dictionaryReplacements().filter(\.isValid).map { replacement in
                JSONValue.object([
                    "heard": .array(replacement.heardForms.map(JSONValue.string)),
                    "replacement": .string(replacement.replacement),
                ])
            }
            return .structured(.object([
                "terms": .array(backend.dictionaryTerms().map(JSONValue.string)),
                "replacements": .array(replacements),
            ]))
        case .addDictionaryTerm:
            let term = try requiredString("term", in: arguments)
            let heard = try optionalString("heard", in: arguments)
            let result: DictionaryPreferences.AddResult
            do {
                result = try backend.addDictionaryTerm(term, heard: heard)
            } catch let error as DictionaryPreferencesError {
                throw MCPToolError(error.localizedDescription)
            }
            return .structured(.object([
                "term": .string(term.trimmingCharacters(in: .whitespacesAndNewlines)),
                "added_term": .bool(result.addedTerm),
                "added_replacement": .bool(result.addedReplacement),
            ]))
        case .startDictation:
            return try openLink("vocamac://dictate/start", backend: backend, done: "Asked VocaMac to start dictating.")
        case .stopDictation:
            return try openLink("vocamac://dictate/stop", backend: backend, done: "Asked VocaMac to stop dictating and type the transcript.")
        }
    }

    private static func openLink(_ link: String, backend: MCPBackend, done: String) throws -> MCPToolOutput {
        guard let url = URL(string: link), backend.openAppLink(url) else {
            throw MCPToolError("Could not reach VocaMac. Open the app and try again.")
        }
        return .text(done + " If VocaMac asks, the user has to confirm it in the app.")
    }

    // MARK: History as JSON

    static func json(for entry: DictationHistoryEntry) -> JSONValue {
        var members: [String: JSONValue] = [
            "id": .string(entry.id.uuidString),
            "uri": .string(historyURI(for: entry.id)),
            "created_at": .string(entry.createdAt.formatted(.iso8601)),
            "status": .string(entry.status.rawValue),
            "text": .string(entry.displayText),
            "model": .string(entry.modelID),
            "audio_seconds": .double((entry.audioSeconds * 100).rounded() / 100),
        ]
        if entry.hasEditedOutput { members["raw_text"] = .string(entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let original = entry.commandOriginal { members["text_before_edit"] = .string(original) }
        if let app = entry.appName { members["app"] = .string(app) }
        if let language = entry.language { members["language"] = .string(language) }
        return .object(members)
    }

    // MARK: Resources

    static let historyURIPrefix = "vocamac://history/"

    static func historyURI(for id: UUID) -> String {
        historyURIPrefix + id.uuidString
    }

    static func historyEntryID(fromURI uri: String) -> UUID? {
        guard uri.lowercased().hasPrefix(historyURIPrefix) else { return nil }
        return UUID(uuidString: String(uri.dropFirst(historyURIPrefix.count)))
    }

    static let historyResourceTemplate: JSONValue = .object([
        "uriTemplate": .string(historyURIPrefix + "{id}"),
        "name": .string("Dictation"),
        "description": .string("One dictation from VocaMac History: what was typed and what was heard."),
        "mimeType": .string("text/markdown"),
    ])

    static func resourceDescriptor(for entry: DictationHistoryEntry) -> JSONValue {
        let preview = entry.displayText.prefix(60)
        return .object([
            "uri": .string(historyURI(for: entry.id)),
            "name": .string("dictation-\(entry.id.uuidString.prefix(8).lowercased())"),
            "title": .string(preview.count < entry.displayText.count ? preview + "…" : String(preview)),
            "description": .string("Dictated \(entry.createdAt.formatted(.iso8601))"
                + (entry.appName.map { " into \($0)" } ?? "")),
            "mimeType": .string("text/markdown"),
        ])
    }

    /// One dictation as Markdown, for `resources/read`.
    static func markdown(for entry: DictationHistoryEntry) -> String {
        var lines = ["# Dictation", ""]
        lines.append("- When: \(entry.createdAt.formatted(.iso8601))")
        if let app = entry.appName { lines.append("- App: \(app)") }
        lines.append("- Status: \(entry.status.displayName)")
        if let language = entry.language { lines.append("- Language: \(language)") }
        lines.append("- Model: \(entry.modelID)")
        lines += ["", "## Text", "", entry.displayText]
        if entry.hasEditedOutput {
            lines += ["", "## What was heard", "", entry.rawText.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        if let original = entry.commandOriginal {
            lines += ["", "## Text before the edit", "", original]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Arguments

    private static func requiredString(_ key: String, in arguments: JSONValue) throws -> String {
        guard let value = arguments[key]?.stringValue,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPRequestError(.invalidParams, "Missing required argument: \(key)")
        }
        return value
    }

    private static func optionalString(_ key: String, in arguments: JSONValue) throws -> String? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let string = value.stringValue else {
            throw MCPRequestError(.invalidParams, "\(key) must be a string.")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func optionalInt(_ key: String, in arguments: JSONValue, range: ClosedRange<Int>) throws -> Int? {
        guard let value = arguments[key], !value.isNull else { return nil }
        guard let number = value.intValue, range.contains(number) else {
            throw MCPRequestError(.invalidParams, "\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }

    static func expandedPath(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }

    // MARK: Schema helpers

    private static func schema(properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    private static func stringProperty(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integerProperty(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}
