// MCPServerTests.swift
// VocaMacTests

import XCTest
@testable import VocaMac

final class MCPServerTests: XCTestCase {
    private var backend: FakeMCPBackend!
    private var server: MCPServer!

    override func setUp() {
        super.setUp()
        backend = FakeMCPBackend()
        server = MCPServer(backend: backend, serverVersion: "9.9.9")
    }

    // MARK: - Helpers

    private func send(_ line: String) async throws -> JSONValue {
        let handled = await server.handle(line: line)
        let response = try XCTUnwrap(handled, "Expected a response to \(line)")
        XCTAssertFalse(response.contains("\n"), "A stdio message must be one line")
        return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    }

    private func call(_ tool: String, _ arguments: String = "{}", id: Int = 7) async throws -> JSONValue {
        try await send(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#)
    }

    private func entry(
        _ text: String, minutesAgo: Double, status: DictationHistoryStatus = .completed,
        app: String? = "Notes", raw: String? = nil, commandOriginal: String? = nil
    ) -> DictationHistoryEntry {
        DictationHistoryEntry(
            createdAt: Date(timeIntervalSinceNow: -minutesAgo * 60), status: status,
            rawText: raw ?? text, finalText: text, appName: app, modelID: "parakeet-tdt-0.6b-v2",
            language: "en", audioSeconds: 2.5, commandOriginal: commandOriginal
        )
    }

    // MARK: - Lifecycle

    func testInitializeNegotiatesASupportedVersionAndNamesTheServer() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        XCTAssertEqual(response["id"], .int(1))
        XCTAssertEqual(response["result"]?["protocolVersion"], .string("2025-03-26"))
        XCTAssertEqual(response["result"]?["serverInfo"]?["name"], .string("vocamac"))
        XCTAssertEqual(response["result"]?["serverInfo"]?["version"], .string("9.9.9"))
        XCTAssertNotNil(response["result"]?["capabilities"]?["tools"])
        XCTAssertNotNil(response["result"]?["capabilities"]?["resources"])
    }

    func testInitializeWithAnUnknownVersionAnswersWithTheNewest() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(response["id"], .string("a"))
        XCTAssertEqual(response["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]))
    }

    func testNotificationsGetNoResponse() async {
        let initialized = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(initialized)
        let blank = await server.handle(line: "   ")
        XCTAssertNil(blank)
    }

    func testPingAnswersWithAnEmptyResult() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        XCTAssertEqual(response["result"], .object([:]))
    }

    // MARK: - Protocol errors

    func testMalformedJSONIsAParseErrorWithANullID() async throws {
        let response = try await send("{not json")
        XCTAssertEqual(response["id"], .null)
        XCTAssertEqual(response["error"]?["code"], .int(-32700))
    }

    func testUnknownMethodEchoesTheID() async throws {
        let numeric = try await send(#"{"jsonrpc":"2.0","id":42,"method":"no/such"}"#)
        XCTAssertEqual(numeric["id"], .int(42))
        XCTAssertEqual(numeric["error"]?["code"], .int(-32601))

        let text = try await send(#"{"jsonrpc":"2.0","id":"req-9","method":"no/such"}"#)
        XCTAssertEqual(text["id"], .string("req-9"))
    }

    func testBatchesAndWrongVersionsAreInvalidRequests() async throws {
        let batch = try await send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)
        XCTAssertEqual(batch["error"]?["code"], .int(-32600))
        let wrongVersion = try await send(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(wrongVersion["error"]?["code"], .int(-32600))
        XCTAssertEqual(wrongVersion["id"], .int(1))
    }

    func testUnknownToolAndMissingArgumentAreInvalidParams() async throws {
        let unknown = try await call("format_disk")
        XCTAssertEqual(unknown["error"]?["code"], .int(-32602))
        let missing = try await call("search_history")
        XCTAssertEqual(missing["error"]?["code"], .int(-32602))
        let outOfRange = try await call("latest_dictation", #"{"count":500}"#)
        XCTAssertEqual(outOfRange["error"]?["code"], .int(-32602))
    }

    // MARK: - Tools

    func testToolsListNamesEveryTool() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let tools)? = response["result"]?["tools"] else { return XCTFail("No tools") }
        let names = tools.compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), Set(MCPToolName.allCases.map(\.rawValue)))
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], .string("object"))
            XCTAssertNotNil(tool["annotations"]?["readOnlyHint"])
        }
    }

    func testTranscribeFilePassesArgumentsAndReturnsTheTranscript() async throws {
        backend.transcription = CLITranscriptionResponse(
            text: "Hello there", model: "tiny", engine: "whisperkit",
            detectedLanguage: "en", durationSeconds: 0.4, audioLengthSeconds: 2
        )
        let response = try await call("transcribe_file", #"{"path":"~/a.wav","model":"tiny","language":"en"}"#)
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"]?["text"], .string("Hello there"))
        XCTAssertEqual(result["structuredContent"]?["audio_length_seconds"], .int(2))
        XCTAssertEqual(backend.transcribeRequests.first?.path, (("~/a.wav") as NSString).expandingTildeInPath)
        XCTAssertEqual(backend.transcribeRequests.first?.model, "tiny")
        XCTAssertEqual(backend.transcribeRequests.first?.language, "en")
        guard case .array(let content)? = result["content"] else { return XCTFail("No content") }
        XCTAssertTrue(content.first?["text"]?.stringValue?.contains("Hello there") ?? false)
    }

    func testTranscriptionFailureIsAToolError() async throws {
        backend.transcriptionError = CLIError(.modelNotDownloaded, "Model is not downloaded: small")
        let response = try await call("transcribe_file", #"{"path":"/tmp/a.wav"}"#)
        XCTAssertEqual(response["result"]?["isError"], .bool(true))
        guard case .array(let content)? = response["result"]?["content"] else { return XCTFail("No content") }
        XCTAssertEqual(content.first?["text"], .string("model_not_downloaded: Model is not downloaded: small"))
    }

    func testListModelsReturnsTheCatalog() async throws {
        backend.models = CLIModelListResponse(models: [
            CLIModelResponse(id: "tiny", name: "Tiny", engine: "whisperkit", selected: true,
                             downloaded: true, supported: true, systemManaged: false),
        ])
        let response = try await call("list_models")
        guard case .array(let models)? = response["result"]?["structuredContent"]?["models"] else { return XCTFail("No models") }
        XCTAssertEqual(models.first?["id"], .string("tiny"))
        XCTAssertEqual(models.first?["system_managed"], .bool(false))
    }

    func testLatestDictationSkipsFailuresEditsAndEmptyText() async throws {
        backend.history = [
            entry("newest", minutesAgo: 1),
            entry("", minutesAgo: 2),
            entry("broken", minutesAgo: 3, status: .failed),
            entry("Shorter.", minutesAgo: 4, commandOriginal: "A much longer sentence."),
            entry("older", minutesAgo: 5, raw: "older um"),
        ]
        let one = try await call("latest_dictation")
        guard case .array(let first)? = one["result"]?["structuredContent"]?["dictations"] else { return XCTFail("No dictations") }
        XCTAssertEqual(first.map { $0["text"] }, [.string("newest")])

        let several = try await call("latest_dictation", #"{"count":5}"#)
        guard case .array(let all)? = several["result"]?["structuredContent"]?["dictations"] else { return XCTFail("No dictations") }
        XCTAssertEqual(all.map { $0["text"] }, [.string("newest"), .string("older")])
        XCTAssertEqual(all.last?["raw_text"], .string("older um"))
        XCTAssertEqual(all.last?["app"], .string("Notes"))
        XCTAssertNil(all.first?["raw_text"], "Unedited text has no separate raw text")
    }

    func testSearchHistoryMatchesEveryWordAndHonoursTheLimit() async throws {
        backend.history = [
            entry("ship the release notes", minutesAgo: 1, app: "Mail"),
            entry("release party", minutesAgo: 2, app: "Mail"),
            entry("notes about the release", minutesAgo: 3, app: "Slack"),
        ]
        let response = try await call("search_history", #"{"query":"release notes","limit":5}"#)
        guard case .array(let matches)? = response["result"]?["structuredContent"]?["dictations"] else { return XCTFail("No matches") }
        XCTAssertEqual(matches.map { $0["text"] }, [.string("ship the release notes"), .string("notes about the release")])

        let limited = try await call("search_history", #"{"query":"release","limit":1}"#)
        guard case .array(let first)? = limited["result"]?["structuredContent"]?["dictations"] else { return XCTFail("No matches") }
        XCTAssertEqual(first.count, 1)
    }

    func testDictionaryTermsListsTermsAndReplacements() async throws {
        backend.terms = ["VocaMac", "kubectl"]
        backend.replacements = [WordReplacement(heard: "get hub, git hub", replacement: "GitHub")]
        let response = try await call("dictionary_terms")
        let structured = try XCTUnwrap(response["result"]?["structuredContent"])
        XCTAssertEqual(structured["terms"], .array([.string("VocaMac"), .string("kubectl")]))
        guard case .array(let replacements)? = structured["replacements"] else { return XCTFail("No replacements") }
        XCTAssertEqual(replacements.first?["heard"], .array([.string("get hub"), .string("git hub")]))
        XCTAssertEqual(replacements.first?["replacement"], .string("GitHub"))
    }

    func testAddDictionaryTermReportsWhatChanged() async throws {
        let response = try await call("add_dictionary_term", #"{"term":"kubectl","heard":"cube cuddle"}"#)
        XCTAssertEqual(response["result"]?["structuredContent"]?["added_term"], .bool(true))
        XCTAssertEqual(response["result"]?["structuredContent"]?["added_replacement"], .bool(true))
        XCTAssertEqual(backend.terms, ["kubectl"])
        XCTAssertEqual(backend.replacements.first?.replacement, "kubectl")
    }

    func testAddDictionaryTermRejectsSeparatorsAsAToolError() async throws {
        let response = try await call("add_dictionary_term", #"{"term":"one, two"}"#)
        XCTAssertEqual(response["result"]?["isError"], .bool(true))
        XCTAssertTrue(backend.terms.isEmpty)
    }

    func testStartAndStopOpenTheAppLinks() async throws {
        _ = try await call("start_dictation")
        _ = try await call("stop_dictation")
        XCTAssertEqual(backend.openedLinks.map(\.absoluteString), ["vocamac://dictate/start", "vocamac://dictate/stop"])
        // Both links parse to what the app expects.
        XCTAssertEqual(backend.openedLinks.compactMap(VocaDeepLink.init(url:)), [.startDictation, .stopDictation])
    }

    func testStartWhenTheAppCannotBeReachedIsAToolError() async throws {
        backend.opensLinks = false
        let response = try await call("start_dictation")
        XCTAssertEqual(response["result"]?["isError"], .bool(true))
    }

    // MARK: - Resources

    func testResourcesListAndReadADictation() async throws {
        let dictation = entry("Send the report", minutesAgo: 1, raw: "um send the report")
        backend.history = [dictation, entry("nope", minutesAgo: 2, status: .failed)]
        let list = try await send(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        guard case .array(let resources)? = list["result"]?["resources"] else { return XCTFail("No resources") }
        XCTAssertEqual(resources.count, 1)
        let uri = try XCTUnwrap(resources.first?["uri"]?.stringValue)
        XCTAssertEqual(uri, "vocamac://history/\(dictation.id.uuidString)")

        let read = try await send(#"{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"\#(uri)"}}"#)
        guard case .array(let contents)? = read["result"]?["contents"] else { return XCTFail("No contents") }
        let text = try XCTUnwrap(contents.first?["text"]?.stringValue)
        XCTAssertTrue(text.contains("Send the report"))
        XCTAssertTrue(text.contains("um send the report"))
    }

    func testReadingAnUnknownResourceIsNotFound() async throws {
        let response = try await send(#"{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"vocamac://history/\#(UUID().uuidString)"}}"#)
        XCTAssertEqual(response["error"]?["code"], .int(-32002))
        XCTAssertEqual(response["id"], .int(5))
    }

    // MARK: - CLI

    func testSetupCommandQuotesPathsWithSpaces() {
        XCTAssertEqual(
            MCPSetup.claudeCodeCommand(executablePath: "/Applications/VocaMac.app/Contents/MacOS/VocaMac"),
            "claude mcp add vocamac -- /Applications/VocaMac.app/Contents/MacOS/VocaMac --mcp"
        )
        XCTAssertEqual(
            MCPSetup.claudeCodeCommand(executablePath: "/Users/me/My Apps/VocaMac.app/Contents/MacOS/VocaMac"),
            "claude mcp add vocamac -- '/Users/me/My Apps/VocaMac.app/Contents/MacOS/VocaMac' --mcp"
        )
        XCTAssertEqual(MCPSetup.shellQuoted("it's"), "'it'\\''s'")
    }

    func testMCPFlagParsesAloneAndRoutesToCLI() throws {
        XCTAssertEqual(try CLICommand.parse(arguments: ["--mcp"]), .mcpServer)
        XCTAssertEqual(CLICommand.invocationMode(arguments: ["--mcp"]), .cli)
        XCTAssertThrowsError(try CLICommand.parse(arguments: ["--mcp", "--json"]))
    }
}

// MARK: - Dictionary preferences

final class DictionaryPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "VocaMac-DictionaryPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAddingATermReplacesADifferentlyCasedCopy() throws {
        defaults.set("Github\nVocaMac", forKey: DictionaryPreferences.vocabularyKey)
        let preferences = DictionaryPreferences(defaults: defaults)
        let result = try preferences.add(term: "GitHub", heard: nil)
        XCTAssertEqual(result, .init(addedTerm: true, addedReplacement: false))
        XCTAssertEqual(preferences.vocabularyTerms, ["VocaMac", "GitHub"])
    }

    func testAddingAnExistingTermChangesNothing() throws {
        defaults.set("VocaMac", forKey: DictionaryPreferences.vocabularyKey)
        let result = try DictionaryPreferences(defaults: defaults).add(term: "VocaMac", heard: "voca mac")
        // "voca mac" spells VocaMac already; the vocabulary fixes the spacing.
        XCTAssertEqual(result, .init(addedTerm: false, addedReplacement: false))
    }

    func testHeardFormsMergeIntoTheExistingReplacement() throws {
        let preferences = DictionaryPreferences(defaults: defaults)
        try preferences.add(term: "kubectl", heard: "cube cuddle")
        try preferences.add(term: "kubectl", heard: "cube control")
        try preferences.add(term: "kubectl", heard: "Cube Cuddle")
        XCTAssertEqual(preferences.replacements.count, 1)
        XCTAssertEqual(preferences.replacements.first?.heardForms, ["cube cuddle", "cube control"])
    }

    func testEmptyTermsAreRefused() {
        XCTAssertThrowsError(try DictionaryPreferences(defaults: defaults).add(term: "  ", heard: nil)) { error in
            XCTAssertEqual(error as? DictionaryPreferencesError, .emptyTerm)
        }
    }

    @MainActor
    func testTheAppReloadsReplacementsWrittenElsewhere() throws {
        let state = AppState.makeTestState().appState
        try DictionaryPreferences(defaults: defaults).add(term: "kubectl", heard: "cube cuddle")
        state.reloadDictionaryFromPreferences(defaults: defaults)
        XCTAssertEqual(state.wordReplacements.map(\.replacement), ["kubectl"])
    }
}

// MARK: - Read-only history

@MainActor
final class HistoryReadOnlyTests: XCTestCase {
    func testReadOnlyEntriesReplayTheJournalWithoutWriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VocaMac-RO-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = DictationHistoryStore(directory: directory)
        let first = await store.begin(
            audio: nil, target: nil, modelID: "tiny", language: "en", audioSeconds: 1, now: Date(timeIntervalSinceNow: -60)
        )
        store.complete(first, rawText: "hello", finalText: "Hello.", summary: nil, language: "en", transcriptionSeconds: 0.1, keepAudio: false)
        let second = await store.begin(audio: nil, target: nil, modelID: "tiny", language: "en", audioSeconds: 1)

        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let entries = DictationHistoryStore.readOnlyEntries(in: directory)
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()

        XCTAssertEqual(before, after, "Reading must not compact or create files")
        XCTAssertEqual(entries.map(\.id), [second, first])
        XCTAssertEqual(entries.last?.finalText, "Hello.")
        XCTAssertEqual(entries.first?.status, .pending, "Another process sees an in-flight dictation as it is")
    }

    func testMissingHistoryReadsAsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("VocaMac-none-\(UUID().uuidString)")
        XCTAssertTrue(DictationHistoryStore.readOnlyEntries(in: missing).isEmpty)
    }
}

// MARK: - Fake backend

private final class FakeMCPBackend: MCPBackend {
    var transcription = CLITranscriptionResponse(
        text: "", model: "tiny", engine: "whisperkit", detectedLanguage: "en", durationSeconds: 0, audioLengthSeconds: 0
    )
    var transcriptionError: Error?
    var transcribeRequests: [(path: String, model: String?, language: String?)] = []
    var models = CLIModelListResponse(models: [])
    var history: [DictationHistoryEntry] = []
    var terms: [String] = []
    var replacements: [WordReplacement] = []
    var openedLinks: [URL] = []
    var opensLinks = true

    func transcribe(path: String, model: String?, language: String?) async throws -> CLITranscriptionResponse {
        transcribeRequests.append((path, model, language))
        if let transcriptionError { throw transcriptionError }
        return transcription
    }

    func listModels() -> CLIModelListResponse { models }
    func historyEntries() -> [DictationHistoryEntry] { history }
    func dictionaryTerms() -> [String] { terms }
    func dictionaryReplacements() -> [WordReplacement] { replacements }

    func addDictionaryTerm(_ term: String, heard: String?) throws -> DictionaryPreferences.AddResult {
        let defaults = UserDefaults(suiteName: "VocaMac-FakeMCP-\(UUID().uuidString)") ?? .standard
        defaults.set(terms.joined(separator: "\n"), forKey: DictionaryPreferences.vocabularyKey)
        defaults.set(try JSONEncoder().encode(replacements), forKey: DictionaryPreferences.replacementsKey)
        let preferences = DictionaryPreferences(defaults: defaults)
        let result = try preferences.add(term: term, heard: heard)
        terms = preferences.vocabularyTerms
        replacements = preferences.replacements
        return result
    }

    func openAppLink(_ url: URL) -> Bool {
        guard opensLinks else { return false }
        openedLinks.append(url)
        return true
    }
}
