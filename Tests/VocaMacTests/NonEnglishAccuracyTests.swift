// NonEnglishAccuracyTests.swift
// VocaMac Tests
//
// Figures an engine wrote in newspaper style, the model an unchosen
// default moves to, and language changes that only the spoken languages make.

import XCTest
@testable import VocaMac

final class FiguresAsWordsTests: XCTestCase {
    private func words(_ text: String) -> String { SpokenNumbers.words(forFiguresIn: text) }

    func testLoneSmallFiguresBecomeWords() {
        XCTAssertEqual(words("I have 2 ideas"), "I have two ideas")
        XCTAssertEqual(words("2 ideas came up."), "Two ideas came up.")
        XCTAssertEqual(words("Done. 3 left, then 4 more"), "Done. Three left, then four more")
        XCTAssertEqual(words("about 5 people"), "about five people")
    }

    func testFiguresThatAreUnitsNumbersOrPairsStay() {
        XCTAssertEqual(words("meet at 5 pm"), "meet at 5 pm")
        XCTAssertEqual(words("wait 3 minutes"), "wait 3 minutes")
        XCTAssertEqual(words("ship version 2 today"), "ship version 2 today")
        XCTAssertEqual(words("between 5 and 12 chairs"), "between 5 and 12 chairs")
        XCTAssertEqual(words("12 or 5 chairs"), "12 or 5 chairs")
    }

    func testFiguresInsideSomethingElseStay() {
        for text in ["costs $5", "about 2.5 hours", "at 3:30", "half is 1/2", "use v2", "50%", "COVID-19",
                     "1,000 rows", "the 1st one", "07 cases", "12 items", "in 2026", "#3 issue", "1-2 days"] {
            XCTAssertEqual(words(text), text, text)
        }
    }

    func testListNumbersNamesAndDatesStay() {
        XCTAssertEqual(words("1. Buy milk"), "1. Buy milk")
        XCTAssertEqual(words("2) Call Sam"), "2) Call Sam")
        XCTAssertEqual(words("we still run Python 3 here"), "we still run Python 3 here")
        XCTAssertEqual(words("Upgrade to Windows 8 first"), "Upgrade to Windows 8 first")
        // At the start of a sentence a capital proves nothing either way.
        XCTAssertEqual(words("Python 3 is installed."), "Python 3 is installed.")
        XCTAssertEqual(words("Done. Python 3 is installed."), "Done. Python 3 is installed.")
        XCTAssertEqual(words("May 5 is a Monday."), "May 5 is a Monday.")
        XCTAssertEqual(words("we meet on may 5"), "we meet on may 5")
        XCTAssertEqual(words("see you friday 3 times"), "see you friday 3 times")
    }

    @MainActor
    func testNewspaperStyleFoldsEngineFiguresInEnglishProseOnly() async {
        func run(_ text: String, format: WritingStyle = .plain, numbers: NumberWriting, language: String = "en") async -> String {
            await DictationOutputPipeline(cleaner: MockTranscriptCleanup(), snippets: SnippetExpander()).process(
                text, profile: WritingProfile(format: format, rules: format.defaultRules),
                snippetList: [], cleanupEnabled: false, rewritingEnabled: false,
                model: .defaultKind, customPrompt: "", language: language,
                autoCapitalize: true, trailingSpace: false, numbers: numbers
            ).text
        }
        let prose = await run("I have 2 ideas for 23 people", numbers: .automatic)
        XCTAssertEqual(prose, "I have two ideas for 23 people")
        // The engine's figure and the spoken word now come out the same.
        let spoken = await run("I have two ideas for twenty three people", numbers: .automatic)
        XCTAssertEqual(spoken, prose)
        // Chat keeps figures; "As spoken" keeps what the engine wrote.
        let chat = await run("I have 2 ideas", format: .chat, numbers: .automatic)
        XCTAssertEqual(chat, "I have 2 ideas")
        let asSpoken = await run("I have 2 ideas", numbers: .words)
        XCTAssertEqual(asSpoken, "I have 2 ideas")
        // Other languages keep their figures.
        let german = await run("Ich habe 2 Ideen", numbers: .automatic, language: "de")
        XCTAssertEqual(german, "Ich habe 2 Ideen")
    }
}

@MainActor
final class OtherLanguageCleanupTests: XCTestCase {
    private func process(_ text: String, language: String, cleaner: MockTranscriptCleanup) async -> DictationOutputResult {
        await DictationOutputPipeline(cleaner: cleaner, snippets: SnippetExpander()).process(
            text, profile: WritingProfile(format: .plain, rules: .passthrough),
            snippetList: [], cleanupEnabled: true, rewritingEnabled: false,
            model: .defaultKind, customPrompt: "", cleanupLevel: .medium, language: language,
            autoCapitalize: true, trailingSpace: false, skipWhenClean: true
        )
    }

    func testCleanTextInAnotherLanguageSkipsTheModel() async {
        let cleaner = MockTranscriptCleanup()
        let result = await process("Kannst du mir bitte den Bericht bis Freitag schicken?", language: "de", cleaner: cleaner)
        XCTAssertEqual(result.text, "Kannst du mir bitte den Bericht bis Freitag schicken?")
        XCTAssertEqual(cleaner.cleanCallCount, 0)
        XCTAssertNil(cleaner.lastPrompt)
    }

    func testUnpunctuatedTextInAnotherLanguageStillAsksTheModel() async {
        let cleaner = MockTranscriptCleanup()
        _ = await process("kannst du mir den bericht schicken", language: "de", cleaner: cleaner)
        XCTAssertNotNil(cleaner.lastPrompt)
    }
}

@MainActor
final class UnchosenDefaultModelTests: XCTestCase {
    // `AppState` keeps its settings in the standard defaults.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PreferenceKey.speechModelChosen)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.speechModelChosen)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.selectedModelSize)
        super.tearDown()
    }

    /// An English speaker after a normal startup: the load saved Tiny.
    private func englishState(downloaded: Set<ModelSize>) -> (AppState, MockModelManager) {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = downloaded
        let (appState, _) = AppState.makeTestState(modelManager: modelManager)
        appState.setSpokenLanguages(["en"])
        appState.selectedModelSize = ModelSize.tiny.rawValue
        appState.speechModelChosen = false
        return (appState, modelManager)
    }

    private func adoptableRecommendation(_ appState: AppState) throws -> ModelSize {
        let recommended = try XCTUnwrap(appState.speechModelRecommendation?.model)
        guard recommended != .tiny, recommended.engine != .appleSpeech, recommended.engine != .customEndpoint else {
            throw XCTSkip("This Mac's recommendation is never adopted automatically")
        }
        return recommended
    }

    func testTinySavedByStartupMovesToTheDownloadedRecommendation() throws {
        let (appState, modelManager) = englishState(downloaded: [.tiny])
        let recommended = try adoptableRecommendation(appState)
        modelManager.downloadedModels.insert(recommended)

        appState.adoptRecommendedModelIfNeverChosen()

        XCTAssertEqual(appState.selectedModelSize, recommended.rawValue)
        XCTAssertTrue(modelManager.downloadRequests.isEmpty)
    }

    func testNothingIsDownloadedForAnUnchosenDefault() {
        let (appState, modelManager) = englishState(downloaded: [.tiny])

        appState.adoptRecommendedModelIfNeverChosen()

        XCTAssertEqual(appState.selectedModelSize, ModelSize.tiny.rawValue)
        XCTAssertTrue(modelManager.downloadRequests.isEmpty)
    }

    func testAChosenTinyIsNeverReplaced() throws {
        let (appState, _) = englishState(downloaded: Set(ModelSize.allCases))
        _ = try adoptableRecommendation(appState)
        appState.speechModelChosen = true

        appState.adoptRecommendedModelIfNeverChosen()

        XCTAssertEqual(appState.selectedModelSize, ModelSize.tiny.rawValue)
    }

    func testAnOtherModelSavedBeforeTheFlagIsNeverReplaced() throws {
        let (appState, _) = englishState(downloaded: Set(ModelSize.allCases))
        _ = try adoptableRecommendation(appState)
        appState.selectedModelSize = ModelSize.base.rawValue

        appState.adoptRecommendedModelIfNeverChosen()

        XCTAssertEqual(appState.selectedModelSize, ModelSize.base.rawValue)
    }

    func testPickingAModelInSettingsRecordsTheChoice() {
        let (appState, _) = englishState(downloaded: [.tiny])
        CalmModelPicker().startSpeech(.tiny, cancelling: nil, appState: appState)
        XCTAssertTrue(appState.speechModelChosen)
    }
}

@MainActor
final class SpokenLanguageReloadTests: XCTestCase {
    func testASecondSpokenLanguageReloadsAModelThatBindsItsLanguage() async {
        let modelManager = MockModelManager()
        modelManager.downloadedModels = [.nemotronUnified]
        let (appState, mocks) = AppState.makeTestState(modelManager: modelManager)
        appState.setSpokenLanguages(["de"])
        appState.selectedLanguage = TranscriptionLanguage.auto.code
        await appState.loadModel(.nemotronUnified)
        await appState.languageDidChange()
        let loads = mocks.transcriber.loadRequests.count

        // Recognition stays on Auto, but Nemotron loaded with German.
        appState.setSpokenLanguages(["de", "fr"])
        XCTAssertEqual(appState.selectedLanguage, TranscriptionLanguage.auto.code)
        await appState.languageDidChange()

        XCTAssertEqual(mocks.transcriber.loadRequests.count, loads + 1)

        // The same languages again change nothing.
        await appState.languageDidChange()
        XCTAssertEqual(mocks.transcriber.loadRequests.count, loads + 1)
    }

    func testTheKeyFollowsWhatAModelLoadsWith() {
        let (appState, _) = AppState.makeTestState()
        appState.setSpokenLanguages(["de"])
        appState.selectedLanguage = TranscriptionLanguage.auto.code
        XCTAssertEqual(appState.languageChangeKey, "auto|de")
        appState.setSpokenLanguages(["de", "fr"])
        XCTAssertEqual(appState.languageChangeKey, "auto|auto")
        appState.selectedLanguage = "fr"
        XCTAssertEqual(appState.languageChangeKey, "fr|fr")
    }
}
