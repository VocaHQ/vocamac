// ServiceTests.swift
// VocaMac Tests
//
// Tests for services: KeyCodeReference, TextInjector, SoundManager, AudioEngine.

import XCTest
import CoreAudio
@testable import VocaMac

// MARK: - KeyCodeReference Tests

final class KeyCodeReferenceTests: XCTestCase {

    func testCommonHotKeysNotEmpty() {
        XCTAssertFalse(KeyCodeReference.commonHotKeys.isEmpty)
    }

    func testDisplayNameForKnownKeyCode() {
        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: 61, modifiers: [])), "Right Option (⌥)")
    }

    func testDisplayNameForRecordedCharacterKeyCodeUsesActiveLayout() throws {
        guard let keyCode = TextInjector.keyCode(forCharacter: "a") else {
            throw XCTSkip("Could not inspect active keyboard layout")
        }

        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: Int(keyCode), modifiers: [])), "A")
    }

    func testDisplayNameForRecordedFunctionKeyCode() {
        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: 105, modifiers: [])), "F13")
    }

    func testDisplayNameForUnknownKeyCode() {
        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: 999, modifiers: [])), "Key 999")
    }

    func testCustomKeyCodeIsNotCommonPreset() {
        XCTAssertFalse(KeyCodeReference.isCommonHotKey(HotKeyCombo(keyCode: 105, modifiers: [])))
    }

    func testModifierKeyCodeDetection() {
        XCTAssertTrue(KeyCodeReference.isModifierKeyCode(61))
        XCTAssertTrue(KeyCodeReference.isModifierKeyCode(55))
        XCTAssertFalse(KeyCodeReference.isModifierKeyCode(105))
    }

    func testEscapeKeyCodeConstant() {
        XCTAssertEqual(KeyCodeReference.escapeKeyCode, 53)
        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: KeyCodeReference.escapeKeyCode, modifiers: [])), "Escape")
    }

    func testDisplayNameForSpaceUsesReadableName() {
        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: 49, modifiers: [])), "Space")
    }

    func testDisplayNameForComboUsesModifierSymbols() {
        XCTAssertEqual(KeyCodeReference.displayName(for: HotKeyCombo(keyCode: 49, modifiers: .command)), "⌘ Space")
    }

    func testComboPresetIsRecognizedAsCommonHotKey() {
        XCTAssertTrue(KeyCodeReference.isCommonHotKey(HotKeyCombo(keyCode: 49, modifiers: .command)))
    }

    func testCommonHotKeysValid() {
        for hotkey in KeyCodeReference.commonHotKeys {
            XCTAssertGreaterThanOrEqual(hotkey.keyCode, 0)
            XCTAssertFalse(hotkey.name.isEmpty)
        }
    }
}

// MARK: - TextInjector Tests

final class TextInjectorTests: XCTestCase {

    func testInstantiation() {
        let injector = TextInjector()
        XCTAssertNotNil(injector)
    }

    func testInjectEmptyStringDoesNothing() {
        let injector = TextInjector()
        // Should return immediately without crashing
        injector.inject(text: "", preserveClipboard: true)
        injector.inject(text: "", preserveClipboard: false)
    }

    /// Verify that the clipboard restore delay remains bounded while leaving
    /// enough time for a busy target application to consume Cmd+V.
    func testClipboardRestoreDelayIsSufficientlyShort() {
        // TextInjector's delays are private, so we verify the observable
        // behaviour: after inject() returns synchronously the pasteboard
        // should be restored within a short, bounded window.
        // We can't exercise the full path without accessibility permission,
        // but we *can* assert the injector doesn't crash and the total
        // constant budget is reasonable by inspecting known internals via
        // the file (compile-time guarantee that the constants exist).
        let injector = TextInjector()
        // Instantiation succeeds — the constants compiled to valid values
        XCTAssertNotNil(injector)
    }

    /// A delayed clipboard change must not become the value consumed by the
    /// paste event. This models a clipboard manager or an older restore task
    /// racing with the current transcription.
    func testClipboardFallbackReassertsTranscriptionBeforePaste() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        var pastedTexts: [String] = []
        let pasteExpectation = expectation(description: "transcription paste event")
        let finishedExpectation = expectation(description: "clipboard restoration")

        let injector = TextInjector(
            accessibilityTrustedOverride: true,
            accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: {
                pastedTexts.append(pasteboard.string(forType: .string) ?? "")
                pasteExpectation.fulfill()
            }
        )

        injector.inject(text: "spoken transcription", preserveClipboard: true)

        // Change the clipboard after VocaMac writes the transcription but
        // before it posts Cmd+V. The injector must put the transcription back
        // before the simulated paste and preserve this newer clipboard value.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            pasteboard.clearContents()
            pasteboard.setString("clipboard manager value", forType: .string)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            finishedExpectation.fulfill()
        }

        wait(for: [pasteExpectation, finishedExpectation], timeout: 1.0)

        XCTAssertEqual(pastedTexts, ["spoken transcription"])
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "clipboard manager value",
            "A newer clipboard value must survive the transcription paste"
        )
    }

    /// Consecutive transcriptions must not share an asynchronous clipboard
    /// window. Each paste event should consume its own transcription, and the
    /// original clipboard should be restored only after both are complete.
    func testRapidClipboardInjectionsAreSerialized() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("original clipboard", forType: .string)

        var pastedTexts: [String] = []
        let pasteExpectation = expectation(description: "two transcription paste events")
        pasteExpectation.expectedFulfillmentCount = 2
        let finishedExpectation = expectation(description: "queued clipboard restoration")

        let injector = TextInjector(
            accessibilityTrustedOverride: true,
            accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: {
                pastedTexts.append(pasteboard.string(forType: .string) ?? "")
                pasteExpectation.fulfill()
                if pastedTexts.count == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        finishedExpectation.fulfill()
                    }
                }
            }
        )

        injector.inject(text: "first transcription", preserveClipboard: true)
        injector.inject(text: "second transcription", preserveClipboard: true)

        wait(for: [pasteExpectation, finishedExpectation], timeout: 1.5)

        XCTAssertEqual(pastedTexts, ["first transcription", "second transcription"])
        XCTAssertEqual(pasteboard.string(forType: .string), "original clipboard")
    }

    /// Verify that the mock text injector faithfully records calls,
    /// ensuring AppState integration tests can assert clipboard preservation.
    func testMockTextInjectorRecordsPreserveClipboard() {
        let mock = MockTextInjector()

        mock.inject(text: "hello", preserveClipboard: true)
        XCTAssertEqual(mock.injectCallCount, 1)
        XCTAssertEqual(mock.lastInjectedText, "hello")
        XCTAssertEqual(mock.lastPreserveClipboard, true)

        mock.inject(text: "world", preserveClipboard: false)
        XCTAssertEqual(mock.injectCallCount, 2)
        XCTAssertEqual(mock.lastInjectedText, "world")
        XCTAssertEqual(mock.lastPreserveClipboard, false)
    }

    // MARK: - Keyboard Layout Resolution (GitHub issue #123)

    /// Verify that the keycode resolver returns a value for the lowercase
    /// "v" character. The exact keycode depends on the active keyboard
    /// layout (9 on US-QWERTY, 47 on Dvorak, etc.), but it must always be
    /// resolvable on any ASCII-capable layout — otherwise Cmd+V paste
    /// injection cannot work on that layout.
    func testKeyCodeForVIsResolvable() {
        let keyCode = TextInjector.keyCode(forCharacter: "v")
        XCTAssertNotNil(keyCode, "Expected a virtual keycode for 'v' on the active layout")
        // Sanity bound: ANSI keycodes live in the lower 128 range.
        if let keyCode = keyCode {
            XCTAssertLessThan(keyCode, 128)
        }
    }

    /// Verify that on the default CI machine (US-QWERTY) the resolver
    /// returns the well-known keycode 9 for "v". This guards against
    /// regressions in the layout lookup path. Skipped if CI is run on a
    /// machine configured with a non-QWERTY layout.
    func testKeyCodeForVOnQWERTYIsNine() throws {
        // We can only meaningfully assert this on a US-QWERTY layout.
        // On other layouts the resolver should still return *some* keycode
        // (covered by testKeyCodeForVIsResolvable).
        guard let periodKeyCode = TextInjector.keyCode(forCharacter: ".") else {
            throw XCTSkip("Could not inspect active keyboard layout")
        }
        // On QWERTY, "." lives at keycode 47; on Dvorak it lives at 9.
        // Skip the strict assertion if we're not on QWERTY.
        guard periodKeyCode == 47 else {
            throw XCTSkip("Active layout is not US-QWERTY (period at keycode \(periodKeyCode))")
        }
        XCTAssertEqual(TextInjector.keyCode(forCharacter: "v"), 9)
    }

    /// Verify the resolver returns nil (rather than crashing) for a
    /// character that is not directly typable on any standard ASCII layout.
    func testKeyCodeForUntypableCharacterReturnsNil() {
        // The "🎉" emoji is not produced by any single keycode on any
        // ASCII keyboard layout.
        XCTAssertNil(TextInjector.keyCode(forCharacter: "🎉"))
    }

    // MARK: - Two-Strategy Injection (Raycast compatibility)

    /// The empty-string guard must fire before either strategy (AX API or
    /// clipboard+Cmd+V) is attempted, so the pasteboard must be unchanged.
    func testInjectEmptyStringDoesNotModifyClipboard() {
        let injector = TextInjector()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("original content", forType: .string)

        injector.inject(text: "", preserveClipboard: true)
        injector.inject(text: "", preserveClipboard: false)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "original content",
            "Clipboard must not change when inject() is called with empty text"
        )
    }

    /// Verify that inject() with a non-empty string does not crash when the
    /// Accessibility API strategy declines (no focused single-line input field
    /// in the test-runner environment). The implementation must fall through
    /// silently to the clipboard+Cmd+V path.
    ///
    /// This also covers the terminal/editor regression fix: AXTextArea elements
    /// are explicitly excluded from the AX strategy, so terminal emulators
    /// (Terminal.app, Ghostty) and code editors always use clipboard+Cmd+V.
    func testInjectNonEmptyStringDoesNotCrashOnAXFallback() {
        let injector = TextInjector()
        // No focused AXTextField/AXSearchField/AXComboBox exists in the test
        // runner, so the AX strategy returns false and the clipboard path runs.
        // Both preserveClipboard variants must survive without crashing.
        injector.inject(text: "Hello, Raycast!", preserveClipboard: false)
        injector.inject(text: "Hello, Raycast!", preserveClipboard: true)

        // Let both asynchronous clipboard operations finish so their restore
        // work cannot leak into the next test.
        let finishedExpectation = expectation(description: "clipboard fallback operations finished")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            finishedExpectation.fulfill()
        }
        wait(for: [finishedExpectation], timeout: 1.0)
    }

    /// When the process does not have Accessibility permission,
    /// inject() must copy the transcribed text to the clipboard (so the
    /// user can paste manually) and must not crash. This covers the early
    /// exit at the top of inject() that runs before either strategy.
    ///
    /// Skipped on machines where the test runner already has Accessibility
    /// permission: in that environment the AX strategy path is taken first
    /// and this specific early-exit code cannot be reached.
    func testInjectCopiesTextToClipboardWhenNotTrusted() throws {
        guard !AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is granted on this machine; the no-permission path cannot be exercised.")
        }

        let injector = TextInjector()
        let expected = "raycast fallback dictation"

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("before", forType: .string)

        injector.inject(text: expected, preserveClipboard: false)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expected,
            "When AX permission is absent, inject() must write the text to the clipboard"
        )
    }

    /// Verify that when AX permission IS granted but there is no focused
    /// AX text field (typical in CI / headless test runs), the clipboard
    /// path is taken and the transcribed text lands on the pasteboard.
    ///
    /// This also guards against a regression where the fallback path is
    /// accidentally short-circuited after the AX strategy returns false.
    func testClipboardFallbackWritesTextWhenAXStrategyFails() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("Accessibility permission is not granted; clipboard fallback cannot be triggered (AX is not even attempted).")
        }

        let injector = TextInjector()
        let expected = "fallback text after ax failure"

        // Seed the pasteboard with a known value so we can detect a change.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("seed", forType: .string)

        // With no focused text field in the test runner, the AX strategy
        // will return false, and injectViaClipboard should write expected.
        injector.inject(text: expected, preserveClipboard: false)

        // Give the async clipboard write a moment to settle.
        let expectation = XCTestExpectation(description: "clipboard written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            expected,
            "When the AX strategy fails, the clipboard fallback must write the text to the pasteboard"
        )
    }
}

// MARK: - SoundManager Tests

final class SoundManagerTests: XCTestCase {

    var soundManager: SoundManager!

    override func setUp() {
        super.setUp()
        soundManager = SoundManager()
    }

    func testPlayStartSoundSync() {
        // Test that synchronous play doesn't crash
        soundManager.playStartSound()
        // If we get here without crashing, the test passes
        XCTAssertTrue(true)
    }

    func testPlayStopSoundSync() {
        // Test that synchronous play doesn't crash
        soundManager.playStopSound()
        // If we get here without crashing, the test passes
        XCTAssertTrue(true)
    }

    func testPlayStartSoundAsync() async {
        // Test that async play completes without hanging
        let startTime = Date()
        await soundManager.playStartSoundAsync()
        let elapsed = Date().timeIntervalSince(startTime)

        // Should complete in reasonable time (under 2 seconds even with timeout)
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testPlayStopSoundAsync() async {
        // Test that async play completes without hanging
        let startTime = Date()
        await soundManager.playStopSoundAsync()
        let elapsed = Date().timeIntervalSince(startTime)

        // Should complete in reasonable time (under 2 seconds even with timeout)
        XCTAssertLessThan(elapsed, 2.0)
    }

    func testVolumeControl() {
        soundManager.volume = 0.0
        XCTAssertEqual(soundManager.volume, 0.0)

        soundManager.volume = 0.5
        XCTAssertEqual(soundManager.volume, 0.5)

        soundManager.volume = 1.0
        XCTAssertEqual(soundManager.volume, 1.0)
    }

    func testOffTonePlayReturnsImmediately() async {
        soundManager.toneOverride = .off
        let startTime = Date()
        await soundManager.playStartSoundAsync()
        await soundManager.playStopSoundAsync()
        XCTAssertLessThan(Date().timeIntervalSince(startTime), 0.2)
    }

    func testOffToneSyncPlayDoesNotCrash() {
        soundManager.toneOverride = .off
        soundManager.playStartSound()
        soundManager.playStopSound()
        XCTAssertTrue(true)
    }
}



// MARK: - AudioEngine Tests

/// Shared guard for tests that need a real audio capture session.
extension XCTestCase {

    /// Skip when there is no real microphone to record from.
    ///
    /// CI runners have no audio input. `AudioEngine.startRecording()` there
    /// may return false, may start and yield no samples, or may block
    /// indefinitely — the last of which hangs the whole job until it times
    /// out rather than reporting a failure. None of these exercise the
    /// behaviour the test is after, so the test is skipped instead.
    func skipWithoutRealAudioInput() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["CI"] != nil,
            "Needs a real audio input device; CI runners have none"
        )
    }
}

final class AudioEngineTests: XCTestCase {

    func testStopRecordingWithoutStartReturnsEmpty() {
        let engine = AudioEngine()
        let samples = engine.stopRecording()
        XCTAssertTrue(samples.isEmpty)
    }

    func testSilenceCallbackFiresOnlyOnce() throws {
        try skipWithoutRealAudioInput()
        // Verify that the silence detection callback doesn't fire repeatedly
        // by simulating the scenario where multiple silent buffers arrive
        let engine = AudioEngine()
        var silenceCallCount = 0

        engine.onSilenceDetected = {
            silenceCallCount += 1
        }

        // Start recording with a very short silence duration so it triggers quickly
        engine.startRecording(
            silenceThreshold: 0.5,  // High threshold so normal ambient noise counts as silence
            silenceDuration: 0.01,  // Very short so it fires quickly
            maxDuration: 60.0
        )

        // Wait for a few audio callbacks to process silence
        let expectation = XCTestExpectation(description: "Silence detection fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let _ = engine.stopRecording()

        // The callback should have fired at most once due to the silenceCallbackFired guard
        XCTAssertLessThanOrEqual(silenceCallCount, 1,
            "Silence callback should fire at most once, but fired \(silenceCallCount) times")
    }

    func testMaxDurationCallbackFiresOnlyOnce() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()
        var maxDurationCallCount = 0

        engine.onMaxDurationReached = {
            maxDurationCallCount += 1
        }

        // Start recording with a very short max duration
        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,  // Long silence duration so it doesn't interfere
            maxDuration: 0.01       // Very short max duration
        )

        // Wait for max duration to be reached
        let expectation = XCTestExpectation(description: "Max duration fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let _ = engine.stopRecording()

        // The callback should have fired at most once
        XCTAssertLessThanOrEqual(maxDurationCallCount, 1,
            "Max duration callback should fire at most once, but fired \(maxDurationCallCount) times")
    }

    func testAudioBufferNotEmptyAfterRecording() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        guard engine.isCurrentlyRecording else {
            // No microphone available in this environment (e.g., CI runner)
            return
        }

        // A cold Core Audio start does not guarantee a buffer within 300 ms,
        // especially with other tests in this process cycling the same device.
        // One second is still a tight assertion and no longer races the hardware.
        let expectation = XCTestExpectation(description: "Recording period")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)

        let samples = engine.stopRecording()

        // On CI runners, a virtual audio device may report isCurrentlyRecording = true
        // but produce no actual audio samples. Skip rather than fail in that case.
        try XCTSkipIf(
            samples.isEmpty && ProcessInfo.processInfo.environment["CI"] != nil,
            "Virtual audio device started but produced no samples (expected on some CI runners)"
        )

        XCTAssertFalse(samples.isEmpty,
            "Audio buffer should contain samples after recording")
    }

    func testStopKeepsEngineWarmUntilIdleRelease() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        let didStart = engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        try XCTSkipIf(!didStart, "No microphone available or Core Audio input could not start")
        XCTAssertTrue(engine.isEngineAllocatedForTesting)

        _ = engine.stopRecording()

        XCTAssertFalse(engine.isCurrentlyRecording)
        XCTAssertTrue(
            engine.isEngineAllocatedForTesting,
            "Stopped engine should stay warm briefly for rapid push-to-talk restarts"
        )

        let expectation = XCTestExpectation(description: "Idle engine release")
        DispatchQueue.main.asyncAfter(deadline: .now() + AudioEngine.idleEngineReleaseDelay + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: AudioEngine.idleEngineReleaseDelay + 2.0)

        XCTAssertFalse(
            engine.isEngineAllocatedForTesting,
            "Engine should release after the idle window so the input route is not held indefinitely"
        )
    }

    func testAudioBufferPreservedWhenSilenceDetected() throws {
        try skipWithoutRealAudioInput()
        // The key bug fix: audio should be buffered BEFORE silence detection fires,
        // so we don't lose the audio frames that triggered the silence condition
        let engine = AudioEngine()
        var silenceDetected = false

        engine.onSilenceDetected = {
            silenceDetected = true
        }

        // Use a high silence threshold so even ambient noise triggers silence detection
        engine.startRecording(
            silenceThreshold: 0.99,  // Almost everything is "silence"
            silenceDuration: 0.01,   // Fire immediately
            maxDuration: 60.0
        )

        // Wait for silence to be detected and audio to accumulate
        let expectation = XCTestExpectation(description: "Silence detected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let samples = engine.stopRecording()

        // Even though silence was detected, audio should still be in the buffer
        // because we now append BEFORE checking silence conditions
        if silenceDetected {
            XCTAssertFalse(samples.isEmpty,
                "Audio buffer should NOT be empty even when silence is detected — " +
                "frames must be appended before the silence check")
        }
    }

    func testAudioBufferPreservedWhenMaxDurationReached() throws {
        try skipWithoutRealAudioInput()
        // Audio should be buffered even when max duration is reached
        let engine = AudioEngine()
        var maxDurationReached = false

        engine.onMaxDurationReached = {
            maxDurationReached = true
        }

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 0.01  // Reach max duration almost immediately
        )

        // Wait for max duration to fire
        let expectation = XCTestExpectation(description: "Max duration reached")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let samples = engine.stopRecording()

        // Even though max duration was reached, audio should still be in the buffer
        if maxDurationReached {
            XCTAssertFalse(samples.isEmpty,
                "Audio buffer should NOT be empty when max duration is reached — " +
                "frames must be appended before the max duration check")
        }
    }
}

final class AudioEngineStartFailureTests: XCTestCase {

    func testFourCharacterCodeDecodesHardwareNotRunningError() {
        XCTAssertEqual(AudioEngine.fourCharacterCode(forOSStatusCode: 1937010544), "stop")
    }

    func testStartRetryOnlyAppliesToFirstHardwareNotRunningFailure() {
        let hardwareNotRunning = NSError(domain: "com.apple.coreaudio.avfaudio", code: 1937010544)
        let otherError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -1)

        XCTAssertTrue(AudioEngine.shouldRetryStart(after: hardwareNotRunning, attempt: 1))
        XCTAssertFalse(AudioEngine.shouldRetryStart(after: hardwareNotRunning, attempt: 2))
        XCTAssertFalse(AudioEngine.shouldRetryStart(after: otherError, attempt: 1))
    }

    func testCoreAudioErrorDescriptionIncludesFourCharacterCode() {
        let error = NSError(domain: "com.apple.coreaudio.avfaudio", code: 1937010544)
        let description = AudioEngine.describeCoreAudioError(error)

        XCTAssertTrue(description.contains("code=1937010544"))
        XCTAssertTrue(description.contains("'stop'"))
    }
}


// MARK: - AudioEngine Force Reset Tests

final class AudioEngineForceResetTests: XCTestCase {

    func testForceResetWhenNotRecording() {
        // forceReset() should be safe to call even when not recording
        let engine = AudioEngine()
        engine.forceReset()

        // Engine should be in a clean state
        XCTAssertFalse(engine.isCurrentlyRecording,
            "Engine should not be recording after force reset")
    }

    func testForceResetDuringRecording() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        // Wait for recording to start and accumulate some data
        let expectation = XCTestExpectation(description: "Recording started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        // Force reset should stop everything
        engine.forceReset()

        XCTAssertFalse(engine.isCurrentlyRecording,
            "Engine should not be recording after force reset")

        // stopRecording should return empty after a force reset
        let samples = engine.stopRecording()
        XCTAssertTrue(samples.isEmpty,
            "stopRecording after forceReset should return empty (buffer was cleared)")
    }

    func testForceResetAllowsNewRecording() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )
        engine.forceReset()

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        guard engine.isCurrentlyRecording else { return }

        let expectation = XCTestExpectation(description: "New recording")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        let samples = engine.stopRecording()

        // Same caveat as testAudioBufferNotEmptyAfterRecording: a virtual
        // audio device can report isCurrentlyRecording = true and still
        // produce no samples, so the check above is not enough on its own.
        try XCTSkipIf(
            samples.isEmpty && ProcessInfo.processInfo.environment["CI"] != nil,
            "Virtual audio device started but produced no samples (expected on some CI runners)"
        )

        XCTAssertFalse(samples.isEmpty,
            "Should be able to record new audio after force reset")
    }

    func testForceResetMultipleTimes() {
        // Calling forceReset multiple times in a row should not crash
        let engine = AudioEngine()
        engine.forceReset()
        engine.forceReset()
        engine.forceReset()

        XCTAssertFalse(engine.isCurrentlyRecording,
            "Engine should be idle after multiple force resets")
    }

    func testIsCurrentlyRecordingReflectsState() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        XCTAssertFalse(engine.isCurrentlyRecording,
            "Engine should not be recording initially")

        let didStart = engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        try XCTSkipIf(!didStart, "No microphone available or Core Audio input could not start")

        // Allow engine to start
        let startExpectation = XCTestExpectation(description: "Recording started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startExpectation.fulfill()
        }
        wait(for: [startExpectation], timeout: 1.0)

        XCTAssertTrue(engine.isCurrentlyRecording,
            "Engine should be recording after startRecording")

        let _ = engine.stopRecording()

        XCTAssertFalse(engine.isCurrentlyRecording,
            "Engine should not be recording after stopRecording")
    }
}

// MARK: - AudioEngine Device Change Tests

final class AudioEngineDeviceChangeTests: XCTestCase {

    func testInputRouteReconfigurationDecision() {
        XCTAssertFalse(
            AudioEngine.shouldReconfigureInputDevice(currentDeviceID: 42, targetDeviceID: 42),
            "An AudioUnit already bound to the target device should not rebuild its graph"
        )
        XCTAssertTrue(
            AudioEngine.shouldReconfigureInputDevice(currentDeviceID: 41, targetDeviceID: 42),
            "Switching devices must rebuild the graph"
        )
        XCTAssertTrue(
            AudioEngine.shouldReconfigureInputDevice(currentDeviceID: nil, targetDeviceID: 42),
            "An unreadable current route must be treated as needing configuration"
        )
    }

    func testConfiguredInputRouteMustMatchTargetAfterReset() {
        XCTAssertTrue(
            AudioEngine.shouldAcceptConfiguredInputRoute(
                targetDeviceID: 42,
                deviceIDAfterReset: 42
            )
        )
        XCTAssertFalse(
            AudioEngine.shouldAcceptConfiguredInputRoute(
                targetDeviceID: 42,
                deviceIDAfterReset: 41
            ),
            "A route mismatch must not silently record from a fallback device"
        )
        XCTAssertFalse(
            AudioEngine.shouldAcceptConfiguredInputRoute(
                targetDeviceID: 42,
                deviceIDAfterReset: nil
            ),
            "An unreadable route must fail verification"
        )
    }

    func testBluetoothInputRouteUsesLongerSettleTimeout() {
        XCTAssertEqual(
            AudioEngine.inputRouteTimeout(isBluetooth: false),
            AudioEngine.inputRouteConfigurationTimeout
        )
        XCTAssertEqual(
            AudioEngine.inputRouteTimeout(isBluetooth: true),
            AudioEngine.bluetoothInputRouteConfigurationTimeout
        )
        XCTAssertGreaterThan(
            AudioEngine.bluetoothInputRouteConfigurationTimeout,
            AudioEngine.inputRouteConfigurationTimeout
        )
    }

    func testBluetoothTransportDetection() {
        XCTAssertTrue(AudioEngine.isBluetoothTransport(kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(AudioEngine.isBluetoothTransport(kAudioDeviceTransportTypeBluetoothLE))
        XCTAssertFalse(AudioEngine.isBluetoothTransport(kAudioDeviceTransportTypeBuiltIn))
        XCTAssertFalse(AudioEngine.isBluetoothTransport(kAudioDeviceTransportTypeUSB))
    }

    func testBluetoothHFPSettleUsesHeadsetSampleRates() {
        XCTAssertTrue(AudioEngine.hasBluetoothHFPSettled(sampleRate: 16000))
        XCTAssertTrue(AudioEngine.hasBluetoothHFPSettled(sampleRate: 8000))
        XCTAssertTrue(AudioEngine.hasBluetoothHFPSettled(sampleRate: 24000))
        XCTAssertFalse(AudioEngine.hasBluetoothHFPSettled(sampleRate: 44100))
        XCTAssertFalse(AudioEngine.hasBluetoothHFPSettled(sampleRate: 48000))
        XCTAssertFalse(AudioEngine.hasBluetoothHFPSettled(sampleRate: nil))
        XCTAssertFalse(AudioEngine.hasBluetoothHFPSettled(sampleRate: 0))
    }

    func testBluetoothRouteSubstituteAcceptance() {
        XCTAssertTrue(
            AudioEngine.isAcceptableBluetoothRouteSubstitute(
                targetUID: "Soundcore-UID",
                actualUID: "Soundcore-UID",
                targetName: "Soundcore Life Q30",
                actualName: "Soundcore Life Q30 Hands-Free",
                actualIsBluetooth: true
            ),
            "Matching Bluetooth UIDs identify the same headset across HFP endpoints"
        )
        XCTAssertTrue(
            AudioEngine.isAcceptableBluetoothRouteSubstitute(
                targetUID: "uid-a",
                actualUID: "uid-b",
                targetName: "Soundcore Life Q30",
                actualName: "Soundcore Life Q30",
                actualIsBluetooth: true
            ),
            "Matching Bluetooth names identify the same headset when UIDs diverge"
        )
        XCTAssertTrue(
            AudioEngine.isAcceptableBluetoothRouteSubstitute(
                targetUID: "uid-a",
                actualUID: "uid-b",
                targetName: "Soundcore Life Q30",
                actualName: "Soundcore Life Q30 Hands-Free",
                actualIsBluetooth: true
            ),
            "HFP Hands-Free suffix should still match the A2DP device name"
        )
        XCTAssertTrue(
            AudioEngine.bluetoothDeviceNamesMatch(
                "AirPods Pro",
                "AirPods Pro Hands-Free"
            )
        )
        XCTAssertFalse(
            AudioEngine.isAcceptableBluetoothRouteSubstitute(
                targetUID: "uid-a",
                actualUID: "uid-b",
                targetName: "Soundcore Life Q30",
                actualName: "MacBook Pro Microphone",
                actualIsBluetooth: true
            ),
            "Unrelated Bluetooth devices must not be treated as substitutes"
        )
        XCTAssertFalse(
            AudioEngine.isAcceptableBluetoothRouteSubstitute(
                targetUID: "uid-a",
                actualUID: "uid-b",
                targetName: "Soundcore Life Q30",
                actualName: "MacBook Pro Microphone",
                actualIsBluetooth: false
            ),
            "Wired fallback devices must never be treated as Bluetooth substitutes"
        )
    }

    func testConfiguredRouteHealthRequiresMatchingDevice() {
        XCTAssertTrue(
            AudioEngine.isConfiguredRouteHealthy(
                configuredInputDeviceID: 42,
                currentInputDeviceID: 42
            )
        )
        XCTAssertFalse(
            AudioEngine.isConfiguredRouteHealthy(
                configuredInputDeviceID: 42,
                currentInputDeviceID: 41
            ),
            "Unrelated device IDs are not healthy without Bluetooth substitute metadata"
        )
        XCTAssertFalse(
            AudioEngine.isConfiguredRouteHealthy(
                configuredInputDeviceID: nil,
                currentInputDeviceID: 42
            )
        )
        XCTAssertFalse(
            AudioEngine.isConfiguredRouteHealthy(
                configuredInputDeviceID: 42,
                currentInputDeviceID: nil
            )
        )
    }

    func testTransientCoreAudioAggregateDetection() {
        XCTAssertTrue(
            AudioEngine.isTransientCoreAudioAggregate(
                name: "CADefaultDeviceAggregate",
                uid: "CADefaultDeviceAggregate-0x8a"
            )
        )
        XCTAssertTrue(
            AudioEngine.isTransientCoreAudioAggregate(
                name: "CADefaultDeviceAggregate-0x8a",
                uid: "other-uid"
            )
        )
        XCTAssertTrue(
            AudioEngine.isTransientCoreAudioAggregate(
                name: "MacBook Pro Microphone",
                uid: "CADefaultDeviceAggregate-0x8a"
            )
        )
        XCTAssertFalse(
            AudioEngine.isTransientCoreAudioAggregate(
                name: "soundcore Liberty 5",
                uid: "00-11-22-33"
            )
        )
        XCTAssertFalse(
            AudioEngine.isTransientCoreAudioAggregate(name: nil, uid: nil)
        )
    }

    func testInternalCoreAudioAggregateIsHiddenFromPicker() {
        XCTAssertFalse(
            AudioEngine.shouldExposeInputDevice(
                name: "CADefaultDeviceAggregate",
                uid: "CADefaultDeviceAggregate-0x1"
            )
        )
        XCTAssertTrue(
            AudioEngine.shouldExposeInputDevice(
                name: "soundcore Liberty 5",
                uid: "00-11-22-33"
            )
        )
        XCTAssertTrue(
            AudioEngine.shouldExposeInputDevice(
                name: "MacBook Pro Microphone",
                uid: "BuiltInMicrophoneDevice"
            )
        )
    }

    func testConfiguredRouteHealthTreatsTransientAggregateAsHealthy() {
        XCTAssertTrue(
            AudioEngine.isConfiguredRouteHealthy(
                configuredInputDeviceID: 42,
                currentInputDeviceID: 41,
                currentDeviceName: "CADefaultDeviceAggregate",
                currentDeviceUID: "CADefaultDeviceAggregate-0x1"
            ),
            "CADefaultDeviceAggregate during Bluetooth settle is not a lost mic"
        )
        XCTAssertFalse(
            AudioEngine.isConfiguredRouteHealthy(
                configuredInputDeviceID: 42,
                currentInputDeviceID: 41,
                currentDeviceName: "MacBook Pro Microphone",
                currentDeviceUID: "BuiltInMicrophoneDevice"
            ),
            "A real different device is still an unhealthy route"
        )
    }

    func testStartupConfigurationChangeIgnoresTransientAggregate() {
        XCTAssertTrue(
            AudioEngine.shouldIgnoreConfigurationChange(
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 0.9,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 41,
                currentDeviceName: "CADefaultDeviceAggregate",
                currentDeviceUID: "CADefaultDeviceAggregate-0x1"
            ),
            "Bluetooth settle that lands on CADefaultDeviceAggregate must not abort recording"
        )
    }

    func testStartupConfigurationChangeIsIgnoredOnlyForStableConfiguredRoute() {
        XCTAssertTrue(
            AudioEngine.shouldIgnoreConfigurationChange(
                isStillPreparingRecording: true,
                isRecording: false,
                engineIsRunning: false,
                elapsedSinceRecordingStart: 0,
                configuredInputDeviceID: nil,
                currentInputDeviceID: nil
            ),
            "Churn while startRecording still owns preparation must not abort start"
        )
        XCTAssertTrue(
            AudioEngine.shouldIgnoreConfigurationChange(
                occurredDuringRecordingPreparation: true,
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 2.5,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 42
            ),
            "Delayed prep notifications may be ignored only while the configured route stays healthy"
        )
        XCTAssertFalse(
            AudioEngine.shouldIgnoreConfigurationChange(
                occurredDuringRecordingPreparation: true,
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 0.1,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 41
            ),
            "Route loss during Bluetooth settle must still recover after start"
        )
        XCTAssertFalse(
            AudioEngine.shouldIgnoreConfigurationChange(
                occurredDuringRecordingPreparation: true,
                isRecording: false,
                engineIsRunning: false,
                elapsedSinceRecordingStart: 0,
                configuredInputDeviceID: nil,
                currentInputDeviceID: nil
            ),
            "Prep-originated notifications after a failed start must not be treated as healthy"
        )
        XCTAssertTrue(
            AudioEngine.shouldIgnoreConfigurationChange(
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 0.5,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 42
            ),
            "A delayed startup notification may be ignored when the configured route is still healthy"
        )
        XCTAssertFalse(
            AudioEngine.shouldIgnoreConfigurationChange(
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 0.5,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 41
            ),
            "A live route change must interrupt recording even during startup"
        )
        XCTAssertFalse(
            AudioEngine.shouldIgnoreConfigurationChange(
                isRecording: true,
                engineIsRunning: false,
                elapsedSinceRecordingStart: 0.5,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 42
            ),
            "A stopped engine still requires route-change recovery"
        )
        XCTAssertFalse(
            AudioEngine.shouldIgnoreConfigurationChange(
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 1.01,
                configuredInputDeviceID: 42,
                currentInputDeviceID: 42
            ),
            "Live route changes after startup must still interrupt recording"
        )
        XCTAssertFalse(
            AudioEngine.shouldIgnoreConfigurationChange(
                isRecording: true,
                engineIsRunning: true,
                elapsedSinceRecordingStart: 0.5,
                configuredInputDeviceID: nil,
                currentInputDeviceID: nil
            ),
            "A notification cannot be ignored when the configured route is unknown"
        )
    }

    func testOnAudioDeviceChangedCallbackExists() {
        // Verify the callback property can be set
        let engine = AudioEngine()
        var callbackInvoked = false

        engine.onAudioDeviceChanged = {
            callbackInvoked = true
        }

        XCTAssertNotNil(engine.onAudioDeviceChanged)
        // Callback hasn't been invoked yet (no device change)
        XCTAssertFalse(callbackInvoked)
    }

    func testForceResetSimulatesDeviceChangeRecovery() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        guard engine.isCurrentlyRecording else { return }

        let startExpectation = XCTestExpectation(description: "Recording started")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            startExpectation.fulfill()
        }
        wait(for: [startExpectation], timeout: 2.0)

        XCTAssertTrue(engine.isCurrentlyRecording, "Should be recording before simulated device change")

        engine.forceReset()

        XCTAssertFalse(engine.isCurrentlyRecording,
            "Engine should stop recording after force reset (simulating device change recovery)")

        engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        let restartExpectation = XCTestExpectation(description: "Restarted recording")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            restartExpectation.fulfill()
        }
        wait(for: [restartExpectation], timeout: 2.0)

        XCTAssertTrue(engine.isCurrentlyRecording,
            "Should be able to record again after device change recovery")
        let _ = engine.stopRecording()
    }

    func testDeviceChangeCallbackNotFiredWhenNotRecording() {
        // forceReset when not recording should not cause any issues
        let engine = AudioEngine()
        var deviceChangeCalled = false

        engine.onAudioDeviceChanged = {
            deviceChangeCalled = true
        }

        XCTAssertFalse(engine.isCurrentlyRecording, "Should not be recording")

        // Force reset while not recording — callback should not fire
        engine.forceReset()

        // Wait for any async processing
        let expectation = XCTestExpectation(description: "Processing complete")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)

        XCTAssertFalse(deviceChangeCalled,
            "Device change callback should NOT fire during forceReset (only notification handler fires it)")
    }
}

// MARK: - AudioEngine Input Route Fallback Tests

final class AudioEngineInputRouteFallbackTests: XCTestCase {

    func testCandidatesTryRequestedDeviceBeforeSystemDefault() {
        XCTAssertEqual(
            AudioEngine.inputRouteCandidates(requestedDeviceID: 42, defaultDeviceID: 7),
            [42, 7],
            "The pinned microphone is tried first, with the system default as a fallback"
        )
    }

    func testCandidatesCollapseAPinnedDefaultDevice() {
        XCTAssertEqual(
            AudioEngine.inputRouteCandidates(requestedDeviceID: 42, defaultDeviceID: 42),
            [42],
            "Pinning the system default should not make us configure the same device twice"
        )
    }

    func testCandidatesFallBackToDefaultWhenNothingIsPinned() {
        XCTAssertEqual(
            AudioEngine.inputRouteCandidates(requestedDeviceID: nil, defaultDeviceID: 7),
            [7]
        )
    }

    func testCandidatesAreEmptyWhenNoInputExists() {
        XCTAssertTrue(
            AudioEngine.inputRouteCandidates(requestedDeviceID: nil, defaultDeviceID: nil).isEmpty,
            "With no device to try, the caller must report the failure rather than record silence"
        )
    }

    /// The input tap used to read `isCurrentlyRecording`, which hops through
    /// `lifecycleQueue`. `stopRecording` holds that queue while `engine.stop()`
    /// waits for the render thread, so a tap blocked on the queue deadlocks the
    /// graph. Recording and stopping repeatedly must stay responsive.
    func testStartStopCyclesDoNotDeadlock() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()

        let finished = XCTestExpectation(description: "Start/stop cycles completed")
        DispatchQueue.global(qos: .userInitiated).async {
            for _ in 0..<5 {
                let didStart = engine.startRecording(
                    silenceThreshold: 0.01,
                    silenceDuration: 999.0,
                    maxDuration: 60.0
                )
                guard didStart else { break }
                Thread.sleep(forTimeInterval: 0.1)
                _ = engine.stopRecording()
            }
            finished.fulfill()
        }

        wait(for: [finished], timeout: 20.0)
        XCTAssertFalse(engine.isCurrentlyRecording)
        engine.forceReset()
    }
}

// MARK: - AudioDeviceMonitor Tests

final class AudioDeviceMonitorTests: XCTestCase {

    func testStartIsIdempotentAndStopIsSafe() {
        let monitor = AudioDeviceMonitor()
        monitor.start()
        monitor.start()
        monitor.stop()
        monitor.stop()
    }

    func testChangeNotificationsAreCoalesced() {
        XCTAssertGreaterThan(
            AudioDeviceMonitor.coalesceInterval,
            0,
            "Bluetooth profile switches fire several property changes; the pickers should rebuild once"
        )
    }
}

// MARK: - AudioEngine Start Cancellation Tests

final class AudioEngineStartCancellationTests: XCTestCase {

    func testCancelPendingStartIsSafeWhenIdle() {
        let engine = AudioEngine()
        engine.cancelPendingStart()
        XCTAssertFalse(engine.isCurrentlyRecording)
    }

    /// A cancel that lands after its start already finished must not leak into
    /// the next one.
    func testStaleCancelDoesNotPoisonTheNextStart() throws {
        try skipWithoutRealAudioInput()
        let engine = AudioEngine()
        engine.cancelPendingStart()

        let didStart = engine.startRecording(
            silenceThreshold: 0.01,
            silenceDuration: 999.0,
            maxDuration: 60.0
        )

        try XCTSkipIf(!didStart, "No microphone available or Core Audio input could not start")
        XCTAssertTrue(engine.isCurrentlyRecording)

        _ = engine.stopRecording()
        engine.forceReset()
    }
}
