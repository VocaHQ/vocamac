// DictationToneTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class DictationToneTests: XCTestCase {

    func testCatalogIdsAndDisplayNames() {
        let expected: [(DictationTone, String, String)] = [
            (.lift, "lift", "Lift"),
            (.flick, "flick", "Flick"),
            (.ember, "ember", "Ember"),
            (.step, "step", "Step"),
            (.voca, "voca", "Voca"),
            (.soft, "soft", "Soft"),
            (.chirp, "chirp", "Chirp"),
            (.scale, "scale", "Scale"),
            (.drop, "drop", "Drop"),
            (.glass, "glass", "Glass"),
            (.off, "off", "Off"),
        ]

        XCTAssertEqual(DictationTone.allCases.map(\.rawValue), expected.map(\.1))
        for (tone, id, name) in expected {
            XCTAssertEqual(tone.rawValue, id)
            XCTAssertEqual(tone.displayName, name)
        }

        XCTAssertFalse(DictationTone.allCases.contains { $0.rawValue == "fifth" })
        XCTAssertFalse(DictationTone.allCases.contains { $0.rawValue.contains("01-") })
    }

    func testUnresolvedPreferenceIsVoca() {
        XCTAssertEqual(DictationTone.defaultTone, .voca)
        XCTAssertEqual(DictationTone.resolved(stored: nil), .voca)
        XCTAssertEqual(DictationTone.resolved(stored: ""), .voca)
        XCTAssertEqual(DictationTone.resolved(stored: "fifth"), .voca)
        XCTAssertEqual(DictationTone.resolved(stored: "01-linux-glide"), .voca)
    }

    func testSavedToneIdsArePreserved() {
        XCTAssertEqual(DictationTone.resolved(stored: "off"), .off)
        XCTAssertEqual(DictationTone.resolved(stored: "lift"), .lift)
        XCTAssertEqual(DictationTone.resolved(stored: "glass"), .glass)
        XCTAssertEqual(DictationTone.resolved(stored: "voca"), .voca)
    }

    func testOffHasNoAudio() {
        XCTAssertFalse(DictationTone.off.playsCues)
        XCTAssertNil(DictationTone.off.audioData(for: .start))
        XCTAssertNil(DictationTone.off.audioData(for: .stop))
    }

    func testAudibleTonesRenderRIFFPairs() {
        for tone in DictationTone.allCases where tone != .off {
            guard let start = tone.audioData(for: .start),
                  let stop = tone.audioData(for: .stop) else {
                XCTFail("\(tone.rawValue) should render start and stop audio")
                continue
            }
            XCTAssertTrue(start.starts(with: Data("RIFF".utf8)), "\(tone.rawValue) start")
            XCTAssertTrue(stop.starts(with: Data("RIFF".utf8)), "\(tone.rawValue) stop")
            XCTAssertGreaterThan(start.count, 44)
            XCTAssertGreaterThan(stop.count, 44)
        }
    }
}

@MainActor
final class DictationTonePreferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PreferenceKey.dictationTone)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.dictationTone)
        super.tearDown()
    }

    func testAppStateDefaultsToVocaWhenUnset() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(appState.dictationTone, .voca)
    }

    func testAppStateKeepsSavedOffChoice() {
        UserDefaults.standard.set("off", forKey: PreferenceKey.dictationTone)
        let (appState, _) = AppState.makeTestState()
        XCTAssertEqual(appState.dictationTone, .off)
    }

    func testPreviewPlaysStartThenStop() async {
        let (appState, mocks) = AppState.makeTestState()
        await appState.previewDictationTone()
        XCTAssertEqual(mocks.soundManager.playLog, [.startAsync, .stopAsync])
        XCTAssertEqual(mocks.soundManager.startSoundAsyncCallCount, 1)
        XCTAssertEqual(mocks.soundManager.stopSoundAsyncCallCount, 1)
    }
}
