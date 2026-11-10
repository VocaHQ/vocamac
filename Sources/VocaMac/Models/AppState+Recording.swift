// AppState+Recording.swift
// VocaMac
//
// Recording: force recovery, the recording flow, process while speaking, and dictation state. Moved out of AppState.swift unchanged.

import Foundation
import SwiftUI
import Combine
import AppKit
import os

extension AppState {

    // MARK: - Force Recovery

    /// Forcibly reset the entire recording pipeline to idle state.
    /// This is a last-resort recovery mechanism callable from the menu bar UI.
    /// It unconditionally resets the audio engine, hotkey state, cursor overlay,
    /// and all published state back to idle.
    func forceRecovery() {
        recordingGeneration = UUID()
        queuedRecordingStart = nil
        // The engine is reset below, which closes an early capture too. Its
        // mute and pause were never tied to `isRecording`, so undo them here.
        if earlyCapture != nil {
            earlyCapture = nil
            audioEngine.onAudioSamples = nil
            audioDucker.restore()
            spotifyPauser.resume()
        }
        cancelFinishingWork()
        // A load that never returns would otherwise hold every later load
        // and dictation behind it; the router drops the model it was loading.
        inFlightModelLoad?.cancel()
        VocaLogger.warning(.appState, "Force recovery: resetting all state to idle (was appStatus=\(appStatus.rawValue), isRecording=\(isRecording))")

        // Reset audio engine unconditionally
        audioEngine.forceReset()

        // Reset hotkey tracking state
        hotKeyManager.resetKeyState()

        // Reset UI state
        isRecording = false
        transcriber.cancelVoiceActivityStream()
        audioLevel = 0.0
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
        isTranscribing = false
        resetCommandModeState()
        liveTranscript = ""
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
        insertionContextTask?.cancel()
        insertionContextTask = nil
        if let id = activeHistoryEntryID {
            historyStore.markCancelled(id)
            activeHistoryEntryID = nil
        }
    }

    /// Play start, then stop, for the tone currently selected in Settings.
    /// Off is silence. Preview is not gated by the sound-effects switch.
    func previewDictationTone() async {
        await soundManager.previewStartThenStop()
    }

    // MARK: - Recording Flow

    func startRecording(
        injectResult: Bool = true,
        outputDestination: ScratchpadOutputDestination = .settingsTest,
        verifiesShortcut: Bool = false
    ) async {
        beginDictationOperation()
        defer { endDictationOperation("start") }
        let interval = PerformanceTrace.begin("RecordingStart")
        defer { PerformanceTrace.end(interval) }
        overlayPreview.stop()
        // If we're already recording, this is a recovery attempt — the user
        // pressed the hotkey again because a previous key-up was missed.
        // Stop the current recording and transcribe what we have.
        if isCapturingAudio {
            VocaLogger.warning(.appState, "startRecording called while already recording — treating as stop (recovery)")
            await stopRecordingAndTranscribe()
            return
        }

        if isAutoPaused {
            let message = autoPausedMessage
            VocaLogger.info(.appState, message)
            endHotKeyToggleSession()
            showOverlayFailure(message)
            showTemporaryError(message)
            return
        }

        // A file or system-audio transcription owns the speech model and shows
        // as processing. Treating that as a stuck state would force-recover
        // mid-job and run two decodes on one model.
        if isTranscribingMedia {
            VocaLogger.info(.appState, "Dictation ignored while a file or system-audio transcription is running")
            endHotKeyToggleSession()
            errorMessage = "VocaMac is transcribing audio. Dictation is available when it finishes."
            let message = errorMessage
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.errorMessage == message { self?.errorMessage = nil }
            }
            return
        }

        // Teaching a Dictionary word holds the microphone and the model.
        if isTeachingWord {
            VocaLogger.info(.appState, "Dictation ignored while a Dictionary word is being taught")
            endHotKeyToggleSession()
            showTemporaryError("VocaMac is listening for a Dictionary word. Dictation is available when you finish.")
            return
        }

        if isLoadingModelForRecording {
            VocaLogger.info(.appState, "Dictation already starting while the speech model loads — ignoring")
            return
        }

        // The previous dictation is still being transcribed, cleaned up, or
        // delivered. Never throw it away: start this one when it's done.
        if isTranscribing {
            if queuedRecordingStart != nil, let early = earlyCapture, early.releasedAtSampleCount != nil {
                // Pressed again before the queued dictation could start. Its
                // microphone never closed, so it simply carries on.
                early.releasedAtSampleCount = nil
                VocaLogger.info(.appState, "Queued dictation resumed before it started")
            } else if queuedRecordingStart != nil {
                // Toggle-style triggers (hands-free, menu) press again to stop.
                queuedRecordingStart = nil
                discardEarlyCapture()
                VocaLogger.info(.appState, "Queued dictation withdrawn before it started")
            } else {
                queuedRecordingStart = QueuedRecordingStart(
                    injectResult: injectResult,
                    outputDestination: outputDestination,
                    isHandsFree: isHandsFreeSession,
                    verifiesShortcut: verifiesShortcut,
                    trigger: dictationTrigger
                )
                VocaLogger.info(.appState, "Dictation requested while the previous one is still finishing — starting when it's delivered")
                // Push to talk speaks while the key is down; toggle-style
                // starts withdraw on the next press, so only a hold records early.
                if activationMode == .pushToTalk, !isHandsFreeSession, activeCommandTarget == nil,
                   micPermission == .granted {
                    beginEarlyCapture()
                }
            }
            return
        }

        switch appStatus {
        case .idle, .recording:
            break
        case .error:
            // An error only reports something that already happened. Clear it
            // and start, rather than making the user press twice.
            errorMessage = nil
            appStatus = .idle
        case .processing:
            // Processing with no transcription, model load, or media job
            // behind it is a stuck status. Clear it and start in one press
            // (not `forceRecovery`, which would forget the key being held).
            VocaLogger.warning(.appState, "startRecording found a stale processing state — clearing it and starting")
            errorMessage = nil
            appStatus = .idle
        }

        // Snapshot the target app now. Injection re-reads the frontmost app —
        // that is what actually receives the text — and only falls back to this
        // when VocaMac itself is in front at that point.
        pendingTargetApp = frontmostAppResolver.currentFrontmostApp()

        // Starting another dictation means the user is done fixing the last one.
        correctionObserver?.flush()

        guard micPermission == .granted else {
            endHotKeyToggleSession()
            showOverlayFailure("Microphone access is off.")
            errorMessage = "Microphone permission is required. Please grant access in System Settings."
            appStatus = .error
            return
        }

        // Lazy-reload after idle unload (or any other cold start).
        if !transcriber.isModelLoaded {
            // The first download can take minutes. Say so instead of leaving
            // the hotkey looking stuck on "processing" until it finishes.
            if startupModelPreparation != nil,
               availableModels.contains(where: { $0.downloadProgress != nil }) {
                let message = "The speech model is still downloading. Dictation will work as soon as it finishes."
                VocaLogger.info(.appState, message)
                endHotKeyToggleSession()
                showOverlayFailure("The speech model is still downloading.")
                showTemporaryError(message)
                return
            }
            appStatus = .processing
            isLoadingModelForRecording = true
            pendingStopDuringModelLoad = nil
            // Listen while the model loads, as for a queued dictation: the
            // microphone opens now and the recording is decoded once the
            // model is ready. Before, it opened only after the load, and a
            // key released in the meantime recorded nothing. Command Mode
            // keeps its own start (and its double chime) after the load.
            if activeCommandTarget == nil {
                beginEarlyCapture()
                if showCursorIndicator && overlayStyle != .off {
                    cursorOverlay.recordingLimit = maxRecordingDuration > 0 ? TimeInterval(maxRecordingDuration) : nil
                    cursorOverlay.show(style: overlayStyle, position: overlayPosition)
                    cursorOverlay.setStopHint(overlayStopHint)
                    cursorOverlay.setLoadingSpeechModel(true)
                }
            }
            // The cleanup model loads with llama.cpp on the GPU while the
            // speech model loads on the Neural Engine. When memory has room
            // for both, as at launch, start it now: after the speech model,
            // its load and prompt read were left for after the user stopped.
            if injectResult, activeCommandTarget == nil, transcriptCleanupEnabled, startupFitsBothModels() {
                let target = frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp
                Task { @MainActor [weak self] in
                    await self?.warmCleanupModel(for: target)
                }
            }
            // A dictation is waiting: the load hands the model over without
            // its warm-up decode, which this dictation would only wait for.
            // Set before waiting on the launch load too, so a dictation that
            // starts while that load runs skips its warm-up as well.
            transcriber.setRecordingWaitingForLoad(true)
            if let startupModelPreparation {
                await startupModelPreparation.value
            }
            await ensureModelLoaded()
            transcriber.setRecordingWaitingForLoad(false)
            isLoadingModelForRecording = false
            cursorOverlay.setLoadingSpeechModel(false)
            let pendingStop = pendingStopDuringModelLoad
            pendingStopDuringModelLoad = nil
            // Auto-pause began while the model loaded. Its unload found
            // nothing loaded yet, so the model is resident now: unload it
            // and refuse the dictation as a paused start would.
            if isAutoPaused {
                discardEarlyCapture()
                let message = autoPausedMessage
                VocaLogger.info(.appState, "Auto-pause began while the speech model loaded: \(message)")
                endHotKeyToggleSession()
                showOverlayFailure(message)
                showTemporaryError(message)
                await unloadModelForAutoPause()
                return
            }
            guard transcriber.isModelLoaded else {
                discardEarlyCapture()
                endHotKeyToggleSession()
                showOverlayFailure("Couldn't load the speech model.")
                showTemporaryError("Could not load the speech model. Open Settings → Speech Model and try again.")
                return
            }
            appStatus = .idle
            // The hotkey was released while the model loaded, with the
            // microphone already recording: transcribe what was said while
            // the key was down, as a queued dictation does.
            if pendingStop == .transcribe, let releasedAt = earlyCapture?.releasedAtSampleCount, releasedAt > 0 {
                VocaLogger.info(.appState, "Dictation ended while the speech model was loading — transcribing what was recorded")
                await startRecording(
                    injectResult: injectResult, outputDestination: outputDestination, verifiesShortcut: verifiesShortcut
                )
                if isCapturingAudio {
                    await stopRecordingAndTranscribe(endsHotKeyToggle: true, keepingFirst: releasedAt)
                }
                // A start that never reached the microphone leaves nothing to adopt.
                discardEarlyCapture()
                return
            }
            // Released before the microphone captured anything, or Escape:
            // starting now would leave the microphone recording with nobody
            // holding the key.
            if let pendingStop {
                discardEarlyCapture()
                cursorOverlay.hide()
                VocaLogger.info(.appState, "Dictation ended while the speech model was loading — not starting a recording")
                hotKeyManager.resetKeyState()
                if pendingStop == .transcribe {
                    showTemporaryError("The speech model was still loading, so nothing was recorded. It's ready now — try again.")
                }
                return
            }
        }

        recordingGeneration = UUID()
        let generation = recordingGeneration
        recordingInjectsResult = injectResult
        recordingVerifiesShortcut = verifiesShortcut
        nonInjectedOutputDestination = outputDestination
        // Typing into the field would move the selection an edit under
        // review is waiting on.
        dismissCommandReview()
        startScreenContextCapture(injectResult: injectResult)
        codingAgentTask?.cancel()
        codingAgentTask = injectResult
            ? (frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp).flatMap(codingAgentDetection(for:))
            : nil
        // A dictation is coming: have the cleanup model loaded and its prompt
        // read by the time the user stops speaking.
        if injectResult, activeCommandTarget == nil {
            let target = frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp
            // The prompt a coding agent's terminal will use, not Terminal's.
            let agentTask = codingAgentTask
            Task { @MainActor [weak self] in
                let agentTerminal = await Self.value(of: agentTask, within: Self.screenContextTimeout, otherwise: nil)
                await self?.warmCleanupModel(for: target, codingAgentTerminal: agentTerminal)
            }
        }
        appStatus = .recording
        liveTranscript = ""
        isRecording = true
        errorMessage = nil
        inputDeviceFallbackNotice = nil

        // Show the overlay in its connecting state. It only claims to be
        // listening once the audio engine confirms the route is live — on
        // Bluetooth that can be seconds later, and anything said before then is
        // not captured by anyone.
        if showCursorIndicator && overlayStyle != .off {
            cursorOverlay.recordingLimit = maxRecordingDuration > 0 ? TimeInterval(maxRecordingDuration) : nil
            cursorOverlay.show(style: overlayStyle, position: overlayPosition)
            cursorOverlay.setStopHint(overlayStopHint)
            cursorOverlay.setCommandSession(commandModeSession)
        }

        // Start recording immediately for instant responsiveness.
        // The start sound is played concurrently — any brief bleed into the
        // mic buffer is negligible and handled well by WhisperKit's noise model.
        isStartingAudio = true
        pendingStopDuringStart = nil
        let partialHandler: (@Sendable (String) -> Void)?
        if overlayStyle == .live {
            partialHandler = { [weak self] text in
                _ = Task<Void, Never> { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.liveTranscript = text
                    self.cursorOverlay.updateTranscript(text)
                }
            }
        } else {
            partialHandler = nil
        }
        // A microphone opened early for this dictation already holds its
        // start. A live session would miss that audio, so it is decoded whole.
        let adoptedCapture = earlyCapture
        earlyCapture = nil
        let commit = adoptedCapture == nil
            ? commitOptionsForRecording(injectResult: injectResult, generation: generation) : nil
        let session = adoptedCapture == nil ? transcriber.startStreaming(
            language: selectedLanguage == "auto" ? nil : selectedLanguage,
            vocabulary: recognitionHintVocabulary,
            liveVocabulary: recordingVocabulary ?? sessionVocabulary(),
            onPartial: partialHandler,
            commit: commit
        ) : nil
        if commit == nil || session == nil {
            recordingSpeculator = nil
            recordingVocabulary = nil
        }
        recordingProcessesWhileSpeaking = commit != nil && session != nil
        // Only promise live words when an engine will actually send them:
        // Whisper, Parakeet and ONNX decode partial snapshots; the Apple
        // Speech session streams audio but reports text only when it finishes.
        let recordingEngine = ModelSize(rawValue: selectedModelSize)?.engine
        let engineSendsPartials = [.whisperKit, .parakeet, .sherpaOnnx].contains(recordingEngine)
        cursorOverlay.setLiveWordsAvailable(session != nil && partialHandler != nil && engineSendsPartials)
        recordingTranscription = session
        // A recording decoded whole at stop has its silence found while it
        // is made, so the stop is left only the last fraction of a second.
        // A microphone opened early holds audio the stream never saw, and
        // Apple Speech finishes its own session without a batch decode.
        let voiceActivity = adoptedCapture == nil && !recordingProcessesWhileSpeaking
            && recordingEngine != .appleSpeech
            ? transcriber.startVoiceActivityStream() : nil
        audioEngine.onAudioSamples = Self.sampleObserver(session: session, voiceActivity: voiceActivity)
        let didStartRecording: Bool
        if let adoptedCapture {
            didStartRecording = await adoptedCapture.start.value
        } else {
            didStartRecording = await startConfiguredAudioEngine()
        }
        isStartingAudio = false

        // The hotkey was released (or the overlay cancelled) while the route was
        // still coming up. That stop was deferred so it wouldn't block behind the
        // Bluetooth settle; finish it now.
        if let pendingStop = pendingStopDuringStart {
            pendingStopDuringStart = nil
            await finishStartInterruptedByStop(pendingStop, didStartRecording: didStartRecording)
            return
        }

        guard didStartRecording else {
            VocaLogger.warning(.appState, "Audio engine failed to start — resetting recording state")
            showOverlayFailure("Couldn't start the microphone.")
            discardRecordingState()
            // Silently dropping back to idle looks like the hotkey did nothing.
            // Tell the user which microphone we tried and where to change it.
            let deviceDescription = selectedAudioDeviceName.isEmpty
                ? "the system default microphone"
                : selectedAudioDeviceName
            showTemporaryError("Could not start \(deviceDescription). Pick a different input in Settings → Audio, or reconnect the device.")
            return
        }

        cursorOverlay.transitionToRecording()
        // Announced now, not when the status changed: until the microphone is
        // live (seconds on Bluetooth) anything said is lost.
        DictationAnnouncement.post(DictationAnnouncement.recordingStarted(isCommandMode: commandModeSession != nil))

        // Spotify Connect plays through another device, outside the Mac's
        // mixer, so muting cannot reach it — only a transport pause can. Ask
        // for it the moment the microphone is live (not on a failed start,
        // which leaves playback alone); the pause itself takes a few hundred
        // milliseconds. Undone from `isRecording`'s observer on every exit.
        guard isRecording && appStatus == .recording && recordingGeneration == generation else { return }
        if pauseSpotifyEnabled {
            spotifyPauser.pause()
        }

        // Off is a stored tone and stays silent even when this switch is on.
        // An adopted early capture played its cue when its microphone opened.
        let playsCue = soundEffectsEnabled && adoptedCapture == nil
        let isCommand = activeCommandTarget != nil
        guard duckOtherAudioEnabled else {
            if playsCue {
                if isCommand { soundManager.playCommandStartSound() } else { soundManager.playStartSound() }
            }
            return
        }

        // Muting is the whole output device, so it silences the cue too.
        // A dictation mutes first: the music stopping is the cue, and the
        // first words are not recorded over the music while a chime plays.
        // The chime still plays when nothing else was playing.
        if !isCommand {
            let mutedOtherAudio = audioDucker.duck()
            if playsCue && !mutedOtherAudio {
                soundManager.playStartSound()
            }
            return
        }

        // Command Mode tells the user to wait for its double chime, so it
        // keeps the chime and mutes once it has played. The recording may
        // have ended, or a new one begun, while the cue played.
        if playsCue {
            await soundManager.playCommandStartSoundAsync()
        }
        if isRecording && appStatus == .recording && recordingGeneration == generation {
            audioDucker.duck()
        }
    }

    /// Whether a live session's result is used whatever the screen context
    /// brings, so its input can end the moment the microphone stops.
    ///
    /// Whisper is the exception: its pieces read the vocabulary when they are
    /// decoded, and a tail decoded before the screen terms arrived would send
    /// the recording to the batch path instead.
    private func endsSessionInputAtStop(liveVocabulary: LiveVocabulary?) -> Bool {
        guard ModelSize(rawValue: selectedModelSize)?.engine == .whisperKit else { return true }
        return !translatesSpeech && liveVocabulary?.isSettled == true
    }

    // MARK: - Process while speaking

    /// The recognition vocabulary for a live session, updated with the
    /// screen's terms as soon as they are read.
    private func sessionVocabulary() -> LiveVocabulary {
        let vocabulary = LiveVocabulary(recognitionHintVocabulary, settled: screenContextTask == nil)
        if let contextTask = screenContextTask {
            let customVocabulary = customVocabulary
            let replacementTargets = replacementTargets
            let usage = termUsage
            Task { @MainActor in
                let terms = await contextTask.value
                vocabulary.update(Self.recognitionVocabulary(
                    customVocabulary, replacementTargets: replacementTargets, contextTerms: terms, usage: usage
                ))
            }
        }
        return vocabulary
    }

    /// Commit-mode options for a new recording, or nil to record as before.
    /// Also creates the recording's cleanup speculator and live vocabulary.
    ///
    /// Only real dictations commit pieces: Command Mode needs the whole
    /// instruction, previews and practice show batch output, and Whisper
    /// translation always decodes the whole recording.
    private func commitOptionsForRecording(injectResult: Bool, generation: UUID) -> StreamingCommitOptions? {
        recordingSpeculator = nil
        recordingVocabulary = nil
        // The custom endpoint is batch-only: one upload per recording. Commit
        // mode would mean an upload per piece, so it stays off for it.
        guard processWhileSpeaking, injectResult, activeCommandTarget == nil,
              let model = ModelSize(rawValue: selectedModelSize),
              model.engine != .customEndpoint,
              // A streaming export transcribes the whole recording as it
              // comes; pieces would decode it twice.
              !(parakeetLiveStreaming && model.transcribesWhileSpeaking),
              !(model.engine == .whisperKit && translatesSpeech) else { return nil }
        let engine = model.engine
        guard !isPowerConstrained() else {
            VocaLogger.info(.appState, "Process while speaking paused: Low Power Mode or thermal pressure")
            return nil
        }

        let vocabulary = sessionVocabulary()
        recordingVocabulary = vocabulary

        // Cleanup ahead of time only on this Mac: an endpoint would be sent
        // pieces that may never be used.
        if transcriptCleanupEnabled, cleanupEndpoint.isLocal {
            recordingSpeculator = makeSpeculator(
                target: frontmostAppResolver.currentFrontmostApp() ?? pendingTargetApp,
                contextTask: screenContextTask,
                documentURLTask: screenDocumentURLTask,
                codingAgentTask: codingAgentTask
            )
        }

        let onPiece: @Sendable (Int, TranscribedPiece) -> Void = { [weak self] index, piece in
            Task { @MainActor [weak self] in
                self?.submitPiece(piece, index: index, generation: generation)
            }
        }
        var readVocabulary: (@Sendable () -> String)?
        var isReadyForEarlyDecode: (@Sendable () -> Bool)?
        // A model that takes no vocabulary prompt has nothing to wait for.
        if engine == .whisperKit, model.acceptsVocabularyPrompt {
            readVocabulary = { vocabulary.read() }
            isReadyForEarlyDecode = { vocabulary.isSettled }
        }
        // A session that ends on silence stops after `silenceDuration` of
        // quiet, which is time to decode (and clean) the last piece before
        // stop. Push to talk ends when the key comes up, in recorded
        // dictations usually within a third of a second of the last word:
        // there, early decodes at every pause cost far more than they save.
        let stopsOnSilence = activationMode == .doubleTapToggle || isHandsFreeSession
        return StreamingCommitOptions(
            onPiece: onPiece,
            // The piece being spoken, decoded early: cleaned the same way, and
            // simply not found at stop if speech went on.
            onTentativePiece: onPiece,
            vocabulary: readVocabulary,
            earlyDecodeQuietSeconds: stopsOnSilence ? Self.earlyDecodeQuietSeconds(silenceDuration: silenceDuration) : nil,
            isReadyForEarlyDecode: isReadyForEarlyDecode,
            // Corrections are free without cleanup; with it, each corrected
            // piece would be cleaned twice (see `revisesPrevious`).
            revisesPrevious: recordingSpeculator == nil
        )
    }

    /// Quiet before the last piece is decoded early, in a session that stops
    /// after `silenceDuration` of it: a third of the way in, leaving the rest
    /// for the decode and its cleanup, and no sooner than 0.3 s, so ordinary
    /// pauses between words don't each cost a decode.
    nonisolated static func earlyDecodeQuietSeconds(silenceDuration: Double) -> Double {
        min(1.0, max(0.3, SilenceDetectionSettings.clampedDuration(silenceDuration) / 3))
    }

    nonisolated static func systemIsPowerConstrained(_ info: ProcessInfo = .processInfo) -> Bool {
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    private func submitPiece(_ piece: TranscribedPiece, index: Int, generation: UUID) {
        guard recordingGeneration == generation else { return }
        (recordingSpeculator ?? finishingSpeculator)?.submit(piece, index: index)
    }

    /// A speculator whose options match what the stop path will use, as far
    /// as can be known while recording. Anything that turns out different at
    /// stop (another app in front, new dictionary words) changes the request,
    /// and that piece is simply cleaned again.
    private func makeSpeculator(
        target: RunningAppSnapshot?,
        contextTask: Task<[String], Never>?,
        documentURLTask: Task<URL?, Never>?,
        codingAgentTask: Task<RunningAppSnapshot?, Never>?
    ) -> CleanupSpeculator {
        var cachedProfile: WritingProfile?
        var cachedTerms: [String]?
        return CleanupSpeculator(pipeline: dictationOutputPipeline) { [weak self] language in
            guard let self else { return nil }
            if cachedProfile == nil {
                let documentURL = await Self.awaitDocumentURL(documentURLTask)
                let agentTerminal = await Self.value(of: codingAgentTask, within: Self.screenContextTimeout, otherwise: nil)
                cachedProfile = self.nextWritingProfile
                    ?? self.resolveWritingStyle(
                        for: target, documentURL: documentURL, codingAgentTerminal: agentTerminal
                    ).profile
            }
            // Cleanup ahead of time isn't on anyone's wait, so it can give the
            // screen read longer than the stop path's 0.3 s. A read that
            // still hasn't answered isn't remembered as "no terms": the
            // final pass would then get the terms, its glossary would differ,
            // and every answer worked out ahead would go unused.
            if cachedTerms == nil, let contextTask {
                let terms = await Self.value(
                    of: Task { Optional(await contextTask.value) },
                    within: Self.speculationContextTimeout, otherwise: nil
                )
                cachedTerms = terms
            }
            guard let profile = cachedProfile else { return nil }
            return self.dictationOptions(profile: profile, language: language, contextTerms: cachedTerms ?? [])
        }
    }

    private static func logPieceSummary(
        result: VocaTranscription,
        speculator: CleanupSpeculator?,
        stopToResult: TimeInterval
    ) {
        let tailSeconds = result.pieces.last.map { Double($0.range.count) / 16_000 } ?? 0
        var line = "Process while speaking: \(result.pieces.count) pieces, "
            + "tail \(String(format: "%.1f", tailSeconds))s, "
            + "stop to result \(String(format: "%.2f", stopToResult))s"
        if let speculator {
            line += ", cleanup hits \(speculator.hitCount), misses \(speculator.missCount), "
                + "cancelled \(speculator.cancelledCount) of \(speculator.submittedCount) submitted"
        }
        VocaLogger.info(.appState, line)
    }

    private func automaticExternalInputIfNeeded() -> AudioDevice? {
        guard externalMicWhenLidClosed, isLidClosed() else { return nil }
        let devices = availableInputDevices()
        if let selected = devices.first(where: { $0.id == selectedAudioDeviceID }), !selected.isBuiltIn {
            return nil
        }
        let external = devices.filter { !$0.isBuiltIn }
            .sorted { lhs, rhs in lhs.isDefault && !rhs.isDefault }
            .first
        if let external {
            inputDeviceFallbackNotice = "MacBook lid is closed — recording from \(external.name)."
        }
        return external
    }

    func stopRecordingAndTranscribe(injectResult: Bool = true) async {
        await stopRecordingAndTranscribe(endsHotKeyToggle: true)
    }

    /// - Parameter endsHotKeyToggle: False only when the hotkey itself asked
    ///   for the stop. Any other stop (silence, the time limit, the menu or
    ///   overlay) must also end the hotkey's double-tap session, or the next
    ///   double-tap would be taken as a stop and do nothing.
    /// - Parameter keepingFirst: Keep only this many samples: a queued
    ///   dictation whose key came up before it could start is stopped late,
    ///   and only what was said while the key was down belongs to it.
    func stopRecordingAndTranscribe(endsHotKeyToggle: Bool, keepingFirst: Int? = nil) async {
        beginDictationOperation()
        defer { endDictationOperation("stop") }
        // Start-time recordingInjectsResult alone decides injection.
        // Practice/settings UIs cannot demote an ordinary hotkey session.
        let injectResult = recordingInjectsResult
        let interval = PerformanceTrace.begin("StopToResultQueued")
        defer { PerformanceTrace.end(interval) }
        // Accept stop if we're recording OR if the audio engine thinks
        // it's recording (covers stuck-state recovery scenarios where
        // isRecording and appStatus may be out of sync).
        guard isCapturingAudio else {
            if isLoadingModelForRecording {
                pendingStopDuringModelLoad = .transcribe
                // The microphone opened while the model loads; keep what it
                // heard until now and transcribe it once the model is ready.
                if let early = earlyCapture, early.releasedAtSampleCount == nil {
                    early.releasedAtSampleCount = early.counter.releaseBoundary()
                    if soundEffectsEnabled { soundManager.playStopSound() }
                    cursorOverlay.transitionToProcessing()
                }
                return
            }
            if queuedRecordingStart != nil, let early = earlyCapture, early.releasedAtSampleCount == nil {
                // The microphone opened early, so what was said is kept and
                // transcribed once the previous dictation is delivered.
                early.releasedAtSampleCount = early.counter.releaseBoundary()
                if soundEffectsEnabled { soundManager.playStopSound() }
                VocaLogger.info(.appState, "Queued dictation ended before it could start — transcribing it next")
                return
            }
            if queuedRecordingStart != nil {
                // Released (or toggled off) before the previous dictation
                // finished, so this one never started.
                queuedRecordingStart = nil
                VocaLogger.info(.appState, "Queued dictation ended before it could start")
            }
            return
        }
        if endsHotKeyToggle {
            endHotKeyToggleSession()
        }
        let stopRequested = ProcessInfo.processInfo.systemUptime

        // A start that is still negotiating its input route holds the audio
        // engine's lifecycle queue. Calling stopRecording() here would block the
        // hotkey path for the whole Bluetooth settle and then hand back an empty
        // buffer — the "No microphone audio detected" report. Ask the engine to
        // abandon the start instead and let startRecording() finish up.
        if isStartingAudio {
            pendingStopDuringStart = .transcribe
            audioEngine.cancelPendingStart()
            return
        }

        guard !isStoppingAudio else { return }
        isStoppingAudio = true
        let generation = recordingGeneration
        var audioData = await stopAudioEngine()
        // Zero is a real limit: the key came up before the microphone
        // delivered anything, so nothing recorded since belongs to it.
        if let keepingFirst, keepingFirst >= 0, audioData.count > keepingFirst {
            audioData = Array(audioData.prefix(keepingFirst))
        }
        isStoppingAudio = false
        guard generation == recordingGeneration else { return }
        let session = recordingTranscription
        recordingTranscription = nil
        finishingTranscription = session
        let speculator = recordingSpeculator
        recordingSpeculator = nil
        finishingSpeculator = speculator
        let liveVocabulary = recordingVocabulary
        recordingVocabulary = nil
        // Let the engine start on the last piece now: saving to History and
        // waiting for the screen context below then overlap its decode.
        if let session, endsSessionInputAtStop(liveVocabulary: liveVocabulary) {
            session.endInput(expectedSampleCount: audioData.count)
        }
        let processedWhileSpeaking = recordingProcessesWhileSpeaking
        let stopStarted = ProcessInfo.processInfo.systemUptime
        defer {
            session?.cancel()
            if finishingTranscription === session { finishingTranscription = nil }
            speculator?.cancelAll()
            if finishingSpeculator === speculator { finishingSpeculator = nil }
        }
        isRecording = false
        audioLevel = 0.0

        // Play stop sound
        if soundEffectsEnabled {
            soundManager.playStopSound()
        }

        // Transition cursor indicator to processing state (red -> purple)
        // Keeps the overlay visible so the user knows text is on its way
        cursorOverlay.transitionToProcessing()

        guard !audioData.isEmpty else {
            resetCommandModeState()
            liveTranscript = ""
            cursorOverlay.hide()
            appStatus = .idle
            return
        }

        guard audioData.contains(where: { abs($0) >= 0.0001 }) else {
            resetCommandModeState()
            showOverlayFailure("No audio from the microphone.")
            cursorOverlay.hide()
            // Don't keep a route warm when it produced only silence.
            audioEngine.forceReset()
            let message = "No microphone audio detected. Check that the selected microphone is connected and available in Settings → Audio."
            VocaLogger.warning(.appState, message)
            showTemporaryError(message)
            return
        }

        appStatus = .processing
        isTranscribing = true
        defer {
            if generation == recordingGeneration { isTranscribing = false }
        }
        // Copy the clipboard while the speech is decoded, not after the text
        // is ready. The paste reuses it only if the board is unchanged, and
        // the release (queued behind that paste) drops it either way.
        if injectResult, preserveClipboard {
            textInjector.prepareClipboardSnapshot()
        }
        defer {
            if injectResult, preserveClipboard { textInjector.releasePreparedClipboardSnapshot() }
        }

        let contextTask = screenContextTask
        screenContextTask = nil
        let documentURLTask = screenDocumentURLTask
        screenDocumentURLTask = nil
        let insertionTask = insertionContextTask
        insertionContextTask = nil
        let insertionContextRead = Task {
            await Self.value(of: insertionTask, within: Self.screenContextTimeout, otherwise: nil)
        }
        let agentTask = codingAgentTask
        codingAgentTask = nil
        let codingAgentRead = Task { await Self.value(of: agentTask, within: Self.screenContextTimeout, otherwise: nil) }
        // Both screen reads wait out one timeout together, alongside the
        // History write, rather than one after the other.
        let contextTermsRead = Task { await Self.awaitContextTerms(contextTask) }
        let documentURLRead = Task { await Self.awaitDocumentURL(documentURLTask) }
        // A website rule is checked against the page in front now, while the
        // speech is decoded, rather than in another Accessibility read after
        // it. A page changed during the decode itself is not noticed.
        let documentURLCheck = Task { @MainActor [weak self] () -> URL? in
            let captured = await documentURLRead.value
            return await self?.revalidatedDocumentURL(captured)
        }
        // The field is read again at key-up, while the speech is decoded,
        // rather than after cleanup: a move to another field while speaking
        // is still noticed, and the read no longer adds to the wait. A move
        // during the decode itself is left to the app check at delivery.
        let insertionContextAtStop: Task<InsertionContext?, Never>?
        if injectResult, writingStyleEnabled, let reader = screenContextReader {
            insertionContextAtStop = Task {
                await Self.value(
                    of: Task { @MainActor in await reader.captureInsertionContext() },
                    within: Self.screenContextTimeout, otherwise: nil
                )
            }
        } else {
            insertionContextAtStop = nil
        }
        let language = selectedLanguage == "auto" ? nil : selectedLanguage
        let selectedEngine = ModelSize(rawValue: selectedModelSize)?.engine
        // sherpa-onnx models take no screen terms (only Qwen3-ASR reads the
        // user's own words), so its batch decode starts now instead of after
        // the History write and the screen read.
        let earlyDecode: Task<VocaTranscription, Error>?
        let decodesWholeRecording = session == nil || session?.language != language
        if selectedEngine == .sherpaOnnx, decodesWholeRecording {
            let vocabulary = Self.recognitionVocabulary(
                customVocabulary, replacementTargets: replacementTargets, contextTerms: [], usage: termUsage
            )
            let transcriber = self.transcriber
            let translate = translatesSpeech
            earlyDecode = Task {
                try await transcriber.transcribe(
                    audioData: audioData, language: language, translate: translate, vocabulary: vocabulary
                )
            }
        } else if selectedEngine == .parakeet, decodesWholeRecording {
            // Parakeet reads the screen terms only for its boost after the
            // decode, so the decode starts now too and the terms join it
            // when they arrive.
            let vocabulary = customVocabulary
            let targets = replacementTargets
            let usage = termUsage
            let transcriber = self.transcriber
            let translate = translatesSpeech
            earlyDecode = Task {
                try await transcriber.transcribe(
                    audioData: audioData, language: language, translate: translate,
                    vocabularyAfterDecode: {
                        let contextTerms = await contextTermsRead.value
                        return await Self.recognitionVocabulary(
                            vocabulary, replacementTargets: targets, contextTerms: contextTerms, usage: usage
                        )
                    }
                )
            }
        } else {
            earlyDecode = nil
        }
        defer { earlyDecode?.cancel() }
        // Journaled before transcribing; the audio is written alongside the
        // transcription, so a failure can still be retried from history.
        let historyID = injectResult ? await beginHistoryEntry(audio: audioData) : nil
        activeHistoryEntryID = historyID
        guard generation == recordingGeneration else {
            // Escape arrived while the audio was being saved.
            if let historyID { historyStore.markCancelled(historyID) }
            return
        }

        do {
            let contextTerms = await contextTermsRead.value
            // Words read off the screen stay on this Mac: a remote endpoint
            // gets only the user's own Dictionary.
            let recognitionVocabulary = Self.recognitionVocabulary(
                customVocabulary, replacementTargets: replacementTargets,
                contextTerms: selectedEngine == .customEndpoint ? [] : contextTerms, usage: termUsage
            )
            let result: VocaTranscription
            // A commit-mode session reads the vocabulary per piece, so context
            // terms reach it too, provided no piece was decoded without them.
            liveVocabulary?.update(recognitionVocabulary)
            let pieceVocabularyMatches = liveVocabulary?.servedOnly(recognitionVocabulary) ?? false
            let contextNeedsWhisperBatch = selectedEngine == .whisperKit
                && ((!contextTerms.isEmpty && !pieceVocabularyMatches) || translatesSpeech)
            if let session, session.language == language, !contextNeedsWhisperBatch {
                do {
                    result = try await session.finish(expectedSampleCount: audioData.count)
                } catch RecordingTranscription.StreamError.timedOut {
                    // The engine was given up on; the batch path would wait
                    // on a model that is being dropped.
                    throw RecordingTranscription.StreamError.timedOut
                } catch {
                    guard generation == recordingGeneration else { return }
                    try Task.checkCancellation()
                    PerformanceTrace.event("StreamingBatchFallback")
                    VocaLogger.warning(.appState, "Live transcription unavailable; decoding the complete recording")
                    result = try await transcriber.transcribe(
                        audioData: audioData, language: language,
                        translate: translatesSpeech, vocabulary: recognitionVocabulary
                    )
                }
            } else if let earlyDecode {
                session?.cancel()
                result = try await withTaskCancellationHandler {
                    try await earlyDecode.value
                } onCancel: {
                    earlyDecode.cancel()
                }
            } else {
                session?.cancel()
                result = try await transcriber.transcribe(
                    audioData: audioData, language: language,
                    translate: translatesSpeech, vocabulary: recognitionVocabulary
                )
            }

            guard generation == recordingGeneration else {
                if let historyID { historyStore.markCancelled(historyID) }
                return
            }
            liveTranscript = ""

            // A spoken edit command isn't a dictation: it stays out of the
            // last-dictation card and the dictated-words stats.
            if let target = activeCommandTarget {
                activeCommandTarget = nil
                commandModeSession?.phase = .rewriting
                commandModeSession?.instruction = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                await finishCommandMode(
                    instruction: result.text,
                    language: result.detectedLanguage,
                    audioSeconds: result.audioLengthSeconds,
                    target: target,
                    engine: activeCommandEngine ?? commandModeEngine,
                    generation: generation
                )
                return
            }

            lastTranscription = result
            lastCommandEdit = nil
            // The text there has changed; "shorter still" no longer has
            // anything to refer to.
            lastCommandTarget = nil

            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Set when nothing was heard and no overlay could say so.
            var heardNothing = false
            var heardNothingBecauseQuiet = false
            if !trimmedText.isEmpty {
                let target = frontmostAppResolver.currentFrontmostApp()
                    ?? pendingTargetApp ?? frontmostAppResolver.lastActiveApp()
                let documentURL = await documentURLCheck.value
                let resolved = resolveWritingStyle(
                    for: target, documentURL: documentURL, codingAgentTerminal: await codingAgentRead.value
                )
                // The scratchpad is plain notes: format it with the default
                // style, not whichever app the Settings preview was left on.
                let profile: WritingProfile
                if injectResult {
                    profile = nextWritingProfile ?? resolved.profile
                } else if nonInjectedOutputDestination == .scratchpad {
                    profile = resolveWritingStyle(for: nil).profile
                } else {
                    profile = settingsPreviewProfile
                }
                if injectResult {
                    nextWritingProfile = nil
                    if activeWritingStyle != resolved { activeWritingStyle = resolved }
                }
                let laysOutParagraphs = Self.laysOutParagraphs(enabled: pauseParagraphs, profile: profile)
                let spoken = laysOutParagraphs
                    ? await Self.paragraphsAtPauses(result, audio: audioData)
                    : result.text
                var output = await dictationOutputPipeline.process(
                    spoken, profile: profile, snippetList: snippets,
                    cleanupEnabled: transcriptCleanupEnabled, rewritingEnabled: writingRewriteEnabled,
                    model: selectedCleanupModelKind, customPrompt: effectiveCleanupPrompt,
                    cleanupLevel: transcriptCleanupLevel,
                    language: result.detectedLanguage, autoCapitalize: autoCapitalize,
                    trailingSpace: appendTrailingSpace, preview: !injectResult,
                    dictionary: dictionaryContext(
                        contextTerms: contextTerms, language: DictationOutputPipeline.languagePrior(
                            reported: result.detectedLanguage, spoken: spokenLanguages, text: result.text
                        ), segments: result.segments
                    ),
                    numbers: numberWriting, numberSymbols: numberSymbols, spokenEmoji: spokenEmoji,
                    skipWhenClean: skipCleanDictations, laysOutParagraphs: laysOutParagraphs,
                    spokenLanguages: spokenLanguages,
                    // Cleaning piece by piece only pays off with answers from
                    // while recording; an endpoint would get one call per piece.
                    pieces: speculator == nil ? [] : result.pieces, speculator: speculator
                )
                if injectResult, resolved.codingAgent, profile == resolved.profile {
                    output = DictationOutputResult(
                        original: output.original, text: output.text,
                        summary: "\(Self.codingAgentSummary) · \(output.summary)"
                    )
                }
                // Fit the text to the field: one line, the sentence already
                // there, the draft's register. Prose only; a terminal's
                // buffer or an editor's code is not a sentence to join.
                // The field read again at key-up: the user may have moved to
                // another one while speaking, and then nothing is fitted.
                var leadingSpace = false
                if injectResult, writingStyleEnabled, profile.cleanup != .raw, profile.format.supportsWording,
                   !resolved.codingAgent, let start = await insertionContextRead.value,
                   let stopRead = insertionContextAtStop,
                   let context = InsertionFit.deliveryContext(start: start, now: await stopRead.value) {
                    let fit = InsertionFit.fit(
                        output.text, into: context,
                        capitalizes: Self.capitalizes(profile.rules, autoCapitalize: autoCapitalize),
                        mirrorsRegister: profile.format == .chat || profile.format == .slack,
                        protecting: snippets.map(\.expansion) + vocabularyTerms
                            + wordReplacements.map(\.replacement) + contextTerms
                    )
                    if fit.text != output.text {
                        output = DictationOutputResult(original: output.original, text: fit.text, summary: output.summary)
                    }
                    leadingSpace = fit.leadingSpace
                }
                if !result.pieces.isEmpty {
                    Self.logPieceSummary(
                        result: result, speculator: speculator,
                        stopToResult: ProcessInfo.processInfo.systemUptime - stopStarted
                    )
                }
                guard generation == recordingGeneration, !Task.isCancelled else {
                    if let historyID { historyStore.markCancelled(historyID) }
                    return
                }
                if !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   injectResult || nonInjectedOutputDestination == .settingsTest {
                    onboardingVerification.microphoneWorks = true
                    if recordingVerifiesShortcut, onboardingVerification.mode != nil {
                        onboardingVerification.shortcutDictationWorks = true
                    }
                }
                lastOutput = output
                // The destination is read again at delivery: the user may have
                // switched to an excluded app while this was transcribed.
                var historyID = historyID
                if injectResult {
                    let destination = frontmostAppResolver.currentFrontmostApp()
                        ?? frontmostAppResolver.lastActiveApp() ?? pendingTargetApp
                    if let id = historyID, !historyRecords(destination) {
                        historyStore.delete(id)
                        historyID = nil
                        activeHistoryEntryID = nil
                        VocaLogger.info(.history, "Removed this dictation from History: \(destination?.displayName ?? "the app") is excluded")
                    }
                    // Paused History counts too: resuming it mustn't bring
                    // back an older saved dictation for Paste Last.
                    lastUnsavedDictation = historyID == nil ? output.text : nil
                }
                // Saved after the paste is under way, not before it: the
                // journal write (and every 500th dictation a rewrite of the
                // whole History index) and the stats update are main-thread
                // work the text should not wait for.
                let completedHistoryID = historyID
                func saveResult() {
                    if let completedHistoryID {
                        historyStore.complete(
                            completedHistoryID, rawText: result.text, finalText: output.text, summary: output.summary,
                            language: result.detectedLanguage, transcriptionSeconds: result.duration,
                            segments: result.segments, keepAudio: historyKeepsAudio
                        )
                    }
                    statsManager.recordTranscription(result)
                    stampModelsInUseIfStale()
                    recordTermUsage(in: output.text)
                }
                if injectResult {
                    let current = frontmostAppResolver.currentFrontmostApp()
                        ?? frontmostAppResolver.lastActiveApp() ?? pendingTargetApp
                    guard Self.sameOutputTarget(target, current) else {
                        saveResult()
                        heldOutput = output.text
                        showOverlayFailure("The app changed. Your text is saved in the menu bar.")
                        cursorOverlay.hide()
                        // The held text stays in the menu bar; the error
                        // itself clears so the app doesn't stay in .error.
                        showTemporaryError("The destination app changed. Your dictation is saved in the menu bar; copy it to paste where you want.")
                        return
                    }
                    let delivery = Self.textDelivery(
                        spoken: result.text, text: output.text, app: current,
                        isCodeOrTerminal: Self.isCodeOrTerminal(current, resolved: resolved),
                        method: insertionMethod, typingApps: typedInsertionApps,
                        autoSendMode: autoSendMode, autoSendApps: autoSendApps
                    )
                    if delivery.text != output.text {
                        // "Send it" asked for Return; it isn't part of the text.
                        output = DictationOutputResult(original: output.original, text: delivery.text, summary: output.summary)
                        lastOutput = output
                        // Paste Last prefers the unsaved copy: it must match
                        // what was delivered, without the cue.
                        if lastUnsavedDictation != nil { lastUnsavedDictation = output.text }
                    }
                    let deliveredText = output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "" : (leadingSpace ? " " : "") + output.text
                    textInjector.inject(text: deliveredText, preserveClipboard: preserveClipboard, options: delivery.options)
                    saveResult()
                    if onboardingVerification.mode == .insertion,
                       !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onboardingVerification.insertionAttempted = true
                    }
                    statsManager.recordStopWait(StopWait(
                        seconds: ProcessInfo.processInfo.systemUptime - stopRequested,
                        audioSeconds: result.audioLengthSeconds,
                        processedWhileSpeaking: processedWhileSpeaking
                    ))
                    let dictationLanguage = DictationOutputPipeline.knownLanguage(result.detectedLanguage) ?? spellingLanguage
                    observeCorrections(
                        to: output.text, language: dictationLanguage, historyID: completedHistoryID, app: target
                    )
                    noteScreenRespellings(raw: result.text, final: output.text, screenTerms: contextTerms,
                                          language: dictationLanguage)
                    suggestFrequentNamesIfDue()
                } else {
                    saveResult()
                    if nonInjectedOutputDestination == .scratchpad {
                        if !scratchpadText.isEmpty, !scratchpadText.hasSuffix("\n") { scratchpadText += "\n" }
                        scratchpadText += output.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        settingsTestResultText = output.text

                    }
                }
            } else {
                VocaLogger.info(.appState, "Transcription produced no usable text (silence or blank audio)")
                if let historyID {
                    historyStore.complete(
                        historyID, rawText: result.text, finalText: "", summary: nil,
                        language: result.detectedLanguage, transcriptionSeconds: result.duration,
                        segments: result.segments, keepAudio: historyKeepsAudio
                    )
                }
                // A mic turned too far down is the likeliest cause; say so.
                let tooQuiet = result.inputLevelWarning == .tooQuiet
                if injectResult {
                    heardNothing = !showOverlayFailure(tooQuiet ? "Didn't catch that. Your mic is very quiet." : "Didn't catch that.")
                } else {
                    settingsTestResultText = nil
                }
                if tooQuiet { heardNothingBecauseQuiet = true }
            }

            cursorOverlay.hide()
            appStatus = .idle
            if heardNothing {
                showTemporaryError(heardNothingBecauseQuiet
                    ? "Didn't catch that. Your microphone level is very low; raise its input volume in System Settings → Sound."
                    : "Didn't catch that. Nothing was typed.")
            }
        } catch {
            guard generation == recordingGeneration else {
                if let historyID { historyStore.markCancelled(historyID) }
                return
            }
            resetCommandModeState()
            liveTranscript = ""
            var message = "Transcription failed: \(error.localizedDescription)"
            var overlayMessage = "Transcription failed."
            if let historyID {
                historyStore.markFailed(historyID, message: error.localizedDescription)
                if historyStore.entry(id: historyID)?.hasAudio == true {
                    message += " Your audio is saved — retry it from the menu bar."
                    overlayMessage = "Transcription failed. Retry it from the menu bar."
                }
            }
            showOverlayFailure(overlayMessage)
            cursorOverlay.hide()
            errorMessage = message
            appStatus = .error

            // Auto-recover after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.appStatus == .error {
                    self?.appStatus = .idle
                    self?.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Dictation state

    /// The microphone is on, or a stop hasn't been taken yet. The two can
    /// briefly disagree during recovery, so every start, stop, and cancel
    /// asks this rather than either flag alone.
    var isCapturingAudio: Bool { isRecording || appStatus == .recording }

    /// The dictation flags in one value.
    var dictationFlags: DictationFlags {
        DictationFlags(
            appStatus: appStatus,
            isRecording: isRecording,
            isStartingAudio: isStartingAudio,
            isStoppingAudio: isStoppingAudio,
            isLoadingModel: isLoadingModelForRecording,
            isTranscribing: isTranscribing,
            isTranscribingMedia: isTranscribingMedia,
            hasPendingStopDuringStart: pendingStopDuringStart != nil,
            hasPendingStopDuringModelLoad: pendingStopDuringModelLoad != nil
        )
    }

    var dictationPhase: DictationPhase { dictationFlags.phase }

    private func beginDictationOperation() {
        dictationOperationDepth += 1
    }

    /// Once nothing else is starting, stopping, or cancelling, check that no
    /// flag was left behind. A finding is logged, not repaired: the log line
    /// is what turns a "the hotkey stopped working" report into a fix.
    private func endDictationOperation(_ operation: String) {
        dictationOperationDepth -= 1
        guard dictationOperationDepth == 0 else { return }
        let flags = dictationFlags
        lastDictationStateViolations = flags.violations
        guard !lastDictationStateViolations.isEmpty else { return }
        VocaLogger.warning(
            .appState,
            "Dictation state after \(operation) is inconsistent: "
                + lastDictationStateViolations.joined(separator: "; ") + " [\(flags)]"
        )
    }

    func toggleScratchpadRecording() async {
        if isCapturingAudio {
            await stopRecordingAndTranscribe()
        } else {
            await startRecording(injectResult: false, outputDestination: .scratchpad)
        }
    }

    /// Cancels the active recording without sending its audio to a transcription
    /// engine. This is used by the overlay's cancel button.
    func cancelRecording() async {
        beginDictationOperation()
        defer { endDictationOperation("cancel") }
        guard isCapturingAudio else {
            if isLoadingModelForRecording {
                pendingStopDuringModelLoad = .discard
                cursorOverlay.hide()
            }
            queuedRecordingStart = nil
            // A microphone opened early (model loading, or a queued
            // dictation) closes now, not when the load finishes, which can
            // take minutes with playback muted all the while.
            discardEarlyCapture()
            return
        }

        if isStartingAudio {
            pendingStopDuringStart = .discard
            audioEngine.cancelPendingStart()
            return
        }

        // A stop already waiting on the audio engine (the hotkey released a
        // moment before Escape) must not go on to transcribe and paste.
        recordingGeneration = UUID()
        _ = await stopAudioEngine()
        discardRecordingState()
        appStatus = .idle
        errorMessage = nil
        VocaLogger.info(.appState, "Recording cancelled")
    }

    /// Tear down a recording that ends without a transcript: a cancel, a
    /// failed start, a lost input device, or auto-pause. Every such exit
    /// must also drop a Command Mode session, or the next ordinary dictation
    /// would be taken as an editing command for the stale selection.
    func discardRecordingState() {
        isRecording = false
        transcriber.cancelVoiceActivityStream()
        audioLevel = 0.0
        screenContextTask?.cancel()
        screenContextTask = nil
        screenDocumentURLTask?.cancel()
        screenDocumentURLTask = nil
        insertionContextTask?.cancel()
        insertionContextTask = nil
        codingAgentTask?.cancel()
        codingAgentTask = nil
        resetCommandModeState()
        liveTranscript = ""
        cursorOverlay.hide()
        hotKeyManager.resetKeyState()
    }

    /// Escape: throw away a recording, or drop a dictation still being
    /// transcribed. A dictation cancelled mid-transcription keeps its audio in
    /// history, so an accidental Escape can be undone with Retry.
    func cancelDictation() async {
        beginDictationOperation()
        defer { endDictationOperation("cancel dictation") }
        // The model is still loading, with the microphone already open.
        if isCapturingAudio || isLoadingModelForRecording {
            await cancelRecording()
            return
        }
        guard isTranscribing else {
            // Nothing is running: Escape closes a result waiting on screen.
            dismissCommandReview()
            return
        }
        recordingGeneration = UUID()
        // Escape cancels everything, including a dictation waiting to start.
        queuedRecordingStart = nil
        discardEarlyCapture()
        cancelFinishingWork()
        resetCommandModeState()
        liveTranscript = ""
        isTranscribing = false
        if let id = activeHistoryEntryID {
            historyStore.markCancelled(id)
            activeHistoryEntryID = nil
        }
        cursorOverlay.hide()
        hotKeyManager.resetKeyState()
        appStatus = .idle
        errorMessage = nil
        VocaLogger.info(.appState, "Dictation cancelled while transcribing")
    }

    /// Completes a recording the user ended while the microphone was still
    /// connecting. If the engine never reached the capture stage there is
    /// nothing to transcribe — no audio existed before the route came up — so
    /// say so plainly instead of reporting a mysterious silent recording.
    private func finishStartInterruptedByStop(
        _ kind: PendingStopKind,
        didStartRecording: Bool
    ) async {
        guard didStartRecording else {
            VocaLogger.info(.appState, "Recording ended while the microphone was still connecting")
            isRecording = false
            audioLevel = 0.0
            cursorOverlay.hide()
            hotKeyManager.resetKeyState()

            switch kind {
            case .discard:
                appStatus = .idle
                errorMessage = nil
            case .transcribe:
                showTemporaryError("The microphone was still connecting, so nothing was recorded. Bluetooth headsets need a moment — hold the hotkey until the start sound, then speak.")
            }
            return
        }

        // The route came up just as the user let go; treat it as a normal end.
        switch kind {
        case .transcribe:
            await stopRecordingAndTranscribe()
        case .discard:
            await cancelRecording()
        }
    }

    private func startAudioEngine(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?,
        preferredInputChannel: Int,
        preferredInputChannelDeviceID: String?,
        preferredInputChannelCount: Int
    ) async -> Bool {
        let worker = AudioEngineWorker(audioEngine: audioEngine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let didStart = worker.startRecording(
                    silenceThreshold: silenceThreshold,
                    silenceDuration: silenceDuration,
                    maxDuration: maxDuration,
                    preferredInputDeviceID: preferredInputDeviceID,
                    preferredInputChannel: preferredInputChannel,
                    preferredInputChannelDeviceID: preferredInputChannelDeviceID,
                    preferredInputChannelCount: preferredInputChannelCount
                )
                continuation.resume(returning: didStart)
            }
        }
    }

    /// Start the microphone with the user's audio settings.
    func startConfiguredAudioEngine() async -> Bool {
        let automaticExternal = automaticExternalInputIfNeeded()
        return await startAudioEngine(
            silenceThreshold: Float(silenceThreshold),
            silenceDuration: silenceDuration,
            maxDuration: TimeInterval(maxRecordingDuration),
            preferredInputDeviceID: automaticExternal?.id
                ?? (selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID),
            preferredInputChannel: automaticExternal == nil ? selectedAudioChannel : 0,
            preferredInputChannelDeviceID: automaticExternal?.id
                ?? (selectedAudioChannelDeviceID.isEmpty ? nil : selectedAudioChannelDeviceID),
            preferredInputChannelCount: automaticExternal?.channelCount ?? selectedAudioChannelCount
        )
    }

    /// Open the microphone for a queued push-to-talk dictation now, without
    /// touching the dictation flags: the previous dictation still owns them.
    private func beginEarlyCapture() {
        guard earlyCapture == nil else { return }
        let counter = CapturedSampleCounter(clock: captureClock)
        audioEngine.onAudioSamples = { samples, offset in counter.record(offset + samples.count) }
        let start = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let started = await self.startConfiguredAudioEngine()
            guard started, self.earlyCapture?.counter === counter else { return started }
            counter.markLive()
            // Recording while the model loads: the overlay can say so now.
            if self.isLoadingModelForRecording, self.earlyCapture?.releasedAtSampleCount == nil {
                self.cursorOverlay.transitionToRecording()
            }
            // Live now: silence playback as a dictation start would, so music
            // is not recorded under what the user says while waiting.
            // `discardEarlyCapture` undoes it; an adopted capture's recording
            // undoes it when it ends.
            let mutedOtherAudio = self.duckOtherAudioEnabled && self.audioDucker.duck()
            if self.pauseSpotifyEnabled { self.spotifyPauser.pause() }
            if self.soundEffectsEnabled, !mutedOtherAudio {
                self.soundManager.playStartSound()
            }
            return started
        }
        earlyCapture = EarlyCapture(start: start, counter: counter)
        VocaLogger.info(.appState, "Opened the microphone early for the queued dictation")
    }

    /// Close a microphone opened early for a queued dictation, discarding
    /// what it heard.
    func discardEarlyCapture() {
        guard let early = earlyCapture else { return }
        earlyCapture = nil
        audioEngine.onAudioSamples = nil
        audioEngine.cancelPendingStart()
        Task { @MainActor [weak self] in
            guard await early.start.value, let self, !self.isCapturingAudio else { return }
            _ = await self.stopAudioEngine()
            // Undo the mute and pause applied when the capture went live.
            self.audioDucker.restore()
            self.spotifyPauser.resume()
            VocaLogger.info(.appState, "Closed the microphone opened for a queued dictation")
        }
    }

    /// What receives the microphone's samples while recording: a live
    /// session, the silence detector, both, or neither.
    static func sampleObserver(
        session: RecordingTranscription?, voiceActivity: VoiceActivityStream?
    ) -> (@Sendable ([Float], Int) -> Void)? {
        switch (session, voiceActivity) {
        case (nil, nil):
            return nil
        case let (session?, nil):
            return { samples, offset in session.append(samples, at: offset) }
        case let (nil, voiceActivity?):
            return { samples, offset in voiceActivity.append(samples, at: offset) }
        case let (session?, voiceActivity?):
            return { samples, offset in
                session.append(samples, at: offset)
                voiceActivity.append(samples, at: offset)
            }
        }
    }

    func stopAudioEngine() async -> [Float] {
        let worker = AudioEngineWorker(audioEngine: audioEngine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: worker.stopRecording())
            }
        }
    }
}

// MARK: - Early capture

/// A microphone opened for a queued push-to-talk dictation (see
/// `AppState.earlyCapture`). Only touched on the main actor.
final class EarlyCapture {
    /// Opening the microphone; true once it is live.
    let start: Task<Bool, Never>
    /// How much audio the microphone has delivered.
    let counter: CapturedSampleCounter
    /// Samples captured when the key came up, or nil while it is held.
    var releasedAtSampleCount: Int?

    init(start: Task<Bool, Never>, counter: CapturedSampleCounter) {
        self.start = start
        self.counter = counter
    }
}

/// Counts samples from the audio tap's thread for the main actor.
final class CapturedSampleCounter: Sendable {
    private struct State {
        var count = 0
        /// Uptime of the last delivery.
        var lastDelivery: TimeInterval?
        /// Uptime the microphone went live.
        var liveSince: TimeInterval?
    }

    /// The tap hands over 4096 frames at a time: about 85 ms at 48 kHz, but
    /// 512 ms from an 8 kHz Bluetooth headset. Time past the last delivery
    /// is counted up to this much, so a stalled tap can't stretch a release
    /// boundary into later speech.
    static let maxInFlightSeconds: TimeInterval = 0.6

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let sampleRate: Double
    private let clock: @Sendable () -> TimeInterval

    init(
        sampleRate: Double = 16_000,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sampleRate = sampleRate
        self.clock = clock
    }

    var count: Int { state.withLock { $0.count } }

    func record(_ end: Int) { record(end, at: clock()) }

    func record(_ end: Int, at uptime: TimeInterval) {
        state.withLock {
            $0.count = max($0.count, end)
            $0.lastDelivery = uptime
        }
    }

    /// The microphone went live: from here on audio is being captured, even
    /// before its first buffer arrives.
    func markLive() { markLive(at: clock()) }

    func markLive(at uptime: TimeInterval) {
        state.withLock { if $0.liveSince == nil { $0.liveSince = uptime } }
    }

    /// Samples captured up to `uptime`, including the buffer the tap is
    /// still filling: the delivered count alone cuts off the last syllable,
    /// and a short word on a slow headset can end before the first buffer.
    /// No minimum length: like any recording, a short one is left to the
    /// silence trimming. (The live time is stamped on the main actor, so it
    /// can run late. A minimum would then drop real words.)
    func releaseBoundary() -> Int { releaseBoundary(at: clock()) }

    func releaseBoundary(at uptime: TimeInterval) -> Int {
        state.withLock { state in
            if let lastDelivery = state.lastDelivery {
                let pending = min(max(uptime - lastDelivery, 0), Self.maxInFlightSeconds)
                return state.count + Int((pending * sampleRate).rounded())
            }
            guard let liveSince = state.liveSince else { return state.count }
            let elapsed = min(max(uptime - liveSince, 0), Self.maxInFlightSeconds)
            return Int((elapsed * sampleRate).rounded())
        }
    }
}
