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

    func testBundledPairsMatchLinuxBytes() {
        // sha256 of VocaLinux #707 resources/sounds/{id}_{start,stop}.wav
        // (commit 8953b645611906447c7e3d3bfc567ff59ff343c3)
        let expectedSHA256: [String: String] = [
            "lift_start": "0e83eacd5ee68d8ec6dfabbe1fc9290b7c5eb1aa428f80683449fb6c42334139",
            "lift_stop": "684f3994d31d6eacbcfaaa323f1c87ef31d843a2ff7add0a1b4adf27eba6901f",
            "flick_start": "dbfefcddbd14d4bf370c65599d9d122a8fe12834ae32427f53b101f2f88cb514",
            "flick_stop": "f740618ab2c029c97ff8b0d594e83de46a55cad382fae92d9de42a165ef1db2c",
            "ember_start": "99a493350e5bfb35ef418f4e9542858a823fbbef7052eba9e6f7c64b89707eea",
            "ember_stop": "7fdce80bc34627a2a9bab7cb9cf8f4882fb3c851d9a31affecb0be1eddc6a9be",
            "step_start": "455d9e9ee00d07c941e00df8bb3c43ae58a6ccd83f91ce44b97022cc18a09810",
            "step_stop": "e8bcebcea647433cacf67f5fd7c7d14b5e65fee938921937a7d0e3691148ca62",
            "voca_start": "954793730cd4be98f897e57b885877563050eca6844dca51b33b26e566e6f41d",
            "voca_stop": "39556c308a7dd5b3cdf6d2e762156f8515d11e09a95fb8e958cb205c1940f2c3",
            "soft_start": "5d167abb02e2de13488e98d3e266f6aca5a922ca33e6777e5946958f214912c1",
            "soft_stop": "f0bf2c55d846c75b5b49bcc45d127a1c9b3fa0c7d3c3f8937ce72e572046b505",
            "chirp_start": "8d71ce1704b6ffbdb37b4447e25799e2a89acde6327cc91bbdbd1e67c912a90d",
            "chirp_stop": "abcb3d26c892ebb14a0939f7fe95b59f6ce4961a7c8d0666d3312d42987feef6",
            "scale_start": "4b9ca317f0d968b54c8d9df8feffffc0bca8c0eb8f8cfeb9564aef59b5ed027d",
            "scale_stop": "dc34dae93f26f2eb87a0268691d66ac3e55ec7f1dfece836aa9f1cf09a73e76f",
            "drop_start": "8c15107f13f7e2604d23f193516c3e6792f1b5e089366cf8aa178fc0e607df70",
            "drop_stop": "04f0a77733c7a117ee16d19a19b0fb0257898a93210ca03eefe9aeb498704b1b",
            "glass_start": "ec381375968f2318fe5ed7f595da3fc559e871f19c3e3f4dba8318c7c42a4b1e",
            "glass_stop": "9c1fd0a2a8cbf7a6b3cdec816ad76ca05d44ac76af5e184dee6f6a0249857f22",
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
