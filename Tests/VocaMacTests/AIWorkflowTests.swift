import XCTest
@testable import VocaMac

private struct StubCleanupCredentials: CleanupCredentialStoring {
    let apiKey: String?
    func readAPIKey() -> String? { apiKey }
    func saveAPIKey(_ value: String) throws {}
    func deleteAPIKey() throws {}
}

private final class StubCleanupURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handlerLock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func install(_ value: @escaping Handler) {
        handlerLock.withLock { handler = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.handlerLock.withLock { Self.handler }
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class AIConfigurationTests: XCTestCase {
    func testLocalProvidersResolveTheirCompatibleDefaults() {
        let ollama = CleanupEndpointConfiguration(provider: .ollama)
        XCTAssertEqual(ollama.resolvedBaseURL, "http://127.0.0.1:11434/v1")
        XCTAssertEqual(ollama.resolvedModel, "qwen2.5:3b")
        XCTAssertEqual(ollama.chatCompletionsURL?.absoluteString, "http://127.0.0.1:11434/v1/chat/completions")
    }

    func testLocalNetworkMachineCanUsePlainHTTP() {
        for base in ["http://192.168.1.20:11434/v1", "http://studio.local:1234/v1", "http://gpu-box:8000/v1"] {
            let configuration = CleanupEndpointConfiguration(
                provider: .openAICompatible, baseURL: base, model: "example"
            )
            XCTAssertNil(configuration.validationProblem(), base)
        }
        let configuration = CleanupEndpointConfiguration(
            provider: .openAICompatible, baseURL: "http://192.168.1.20:11434/v1", model: "example"
        )
        XCTAssertEqual(
            configuration.chatCompletionsURL?.absoluteString,
            "http://192.168.1.20:11434/v1/chat/completions"
        )
    }

    func testPublicEndpointRequiresHTTPS() {
        let configuration = CleanupEndpointConfiguration(
            provider: .openAICompatible,
            baseURL: "http://cleanup.example.com/v1",
            model: "example"
        )
        XCTAssertNotNil(configuration.validationProblem())
        XCTAssertNil(configuration.chatCompletionsURL)
        XCTAssertFalse(CleanupEndpointConfiguration.isLocalNetworkHost("8.8.8.8"))
        XCTAssertFalse(CleanupEndpointConfiguration.isLocalNetworkHost("172.32.0.1"))
        XCTAssertTrue(CleanupEndpointConfiguration.isLocalNetworkHost("172.20.0.1"))
    }

    func testCommandModeEngineResolution() {
        XCTAssertEqual(
            CommandModeEngine.resolve(stored: "", endpointIsConfigured: false, appleIntelligenceAvailable: false),
            .local(.qwen25_1_5b_q4_k_m)
        )
        XCTAssertEqual(
            CommandModeEngine.resolve(stored: "", endpointIsConfigured: false, appleIntelligenceAvailable: true),
            .appleIntelligence
        )
        XCTAssertEqual(
            CommandModeEngine.resolve(stored: "", endpointIsConfigured: true, appleIntelligenceAvailable: true),
            .endpoint
        )
        XCTAssertEqual(
            CommandModeEngine.resolve(
                stored: CleanupModelKind.qwen3_4b_instruct_2507_q4_k_m.rawValue,
                endpointIsConfigured: true, appleIntelligenceAvailable: true
            ),
            .local(.qwen3_4b_instruct_2507_q4_k_m)
        )
        // A stale endpoint choice falls back once the endpoint is switched off.
        XCTAssertEqual(
            CommandModeEngine.resolve(stored: "endpoint", endpointIsConfigured: false, appleIntelligenceAvailable: false),
            .local(.qwen25_1_5b_q4_k_m)
        )
        // Compact cleanup models are not offered for editing commands.
        XCTAssertNil(CommandModeEngine(storageValue: CleanupModelKind.qwen25_0_5b_q4_k_m.rawValue))
    }

    func testCommandModeModelsArePinned() {
        for kind in CleanupModelKind.commandModeChoices {
            let descriptor = kind.descriptor
            XCTAssertEqual(descriptor.kind, kind)
            XCTAssertEqual(descriptor.expectedSHA256.count, 64)
            XCTAssertTrue(descriptor.url.absoluteString.contains("/resolve/"))
            XCTAssertTrue(descriptor.url.lastPathComponent == descriptor.fileName)
        }
        XCTAssertFalse(CleanupModelKind.cleanupChoices.contains(.qwen25_7b_q4_k_m))
        // Only the model in both lists is labelled as shared.
        XCTAssertEqual(CleanupModelKind.allCases.filter(\.isShared), [.qwen25_1_5b_q4_k_m])
    }

    func testEndpointAndWebsiteRulesRoundTrip() {
        let configuration = CleanupEndpointConfiguration(
            provider: .lmStudio,
            baseURL: "http://localhost:1234/v1/",
            model: "local-model"
        )
        XCTAssertEqual(CleanupEndpointConfiguration.decode(configuration.encoded()), configuration)

        let binding = WebsiteStyleBinding(
            hostPattern: "*.example.com", displayName: "Example",
            style: .email, cleanupLevel: .light, cleanupPrompt: "Keep it crisp"
        )
        let decoded = WebsiteStyleBindingStore.decode(WebsiteStyleBindingStore.encode([binding]))
        XCTAssertEqual(decoded, [binding])
        XCTAssertTrue(binding.matches(URL(string: "https://docs.example.com/page")!))
        XCTAssertTrue(binding.matches(URL(string: "https://example.com")!))
        XCTAssertFalse(binding.matches(URL(string: "https://notexample.com")!))
    }

    func testCleanupLevelsAddBoundedInstructions() {
        XCTAssertEqual(CleanupLevel.none.prompt(custom: "Custom"), "Custom")
        XCTAssertTrue(CleanupLevel.light.prompt(custom: "Custom").contains("light cleanup"))
        XCTAssertTrue(CleanupLevel.high.prompt(custom: "Custom").contains("self-corrections"))
    }

    func testQualityModelMetadataIsPinned() {
        let descriptor = CleanupModelKind.qwen25_1_5b_q4_k_m.descriptor
        XCTAssertEqual(descriptor.recommendation, .quality)
        XCTAssertEqual(descriptor.expectedByteCount, 1_117_320_736)
        XCTAssertEqual(descriptor.expectedSHA256.count, 64)
        XCTAssertTrue(descriptor.url.absoluteString.contains("/91cad51170dc346986eccefdc2dd33a9da36ead9/"))
    }

    func testWebsiteRuleOverridesTheBrowserProfile() {
        let appProfile = ResolvedWritingStyle(
            style: .chat, rules: WritingStyle.chat.defaultRules,
            matchedAppName: "Browser", intent: .casual, cleanup: .inherit
        )
        let rule = WebsiteStyleBinding(
            hostPattern: "mail.example.com", displayName: "Work Mail",
            style: .email, intent: .professional, cleanup: .inherit,
            cleanupLevel: .light, cleanupPrompt: "Use short paragraphs"
        )

        let resolved = WritingStyleResolver.applyingWebsiteRule(
            appProfile, url: URL(string: "https://mail.example.com/inbox"), bindings: [rule]
        )

        XCTAssertEqual(resolved.style, .email)
        XCTAssertEqual(resolved.matchedAppName, "Work Mail")
        XCTAssertEqual(resolved.cleanupLevel, .light)
        XCTAssertEqual(resolved.cleanupPrompt, "Use short paragraphs")
    }

    func testMostSpecificWebsiteRuleWins() {
        let base = ResolvedWritingStyle(style: .chat, rules: WritingStyle.chat.defaultRules, matchedAppName: "Browser")
        let specificRule = WebsiteStyleBinding(hostPattern: "mail.example.com", displayName: "Mail", style: .email)
        let generalRule = WebsiteStyleBinding(hostPattern: "example.com", displayName: "Example", style: .notes)
        let url = URL(string: "https://mail.example.com/inbox")
        XCTAssertEqual(WritingStyleResolver.applyingWebsiteRule(base, url: url, bindings: [specificRule, generalRule]).matchedAppName, "Mail")
        XCTAssertEqual(WritingStyleResolver.applyingWebsiteRule(base, url: url, bindings: [generalRule, specificRule]).matchedAppName, "Mail")
        XCTAssertEqual(
            WritingStyleResolver.applyingWebsiteRule(base, url: URL(string: "https://example.com"), bindings: [specificRule, generalRule]).matchedAppName,
            "Example"
        )
    }

    func testPerAppCleanupOverridesSurvivePersistence() throws {
        let binding = AppStyleBinding(
            id: "com.example.editor", displayName: "Editor",
            bundleIdentifier: "com.example.editor", style: .notes,
            cleanupLevel: .high, cleanupPrompt: "Preserve issue numbers"
        )
        let json = WritingStyleBindingStore(bindings: [binding]).encodedJSON()
        let restored = try XCTUnwrap(WritingStyleBindingStore.decode(json: json).bindings.first)
        XCTAssertEqual(restored.cleanupLevel, .high)
        XCTAssertEqual(restored.cleanupPrompt, "Preserve issue numbers")
    }

    @MainActor
    func testSettingsPreviewUsesPerAppCleanupOverrides() {
        let (appState, _) = AppState.makeTestState()
        appState.settingsPreviewBindingID = "com.example.editor"
        appState.writingStyleBindings = [AppStyleBinding(
            id: "com.example.editor", displayName: "Editor",
            bundleIdentifier: "com.example.editor", style: .notes,
            cleanupLevel: .light, cleanupPrompt: "Preserve issue numbers"
        )]

        XCTAssertEqual(appState.settingsPreviewProfile.cleanupLevel, .light)
        XCTAssertEqual(appState.settingsPreviewProfile.cleanupPrompt, "Preserve issue numbers")
    }
}

@MainActor
final class RecognitionVocabularyTests: XCTestCase {
    func testUserVocabularySurvivesWhispersFrontTrimming() {
        let screen = (0..<200).map { "identifierNumber\($0)" }
        let prompt = AppState.recognitionVocabulary("VocaMac, Namrata", contextTerms: screen)

        // WhisperKit keeps the suffix of the prompt, so the user's terms must end it.
        XCTAssertTrue(prompt.hasSuffix("VocaMac, Namrata"))
        XCTAssertLessThanOrEqual(prompt.count, AppState.recognitionPromptCharacterBudget)
    }

    func testScreenTermsAreDeduplicatedAgainstVocabulary() {
        let prompt = AppState.recognitionVocabulary("GitHub", contextTerms: ["github", "userId", "userId"])
        XCTAssertEqual(prompt, "userId, GitHub")
        XCTAssertEqual(AppState.recognitionVocabulary("", contextTerms: []), "")
    }
}

final class SystemAudioAccumulatorTests: XCTestCase {
    func testResamplingAveragesInsteadOfDroppingSamples() {
        let alternating: [Float] = (0..<48).map { $0.isMultiple(of: 2) ? 1 : -1 }
        let resampled = SystemAudioAccumulator.resampleTo16k(alternating, from: 48_000)
        XCTAssertEqual(resampled.count, 16)
        // A tone at the source's Nyquist frequency is inaudible at 16 kHz and
        // must not alias into full-scale noise.
        XCTAssertLessThan(resampled.map(abs).max() ?? 1, 0.34)
        XCTAssertTrue(SystemAudioAccumulator.isSilent([0, 0.00001, -0.00002]))
        XCTAssertFalse(SystemAudioAccumulator.isSilent([0, 0.2]))
    }

    func testDurationLimitIsReportedOnceWhenExactlyReached() {
        let accumulator = SystemAudioAccumulator(maximumDurationSeconds: 1)
        accumulator.reset(sampleRate: 2)

        XCTAssertFalse(accumulator.appendMonoSamples([0.1]))
        XCTAssertTrue(accumulator.appendMonoSamples([0.2]))
        XCTAssertFalse(accumulator.appendMonoSamples([0.3]))
        XCTAssertTrue(accumulator.reachedLimit())
    }
}

final class SpokenCorrectionResolverTests: XCTestCase {
    func testExplicitNumericCorrectionKeepsTheReplacement() {
        XCTAssertEqual(
            SpokenCorrectionResolver.resolve("Meet me at 2, actually 3 tomorrow"),
            "Meet me at 3 tomorrow"
        )
        XCTAssertEqual(
            SpokenCorrectionResolver.resolve("Use 2:00 rather 3:30"),
            "Use 3:30"
        )
    }

    func testOrdinaryActuallyPhraseIsNotRewritten() {
        let text = "I was actually thrilled with the result"
        XCTAssertEqual(SpokenCorrectionResolver.resolve(text), text)
    }
}

final class DeepLinkRouterTests: XCTestCase {
    func testSupportedDeepLinks() {
        XCTAssertEqual(VocaDeepLink(url: URL(string: "vocamac://dictate/start")!), .startDictation)
        XCTAssertEqual(VocaDeepLink(url: URL(string: "vocamac://paste-last")!), .pasteLast)
        XCTAssertEqual(VocaDeepLink(url: URL(string: "vocamac://transcribe-file")!), .transcribeFile)
        XCTAssertEqual(VocaDeepLink(url: URL(string: "vocamac://scratchpad")!), .scratchpad)
    }

    func testUnknownOrForeignLinksAreRejected() {
        XCTAssertNil(VocaDeepLink(url: URL(string: "vocamac://unknown")!))
        XCTAssertNil(VocaDeepLink(url: URL(string: "https://vocamac.com")!))
    }

    func testOnlyPrivilegedExternalLinksRequireConfirmation() {
        XCTAssertTrue(VocaDeepLink.pasteLast.requiresExternalConfirmation)
        XCTAssertTrue(VocaDeepLink.startDictation.requiresExternalConfirmation)
        XCTAssertTrue(VocaDeepLink.stopDictation.requiresExternalConfirmation)
        XCTAssertTrue(VocaDeepLink.toggleDictation.requiresExternalConfirmation)
        XCTAssertFalse(VocaDeepLink.settings.requiresExternalConfirmation)
        XCTAssertFalse(VocaDeepLink.transcribeFile.requiresExternalConfirmation)
    }
}

final class SettingsArchiveTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsArchiveTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testArchiveUsesAllowlistAndRestoresKnownValues() throws {
        defaults.set(true, forKey: PreferenceKey.historyEnabled)
        defaults.set("https://private.example/v1", forKey: PreferenceKey.cleanupEndpoint)
        defaults.set("secret", forKey: "vocamac.scratchpad.text")
        defaults.set("not-exported", forKey: "unknown")

        let data = try SettingsArchiveService.encode(defaults: defaults)
        defaults.set(false, forKey: PreferenceKey.historyEnabled)
        try SettingsArchiveService.restore(data, defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: PreferenceKey.historyEnabled))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private.example"))
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains("not-exported"))
    }

    func testNumbersKeepTheirTypeThroughExport() throws {
        defaults.set(1, forKey: PreferenceKey.mouseTriggerButton)
        defaults.set(2.0, forKey: "vocamac.silenceDuration")
        defaults.set(true, forKey: PreferenceKey.historyEnabled)

        let archive = SettingsArchiveService.make(defaults: defaults)

        XCTAssertEqual(archive.values[PreferenceKey.mouseTriggerButton], .integer(1))
        XCTAssertEqual(archive.values["vocamac.silenceDuration"], .double(2.0))
        XCTAssertEqual(archive.values[PreferenceKey.historyEnabled], .bool(true))
    }

    func testClipboardConsentIsNeverImported() throws {
        let archive = SettingsArchive(values: [PreferenceKey.commandModeClipboardFallback: .bool(true)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try SettingsArchiveService.restore(try encoder.encode(archive), defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: PreferenceKey.commandModeClipboardFallback))

        defaults.set(true, forKey: PreferenceKey.commandModeClipboardFallback)
        XCTAssertNil(SettingsArchiveService.make(defaults: defaults).values[PreferenceKey.commandModeClipboardFallback])
    }

    func testRestoreCannotRedirectCleanupEndpoint() throws {
        defaults.set("https://trusted.example/v1", forKey: PreferenceKey.cleanupEndpoint)
        let archive = SettingsArchive(values: [
            PreferenceKey.cleanupEndpoint: .string("https://attacker.example/v1"),
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try SettingsArchiveService.restore(try encoder.encode(archive), defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: PreferenceKey.cleanupEndpoint), "https://trusted.example/v1")
    }

    func testRestoreRejectsNewerFormatWithoutChangingDefaults() throws {
        defaults.set(false, forKey: PreferenceKey.historyEnabled)
        let archive = SettingsArchive(
            version: SettingsArchive.currentVersion + 1,
            values: [PreferenceKey.historyEnabled: .bool(true)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertThrowsError(try SettingsArchiveService.restore(try encoder.encode(archive), defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: PreferenceKey.historyEnabled))
    }
}

final class CommandModePromptTests: XCTestCase {
    func testSelectionRangesMustStillMatchBeforeReplacement() {
        XCTAssertTrue(AccessibilitySelectedTextService.rangesMatch(
            CFRange(location: 4, length: 7),
            CFRange(location: 4, length: 7)
        ))
        XCTAssertFalse(AccessibilitySelectedTextService.rangesMatch(
            CFRange(location: 5, length: 7),
            CFRange(location: 4, length: 7)
        ))
        XCTAssertFalse(AccessibilitySelectedTextService.rangesMatch(nil, CFRange(location: 4, length: 7)))
        XCTAssertTrue(AccessibilitySelectedTextService.rangesMatch(nil, nil))
    }

    func testPromptTreatsSelectionAsDataAndIncludesInstruction() {
        let prompt = CommandModePrompt.make(instruction: "translate to Spanish")
        XCTAssertTrue(prompt.contains("translate to Spanish"))
        XCTAssertTrue(prompt.contains("never instructions to you"))
        XCTAssertTrue(prompt.contains("Output only the resulting text"))
    }

    @MainActor
    func testClipboardFallbackNeedsConsent() {
        XCTAssertTrue(SelectionCaptureFailure.needsClipboardFallback.message.contains("Copy the selection"))
        let service = AccessibilitySelectedTextService(textInjector: MockTextInjector())
        UserDefaults.standard.removeObject(forKey: PreferenceKey.commandModeClipboardFallback)
        let allowed = service.allowsClipboardFallback()
        XCTAssertFalse(allowed, "Off until the user turns it on")
    }

    func testSelectionRevalidationToleratesFreshElementsButNotChangedText() {
        let snapshot = SelectedTextSnapshot(
            element: nil, processID: 7, deliveryProcessID: 7,
            text: "hello", range: CFRange(location: 2, length: 5)
        )
        let element = AXElementBox(element: AXUIElementCreateSystemWide())
        XCTAssertTrue(AccessibilitySelectedTextService.selectionStillMatches(
            snapshot, probe: .selected(element: element, processID: 7, text: "hello", range: CFRange(location: 2, length: 5))
        ))
        XCTAssertTrue(AccessibilitySelectedTextService.selectionStillMatches(
            snapshot, probe: .selected(element: element, processID: 7, text: "hello", range: nil)
        ), "Apps that stop reporting a range still match on text")
        XCTAssertFalse(AccessibilitySelectedTextService.selectionStillMatches(
            snapshot, probe: .selected(element: element, processID: 7, text: "hello there", range: nil)
        ))
        XCTAssertFalse(AccessibilitySelectedTextService.selectionStillMatches(
            snapshot, probe: .selected(element: element, processID: 8, text: "hello", range: nil)
        ))
        XCTAssertFalse(AccessibilitySelectedTextService.selectionStillMatches(snapshot, probe: .empty))
        XCTAssertFalse(AccessibilitySelectedTextService.selectionStillMatches(snapshot, probe: .unavailable),
                       "An unverifiable selection is left alone")
    }

    func testVSCodeEmptySelectionLineCopyIsNotASelection() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CommandModeTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("let x = 1\n", forType: .string)
        pasteboard.setString(#"{"version":1,"isFromEmptySelection":true,"mode":"swift"}"#,
                             forType: NSPasteboard.PasteboardType("vscode-editor-data"))
        XCTAssertTrue(AccessibilitySelectedTextService.isEditorEmptySelectionCopy(pasteboard))

        pasteboard.clearContents()
        pasteboard.setString("let x = 1", forType: .string)
        pasteboard.setString(#"{"version":1,"isFromEmptySelection":false}"#,
                             forType: NSPasteboard.PasteboardType("vscode-editor-data"))
        XCTAssertFalse(AccessibilitySelectedTextService.isEditorEmptySelectionCopy(pasteboard))
    }

    func testTransformOutputDropsChatWrapping() {
        XCTAssertEqual(
            TranscriptCleanup.acceptedTransformOutput("Here's the shorter version:\nShip it Friday.", original: "We should ship it on Friday."),
            "Ship it Friday."
        )
        XCTAssertEqual(
            TranscriptCleanup.acceptedTransformOutput("```swift\nlet total = a + b\n```", original: "let  total=a+b"),
            "let total = a + b"
        )
        XCTAssertEqual(
            TranscriptCleanup.acceptedTransformOutput("“Hola, ¿cómo estás?”", original: "Hi, how are you?"),
            "Hola, ¿cómo estás?"
        )
        // Quotes the selection already had stay.
        XCTAssertEqual(
            TranscriptCleanup.acceptedTransformOutput("\"Stop.\"", original: "\"Please stop that.\""),
            "\"Stop.\""
        )
    }

    func testSessionPreviewIsOneShortLine() {
        let session = CommandModeSession(
            selection: "First line\n\n  second   line " + String(repeating: "x", count: 100),
            appName: "Discord", engineName: "Qwen 3 4B Instruct"
        )
        XCTAssertFalse(session.selectionPreview.contains("\n"))
        XCTAssertTrue(session.selectionPreview.hasPrefix("First line second line"))
        XCTAssertEqual(session.selectionPreview.count, 80)
        XCTAssertTrue(session.selectionPreview.hasSuffix("…"))
        XCTAssertEqual(session.phase, .listening)
    }

    func testReplacementKeepsTheSelectionsSurroundingWhitespace() {
        XCTAssertEqual(
            TranscriptCleanup.preservingOuterWhitespace(of: "  first line\n", in: "First line."),
            "  First line.\n"
        )
        XCTAssertEqual(TranscriptCleanup.preservingOuterWhitespace(of: "word", in: " Word "), "Word")
    }
}

@MainActor
final class CommandModeFlowTests: XCTestCase {
    func testCommandModeTransformsAndReplacesTheCapturedSelection() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "This sentence is unnecessarily long."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "A short sentence." }
        let (app, mocks) = AppState.makeTestState(
            transcriptCleanup: cleanup,
            selectedTextService: selection
        )
        app.transcriptCleanupEnabled = true
        app.selectedCleanupModelKind = .qwen25_1_5b_q4_k_m
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "make this shorter", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.beginCommandMode()
        XCTAssertTrue(app.isRecording)
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(selection.captureCallCount, 1)
        XCTAssertEqual(selection.replacement, "A short sentence.")
        XCTAssertEqual(cleanup.previewCallCount, 1)
        XCTAssertTrue(cleanup.lastPrompt?.contains("make this shorter") == true)
        XCTAssertNil(mocks.textInjector.lastInjectedText)
        XCTAssertEqual(app.appStatus, .idle)
    }

    func testQuickPressKeepsCommandModeRecordingUntilSecondPress() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "This sentence is unnecessarily long."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "A short sentence." }
        let (app, mocks) = AppState.makeTestState(
            transcriptCleanup: cleanup,
            selectedTextService: selection
        )
        app.transcriptCleanupEnabled = true
        app.selectedCleanupModelKind = .qwen25_1_5b_q4_k_m
        app.commandModeHoldThreshold = 60
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "make this shorter", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.handleShortcut(.commandMode)
        await app.handleShortcutReleased(.commandMode)

        XCTAssertTrue(app.isRecording, "A quick release should switch to toggle mode")
        XCTAssertNil(selection.replacement)

        await app.handleShortcut(.commandMode)

        XCTAssertEqual(selection.replacement, "A short sentence.")
        XCTAssertFalse(app.isRecording)
        XCTAssertEqual(app.appStatus, .idle)
    }

    func testHeldCommandModeStopsWhenShortcutIsReleased() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "This sentence is unnecessarily long."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "A short sentence." }
        let (app, mocks) = AppState.makeTestState(
            transcriptCleanup: cleanup,
            selectedTextService: selection
        )
        app.transcriptCleanupEnabled = true
        app.selectedCleanupModelKind = .qwen25_1_5b_q4_k_m
        app.commandModeHoldThreshold = 0
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "make this shorter", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.handleShortcut(.commandMode)
        await app.handleShortcutReleased(.commandMode)

        XCTAssertEqual(selection.replacement, "A short sentence.")
        XCTAssertFalse(app.isRecording)
        XCTAssertEqual(app.appStatus, .idle)
    }

    func testReleasingBeforeTheMicrophoneStartsCancelsWithAHint() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "Slow app selection."
        let (app, _) = AppState.makeTestState(selectedTextService: selection)
        app.commandModeHoldThreshold = 0
        // The key comes up while the selection is still being read.
        selection.onCapture = { [weak app] in await app?.handleShortcutReleased(.commandMode) }

        await app.handleShortcut(.commandMode)

        XCTAssertFalse(app.isRecording, "Nothing the user meant for Command Mode gets recorded")
        XCTAssertEqual(app.errorMessage, AppState.commandReleasedEarlyMessage)
        XCTAssertNil(app.commandModeSession)
        XCTAssertNil(selection.replacement)
    }

    func testCommandModeWorksWithSmartCleanupOff() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "This sentence is unnecessarily long."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "A short sentence." }
        let (app, mocks) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        XCTAssertFalse(app.transcriptCleanupEnabled)
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "make this shorter", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.beginCommandMode()
        XCTAssertTrue(mocks.cursorOverlay.isCommandMode)
        XCTAssertEqual(app.commandModeSession?.phase, .listening)
        XCTAssertEqual(app.commandModeSession?.characterCount, 36)
        await app.stopRecordingAndTranscribe()
        XCTAssertNil(app.commandModeSession, "The menu bar and overlay return to dictation")
        XCTAssertFalse(mocks.cursorOverlay.isCommandMode)

        XCTAssertEqual(selection.replacement, "A short sentence.")
        XCTAssertEqual(cleanup.lastLoadedKind, .qwen25_1_5b_q4_k_m)
        // The spoken command is not a dictation.
        XCTAssertNil(app.lastTranscription)
        XCTAssertEqual(mocks.soundManager.commandStartSoundCallCount, 1)
        XCTAssertEqual(mocks.soundManager.startSoundCallCount, 0, "Edits get their own cue")
        let entry = try? XCTUnwrap(app.historyStore.entries.first)
        XCTAssertEqual(entry?.commandOriginal, "This sentence is unnecessarily long.")
        XCTAssertEqual(entry?.finalText, "A short sentence.")
        XCTAssertEqual(entry?.rawText, "make this shorter")
        XCTAssertEqual(app.lastCommandEdit?.original, "This sentence is unnecessarily long.")
        XCTAssertEqual(app.lastCommandEdit?.instruction, "make this shorter")
        XCTAssertEqual(mocks.statsManager.recordCallCount, 0)
    }

    func testEditsFollowHistoryRetentionImmediately() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "Some text."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "Other text." }
        let (app, mocks) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        app.historyRetention = .day
        app.historyStore.recordCommandEdit(
            instruction: "old", original: "old", replacement: "old", summary: nil, target: nil,
            modelID: "tiny", language: "en", audioSeconds: 1, now: Date().addingTimeInterval(-3 * 24 * 60 * 60)
        )
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "rewrite", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.beginCommandMode()
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(app.historyStore.entries.map(\.finalText), ["Other text."], "The expired edit is gone")
    }

    func testDictionaryTreatsAutoAsUnknownLanguage() {
        let (app, _) = AppState.makeTestState()
        var seen: [String?] = []
        app.isKnownWord = { _, language in seen.append(language); return false }
        _ = app.dictionaryContext(contextTerms: [], language: "auto").isKnownWord("namratha")
        _ = app.dictionaryContext(contextTerms: [], language: "en").isKnownWord("namratha")
        XCTAssertEqual(seen, [nil, "en"])
    }

    func testEditsStayOutOfHistoryWhenHistoryIsOff() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "Some text."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "Other text." }
        let (app, mocks) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        app.historyEnabled = false
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "rewrite", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.beginCommandMode()
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(selection.replacement, "Other text.")
        XCTAssertTrue(app.historyStore.entries.isEmpty)
    }

    func testSuggestedShortcutAvoidsVocaMacsOwnShortcuts() {
        let (app, _) = AppState.makeTestState()
        let first = ShortcutValidation.commandModeSuggestions[0]
        XCTAssertEqual(ShortcutValidation.suggestion(for: .commandMode, appState: app), first)
        XCTAssertNil(ShortcutValidation.suggestion(for: .pasteLastDictation, appState: app))

        app.setShortcut(first, for: .handsFreeToggle)
        XCTAssertEqual(
            ShortcutValidation.suggestion(for: .commandMode, appState: app),
            ShortcutValidation.commandModeSuggestions[1]
        )
        for combo in ShortcutValidation.commandModeSuggestions {
            XCTAssertEqual(combo.modifiers, [.control, .option, .command])
        }
    }

    func testCommandModeExplainsWhenItsModelIsNotDownloaded() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "Selected"
        let cleanup = MockTranscriptCleanup()
        cleanup.downloadedKinds = [.qwen25_0_5b_q4_k_m]
        let (app, _) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        app.commandModeEngine = .local(.qwen3_4b_instruct_2507_q4_k_m)

        await app.beginCommandMode()

        XCTAssertEqual(selection.captureCallCount, 0)
        XCTAssertEqual(app.appStatus, .error)
        XCTAssertTrue(app.errorMessage?.contains("Qwen 3 4B Instruct") == true)
    }

    func testCaptureFailureExplainsWhatToDo() async {
        let selection = MockSelectedTextService()
        selection.failure = .secureField
        let (app, _) = AppState.makeTestState(selectedTextService: selection)

        await app.beginCommandMode()

        XCTAssertFalse(app.isRecording)
        XCTAssertEqual(app.errorMessage, SelectionCaptureFailure.secureField.message)
    }

    func testEscapeWhileTheModelRunsLeavesTheSelectionAlone() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "Keep me exactly as I am."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "Rewritten." }
        let (app, mocks) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        cleanup.onTransform = { [weak app] in await app?.cancelDictation() }
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "rewrite this", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.beginCommandMode()
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(cleanup.cancelTransformCallCount, 1)
        XCTAssertNil(app.commandModeSession)
        XCTAssertEqual(selection.replaceCallCount, 0)
        XCTAssertNil(selection.replacement)
        XCTAssertEqual(app.appStatus, .idle)
    }

    func testReplacementKeepsTrailingNewlineOfTheSelection() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "first line\n"
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "First line." }
        let (app, mocks) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "fix the capitalization", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )
        var sessionWhileRewriting: CommandModeSession?
        cleanup.onTransform = { [weak app] in
            await MainActor.run { sessionWhileRewriting = app?.commandModeSession }
        }

        await app.beginCommandMode()
        await app.stopRecordingAndTranscribe()

        XCTAssertEqual(selection.replacement, "First line.\n")
        XCTAssertEqual(sessionWhileRewriting?.phase, .rewriting)
        XCTAssertEqual(sessionWhileRewriting?.instruction, "fix the capitalization")
    }

    func testCleanupModelIsReloadedAfterALargerCommandModel() async {
        let selection = MockSelectedTextService()
        selection.selectedText = "Some text."
        let cleanup = MockTranscriptCleanup()
        cleanup.cleanHandler = { _ in "Other text." }
        let (app, mocks) = AppState.makeTestState(transcriptCleanup: cleanup, selectedTextService: selection)
        app.transcriptCleanupEnabled = true
        app.selectedCleanupModelKind = .qwen25_0_5b_q4_k_m
        app.commandModeEngine = .local(.qwen3_4b_instruct_2507_q4_k_m)
        mocks.audioEngine.stopRecordingResult = [0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "rewrite", duration: 0, detectedLanguage: "en",
            audioLengthSeconds: 1.0 / 16_000, modelUsed: .tiny
        )

        await app.beginCommandMode()
        await app.stopRecordingAndTranscribe()
        XCTAssertEqual(selection.replacement, "Other text.")

        for _ in 0..<50 where cleanup.lastLoadedKind != .qwen25_0_5b_q4_k_m {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(cleanup.lastLoadedKind, .qwen25_0_5b_q4_k_m)
    }
}

@MainActor
final class RemoteCleanupServiceTests: XCTestCase {
    func testOpenAICompatibleRequestUsesConfiguredModelPromptAndKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubCleanupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        StubCleanupURLProtocol.install { request in
            XCTAssertEqual(request.url?.absoluteString, "https://cleanup.example/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try XCTUnwrap(StubCleanupURLProtocol.bodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "cleanup-model")
            let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertEqual(messages.first?["content"], "Clean this")
            let response = try XCTUnwrap(HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ))
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "Hello."]]]
            ])
            return (response, data)
        }
        let service = RemoteCleanupService(
            configuration: CleanupEndpointConfiguration(
                provider: .openAICompatible,
                baseURL: "https://cleanup.example/v1",
                model: "cleanup-model"
            ),
            credentials: StubCleanupCredentials(apiKey: "test-key"),
            session: session
        )

        let attempt = await service.attempt("um hello", prompt: "Clean this")

        XCTAssertEqual(attempt.output, "Hello.")
        XCTAssertEqual(attempt.outcome, .cleaned)
    }

    func testUnreachableEndpointIsSkippedForAWhileButCommandsStillTry() async {
        RemoteCleanupService.resetReachabilityForTesting()
        defer { RemoteCleanupService.resetReachabilityForTesting() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubCleanupURLProtocol.self]
        let session = URLSession(configuration: configuration)
        final class RequestCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let requests = RequestCounter()
        StubCleanupURLProtocol.install { _ in
            requests.increment()
            throw URLError(.cannotConnectToHost)
        }
        let service = RemoteCleanupService(
            configuration: CleanupEndpointConfiguration(
                provider: .ollama, baseURL: "http://127.0.0.1:9/v1", model: "m"
            ),
            credentials: StubCleanupCredentials(apiKey: nil),
            session: session
        )

        let first = await service.attempt("hello there", prompt: "Clean")
        let second = await service.attempt("hello again", prompt: "Clean")
        _ = await service.transform("hello", prompt: "Edit")

        guard case .rejected = first.outcome else { return XCTFail("Expected the first attempt to reach the stub") }
        guard case .skipped = second.outcome else { return XCTFail("Expected the next cleanup to skip the dead endpoint") }
        XCTAssertEqual(second.output, "hello again")
        XCTAssertEqual(requests.count, 2, "Command Mode still tries")
    }

    func testInvalidEndpointFailsClosedWithoutNetwork() async {
        let service = RemoteCleanupService(configuration: CleanupEndpointConfiguration(
            provider: .openAICompatible, baseURL: "file:///tmp/model", model: "model"
        ))
        let attempt = await service.attempt("keep me", prompt: "Clean")
        XCTAssertEqual(attempt.output, "keep me")
        guard case .skipped = attempt.outcome else { return XCTFail("Expected invalid endpoint to skip") }
    }
}

final class IncrementalAudioTranscriberTests: XCTestCase {
    private final class PartialStore: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) { lock.withLock { values.append(value) } }
        func contains(_ value: String) -> Bool { lock.withLock { values.contains(value) } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func testPartialIsDisplayOnlyAndFinalUsesAllSamples() async throws {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let partials = PartialStore()
        let task = Task {
            try await IncrementalAudioTranscriber.run(
                chunks: stream,
                updateEverySamples: 2,
                transcribe: { samples in
                    VocaTranscription(
                        text: "count \(samples.count)", duration: 0,
                        detectedLanguage: "en",
                        audioLengthSeconds: Double(samples.count) / 16_000,
                        modelUsed: .tiny
                    )
                },
                onPartial: { value in partials.append(value) }
            )
        }
        continuation.yield([0.1, 0.2])
        try await Task.sleep(for: .milliseconds(300))
        continuation.yield([0.3])
        continuation.finish()

        let final = try await task.value
        XCTAssertEqual(final.text, "count 3")
        XCTAssertEqual(final.audioLengthSeconds, 3.0 / 16_000.0)
        XCTAssertTrue(partials.contains("count 2"))
    }

    func testFailedPartialDoesNotDiscardTheFinalRecording() async throws {
        enum PreviewError: Error { case tooShort }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let task = Task {
            try await IncrementalAudioTranscriber.run(
                chunks: stream,
                updateEverySamples: 2,
                transcribe: { samples in
                    if samples.count == 2 { throw PreviewError.tooShort }
                    return VocaTranscription(
                        text: "complete", duration: 0, detectedLanguage: "en",
                        audioLengthSeconds: Double(samples.count) / 16_000,
                        modelUsed: .tiny
                    )
                },
                onPartial: { _ in }
            )
        }
        continuation.yield([0.1, 0.2])
        try await Task.sleep(for: .milliseconds(300))
        continuation.yield([0.3])
        continuation.finish()

        let result = try await task.value
        XCTAssertEqual(result.text, "complete")
    }

    func testNoLiveConsumerDoesOnlyTheFinalDecode() async throws {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let calls = Counter()
        let task = Task {
            try await IncrementalAudioTranscriber.run(
                chunks: stream,
                updateEverySamples: 2,
                transcribe: { samples in
                    calls.increment()
                    return VocaTranscription(
                        text: "final", duration: 0, detectedLanguage: "en",
                        audioLengthSeconds: Double(samples.count) / 16_000,
                        modelUsed: .tiny
                    )
                },
                onPartial: nil
            )
        }
        continuation.yield([0.1, 0.2])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(calls.count, 0)
        continuation.finish()

        _ = try await task.value
        XCTAssertEqual(calls.count, 1)
    }
}
