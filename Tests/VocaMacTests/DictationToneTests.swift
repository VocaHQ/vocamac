// DictationToneTests.swift
// VocaMac Tests

import CryptoKit
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
        XCTAssertNil(DictationTone.off.resourceName(for: .start))
        XCTAssertNil(DictationTone.off.audioData(for: .start))
        XCTAssertNil(DictationTone.off.audioData(for: .stop))
    }

    func testBundledPairsMatchPreviewBytes() {
        // sha256 of the preview pair WAVs (05-fifth/start.wav is 19448 bytes).
        let expectedSHA256: [String: String] = [
            "lift_start": "a9f62c4bf03bd1f8b1e2c9ca476616c4891f817f899341e85889e9567ef63991",
            "lift_stop": "161b672769a7f21a89b946b5936469bf137b4fc596dc0f8b3c53971dfe0f450f",
            "flick_start": "ad361a5cc8e127b49313cb56e97d121a78e7406af12ed2a0c4881028b8ccab27",
            "flick_stop": "66993cd3a6bf6a830ab0b947762a4a737407b0429a887269d0e73e98ed54a01f",
            "ember_start": "f9f0b1b9c2a7ff97089122b009c7b66a1da5f999693c65c05bdb3bf375c748fe",
            "ember_stop": "bcd0370f7442bfa004f6211e4a35efcaf703ee384a3d7a00e97dd77f38ed2703",
            "step_start": "612f1fb1e155fcfff665153f74b1d998cd5e33ab0d55c965470f8b9823b87304",
            "step_stop": "d273326d075141e9fdd2f55597b588d8d8f196060b4db50ea58b014f57394909",
            "voca_start": "f1c46d405583f45fc8d088c54a02fa3be2f2c1e2f0d7cefc5759908fa065d068",
            "voca_stop": "2f11cd2ad5e7f5918fe4a902f84f8eed8b10784f7f1aa9feba7bc131154e86e8",
            "soft_start": "8a7fe9254cf6517036d9f6df6e1205c40d11f574cfa1b8a27ba4c3282938ad26",
            "soft_stop": "4175569f9f6e08ae612352a0773e5300e0587e85f82799af0b4839b40b07bda7",
            "chirp_start": "aff4f070a60b33dbc42e127ef485ffb0bb0c244e1b3a91c4a9f1e34231bf3d84",
            "chirp_stop": "1d953e3d93538d564bcd460723b009a0c312b518c68b1402f2786132a76f73d2",
            "scale_start": "4d55d4f8eb1d935c8a889f477474f65595b0d2f22d1ef99d1409b4b71d383e46",
            "scale_stop": "ce784c1dc606fa854da30574df079e7ddf775d13b67c2d789979c00b117fba00",
            "drop_start": "62573c6c851ee3efcc1ffbda5df8ec5bd2dd0ff03706ef24b285b15b61312dc8",
            "drop_stop": "f10fcf71799a02aa34f126d23ab42a8ce9bf6a89baf49e80aca274e53802ee0f",
            "glass_start": "f0312758398b62a3de5c67d9feb7c329af6e535d1723f04d1b38a67efa34a022",
            "glass_stop": "4293a1abc492b2f72d4151ed201693ce0f18bbeb506afc8125e9f61b3c2fe0b0",
        ]

        for tone in DictationTone.allCases where tone != .off {
            for kind in [DictationCueKind.start, DictationCueKind.stop] {
                let name = "\(tone.rawValue)_\(kind.rawValue)"
                XCTAssertEqual(tone.resourceName(for: kind), name)
                guard let data = tone.audioData(for: kind) else {
                    XCTFail("\(name) should load from the resource bundle")
                    continue
                }
                XCTAssertTrue(data.starts(with: Data("RIFF".utf8)), name)
                if name == "voca_start" {
                    XCTAssertEqual(data.count, 19448, name)
                }
                let rate = UInt32(data[24])
                    | UInt32(data[25]) << 8
                    | UInt32(data[26]) << 16
                    | UInt32(data[27]) << 24
                XCTAssertEqual(rate, 44100, name)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, expectedSHA256[name], name)
            }
        }
    }
}

@MainActor
final class DictationTonePreferenceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PreferenceKey.dictationTone)
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: PreferenceKey.dictationTone)
        UserDefaults.standard.removeObject(forKey: "vocamac.soundEffectsEnabled")
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
