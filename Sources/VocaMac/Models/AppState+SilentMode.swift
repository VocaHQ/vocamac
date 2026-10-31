// AppState+SilentMode.swift
// VocaMac
//
// Silent Mode: dictate in a whisper, or mouth a short command, with the
// camera reading the lips. Its own shortcut (hold it, or press it and press
// again), so the dictation key keeps working as before. The camera is on
// only while a Silent Mode recording runs.

import Foundation

/// What a Silent Mode recording turns into, decided at the stop.
enum SilentOutcome: Equatable {
    /// One short mouthed word that matched a taught command.
    case command(SilentCommand)
    /// Decode these sample ranges: where the lips moved, and anything the camera missed.
    case decode([Range<Int>])
    /// The camera watched still lips throughout; type nothing.
    case nothingSaid
    /// The camera couldn't judge; decode as an ordinary dictation.
    case asUsual
}

/// A silent recording's outcome, and what lip reading should read.
struct SilentDecision: Equatable {
    var outcome: SilentOutcome
    /// Where the lips moved; for lips the movement check found still, where
    /// the face was in view.
    var speaking: [ClosedRange<TimeInterval>]
    /// The movement check found no speech; a lone word read here is likely
    /// the lip reader filling silence.
    var lowMotion = false
}

extension AppState {

    static let silentNothingSaidMessage = "Silent Mode didn't see your lips move, so nothing was typed. Face the camera, or raise Sensitivity in Settings › Silent Mode."

    // MARK: On and off

    /// Silent Mode is on while it has a shortcut, like Command Mode.
    var isSilentModeOn: Bool { shortcut(for: .silentMode) != nil }

    /// Where the switch remembers the keys it turned off.
    static let silentModeLastShortcutKey = "calm.silentMode.lastShortcut"

    /// Turn Silent Mode off (clearing and remembering its shortcut) or on
    /// (restoring the remembered keys, else the suggested ones), asking for
    /// camera access the first time.
    ///
    /// - Returns: False when it couldn't turn on because no keys are free;
    ///   the page then opens the recorder.
    @discardableResult
    func setSilentModeOn(_ isOn: Bool, defaults: UserDefaults = .standard) -> Bool {
        if !isOn {
            if let current = shortcut(for: .silentMode) {
                defaults.set(current.storageString, forKey: Self.silentModeLastShortcutKey)
            }
            setShortcut(nil, for: .silentMode)
            return true
        }
        guard !isSilentModeOn else { return true }
        guard let candidate = silentModeOnCandidate(defaults: defaults) else { return false }
        setShortcut(candidate, for: .silentMode)
        Task { await silentMode.requestPermission() }
        return true
    }

    /// The keys turning Silent Mode on would use: the ones the switch turned
    /// off, while still free, else the suggested ones.
    func silentModeOnCandidate(defaults: UserDefaults = .standard) -> HotKeyCombo? {
        let remembered = defaults.string(forKey: Self.silentModeLastShortcutKey).flatMap(HotKeyCombo.init(storageString:))
        return remembered.flatMap { combo in
            ShortcutValidation.problem(with: combo, action: .silentMode, appState: self) == nil ? combo : nil
        } ?? ShortcutValidation.suggestion(for: .silentMode, appState: self)
    }

    /// The shortcut as menus write it ("⌃⌥⌘S"), or nil while off.
    var silentModeShortcutText: String? {
        shortcut(for: .silentMode).map { CalmKeyCaps.compactText(for: $0) }
    }

    /// Push the Silent Mode settings to the camera side.
    func syncSilentModeSettings() {
        silentMode.sensitivity = ArticulationSensitivity.clamped(silentModeSensitivity)
        silentMode.cameraID = silentModeCameraID.isEmpty ? nil : silentModeCameraID
        silentMode.live.showsVideo = silentModeShowsVideo
        silentMode.stillTimeout = SilenceDetectionSettings.clampedDuration(silenceDuration)
        silentMode.onLipsStill = { [weak self] in
            Task { @MainActor [weak self] in await self?.silentLipsWentStill() }
        }
    }

    // MARK: The shortcut

    /// The Silent Mode shortcut went down: start a silent recording, or end
    /// the one a quick press started.
    func handleSilentModePress() async {
        if isCapturingAudio || isLoadingModelForRecording {
            // Another press while a silent recording runs finishes it. A
            // dictation started some other way is left alone.
            guard isSilentSession || isLoadingModelForRecording else { return }
            silentModePressStartedAt = nil
            await stopRecordingAndTranscribe()
            return
        }
        silentModePressStartedAt = Date()
        isSilentSessionRequested = true
        await startRecording()
        // Queued behind a dictation still finishing carries the request in
        // the queue; anything else that didn't start drops it.
        // The press time stays: letting go then still ends a queued one.
        if !isRecording { isSilentSessionRequested = false }
    }

    /// The Silent Mode shortcut came up. After a hold, the recording is
    /// typed; after a quick press it carries on until the next press.
    func handleSilentModeRelease() async {
        guard let startedAt = silentModePressStartedAt else { return }
        silentModePressStartedAt = nil
        guard Date().timeIntervalSince(startedAt) >= silentModeHoldThreshold else {
            VocaLogger.debug(.silentMode, "Silent Mode quick press — waiting for a second press")
            cursorOverlay.setStopHint(overlayStopHint)
            return
        }
        await stopRecordingAndTranscribe()
    }

    /// The overlay's hint while a silent recording started by its shortcut
    /// runs: let go of it, or press it again.
    var silentStopHint: OverlayStopHint? {
        guard isSilentSession, silentSessionStartedByShortcut, let keys = silentModeShortcutText else { return nil }
        return silentModePressStartedAt != nil ? .hold(key: keys) : .press(key: keys)
    }

    // MARK: Session

    /// At the start of a recording: make it a silent one when the Silent
    /// Mode shortcut asked, or when the dictation key records silently too.
    /// Never for Command Mode, which edits a selection by voice.
    func beginSilentSessionIfWanted(injectResult: Bool) {
        let requested = isSilentSessionRequested
        isSilentSessionRequested = false
        let viaDictationKey = silentModeUsesDictationKey && isSilentModeOn && injectResult
            && [.dictationKey, .mouseButton].contains(dictationTrigger)
        guard requested || viaDictationKey, commandModeSession == nil else { return }
        syncSilentModeSettings()
        silentSessionStartedByShortcut = requested
        silentSessionReadsLips = silentModeReadsLips && lipReader.isInstalled
        isSilentSession = true
        silentMode.beginDictation(readsLips: silentSessionReadsLips)
        if silentSessionReadsLips {
            // Load while the user speaks; the first load takes seconds.
            lipReaderIdleUnload?.cancel()
            let reader = lipReader
            Task.detached(priority: .userInitiated) { await reader.prepare() }
        }
        VocaLogger.info(.silentMode, "Silent Mode recording started (\(requested ? "shortcut" : "dictation key"), \(silentSessionReadsLips ? "reading lips" : "decoding a whisper"))")
    }

    /// Every way a recording ends comes through here (from `isRecording`):
    /// the camera goes off with the microphone.
    func endSilentSession() {
        guard isSilentSession else { return }
        if silentMode.isDictating { _ = silentMode.finishDictationCapture() }
        isSilentSession = false
        silentSessionReadsLips = false
        silentSessionStartedByShortcut = false
        cursorOverlay.setSilentSession(nil)
    }

    /// The lips have been still for the silence timeout in a recording that
    /// doesn't end on a key-up: stop it, as silence stops a toggle dictation.
    func silentLipsWentStill() async {
        guard isSilentSession, isRecording else { return }
        let isToggleLike = silentSessionStartedByShortcut
            ? silentModePressStartedAt == nil
            : activationMode == .doubleTapToggle || isHandsFreeSession
        guard isToggleLike else { return }
        VocaLogger.info(.silentMode, "Lips still — stopping the silent recording")
        await stopRecordingAndTranscribe()
    }

    // MARK: Outcome

    /// Decide what a silent recording becomes, from its lip frames.
    ///
    /// - Parameter readsLips: The recording has crops for the lip reader.
    ///   Subtle mouthing can stay under the movement threshold, so then the
    ///   lip reader reads what the camera saw rather than nothing being typed.
    func silentDecision(frames: [LipFrame], audioEnd: TimeInterval, sampleCount: Int, readsLips: Bool = false) -> SilentDecision {
        let sensitivity = ArticulationSensitivity.clamped(silentModeSensitivity)
        let timeline = ArticulationDetector.timeline(for: frames, sensitivity: sensitivity)
        VocaLogger.info(.silentMode, String(
            format: "Silent recording: %d frames, %.1fs with lips in view, %d stretches of movement; rest %.4f, threshold %.4f, peak %.4f",
            frames.count, timeline.coveredSeconds, timeline.active.count, timeline.floor, timeline.threshold, timeline.peak
        ))

        func decision(_ outcome: SilentOutcome) -> SilentDecision {
            SilentDecision(outcome: outcome, speaking: timeline.speaking)
        }
        if let burst = SilentSpeechGate.commandFrames(frames, timeline: timeline),
           let command = matchSilentCommand(LipSequence.features(burst)) {
            return decision(.command(command))
        }

        switch SilentSpeechGate.decide(timeline: timeline, audioEnd: audioEnd, sampleCount: sampleCount) {
        case .speech(let ranges):
            let kept = ranges.reduce(0) { $0 + $1.count }
            VocaLogger.info(.silentMode, "Decoding \(kept) of \(sampleCount) samples, where the lips moved or the camera couldn't see")
            return decision(.decode(ranges))
        case .noArticulation:
            if readsLips, !timeline.covered.isEmpty {
                VocaLogger.info(.silentMode, "Little lip movement; reading the lips anyway")
                return SilentDecision(outcome: .decode([]), speaking: timeline.covered, lowMotion: true)
            }
            VocaLogger.info(.silentMode, "No lip movement in a recording the camera watched; nothing decoded")
            return decision(.nothingSaid)
        case .notJudged(let reason):
            VocaLogger.info(.silentMode, "Decoding as usual: \(reason)")
            return decision(.asUsual)
        }
    }

    // MARK: Lip reading

    var isLipReadingModelInstalled: Bool { lipReader.isInstalled }

    /// Copy a converted model folder into place.
    func installLipReadingModel(from folder: URL) throws {
        guard let reader = lipReader as? CoreMLLipReader else { throw LipReadingError.notInstalled }
        try reader.install(from: folder)
        objectWillChange.send()
        VocaLogger.info(.silentMode, "Lip-reading model installed from \(folder.lastPathComponent)")
    }

    func removeLipReadingModel() throws {
        try (lipReader as? CoreMLLipReader)?.remove()
        objectWillChange.send()
    }

    /// Extra seconds read before and after each stretch of movement.
    static let lipReadingMargin: TimeInterval = 0.25

    /// How long the lip-reading model stays loaded after its last read.
    static let lipReaderIdleSeconds: UInt64 = 600

    /// The words the lips said in `crops`, read stretch by stretch; nil when
    /// the model couldn't run, empty when it read nothing.
    func readLips(_ crops: [MouthCrop], speaking: [ClosedRange<TimeInterval>]) async -> String? {
        guard let first = crops.first?.time, let last = crops.last?.time, first < last else { return nil }
        let available = first...last
        let started = ProcessInfo.processInfo.systemUptime
        // Loaded first (it usually is, from the start of the recording), so
        // the windows use the lengths this model accepts.
        await lipReader.prepare()
        var texts: [String] = []
        var frames = 0
        for chunk in LipReadingWindow.chunks(speaking) {
            // A little more context either side: a first or last syllable
            // mouthed gently can sit under the movement threshold.
            let lower = max(chunk.lowerBound - Self.lipReadingMargin, available.lowerBound)
            let upper = min(chunk.upperBound + Self.lipReadingMargin, available.upperBound)
            guard lower < upper else { continue }
            let reader = lipReader
            let window = LipReadingWindow.crops(
                at: LipReadingWindow.frameTimes(for: lower...upper, available: available) { reader.modelLength(for: $0) },
                from: crops
            )
            frames += window.count
            do {
                let text = try await lipReader.read(window)
                if !text.isEmpty { texts.append(text) }
            } catch {
                VocaLogger.error(.silentMode, "Lip reading failed: \(error.localizedDescription)")
                return nil
            }
        }
        VocaLogger.info(.silentMode, String(
            format: "Read %d frames of lips in %.2fs: %d words",
            frames, ProcessInfo.processInfo.systemUptime - started, texts.joined(separator: " ").split(separator: " ").count
        ))
        scheduleLipReaderUnload()
        return texts.joined(separator: " ")
    }

    /// Free the lip-reading model once Silent Mode has been idle a while.
    func scheduleLipReaderUnload() {
        lipReaderIdleUnload?.cancel()
        let reader = lipReader
        lipReaderIdleUnload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.lipReaderIdleSeconds * 1_000_000_000)
            guard !Task.isCancelled, self?.isSilentSession == false else { return }
            reader.unload()
        }
    }

    /// The taught command `features` match, when the match is clear.
    func matchSilentCommand(_ features: [[Double]]) -> SilentCommand? {
        let ready = silentCommands.filter(\.isReady)
        guard !features.isEmpty, let matcher = LipCommandMatcher(commands: ready) else { return nil }
        let match = matcher.match(features)
        guard let best = match.best else { return nil }
        let name = ready.first { $0.id == best.commandID }?.action.title ?? "?"
        VocaLogger.info(.silentMode, String(
            format: "Silent command match: %@ at %.3f (limit %.3f), margin %.2f — %@",
            name, best.distance, matcher.maximumDistance, match.margin, match.isAccepted ? "running it" : "not sure, dictating"
        ))
        guard match.isAccepted else { return nil }
        return ready.first { $0.id == best.commandID }
    }

    // MARK: Commands

    /// Show what was recognised, then do it.
    func runSilentCommand(_ command: SilentCommand) async {
        silentMode.live.recognizedCommand = command.action.chip
        cursorOverlay.showDone(message: command.action.chip)
        // Long enough to read before keys are pressed in the document.
        try? await Task.sleep(for: .milliseconds(600))
        await performSilentAction(command.action)
        silentMode.live.recognizedCommand = nil
    }

    func performSilentAction(_ action: SilentCommandAction) async {
        VocaLogger.info(.silentMode, "Silent command: \(action.title)")
        switch action {
        case .pressReturn: keyPresser.press(.returnKey)
        case .newLine: keyPresser.press(.shiftReturn)
        case .undo: keyPresser.press(.undo)
        case .tab: keyPresser.press(.tab)
        case .escape: keyPresser.press(.escape)
        case .deleteWord: keyPresser.press(.optionDelete)
        case .pasteLastDictation: pasteLastDictation()
        case .runShortcut(let name):
            guard let voiceActionPerformer else { return }
            switch VoiceActionPolicy.permitted(.runShortcut(name), allowedShortcuts: allowedVoiceShortcuts) {
            case .failure(let error):
                showOverlayFailure(error.message)
            case .success(let permitted):
                if case .failure(let error) = await voiceActionPerformer.perform(permitted, input: nil) {
                    showOverlayFailure(error.message)
                }
            }
        }
    }

    // MARK: Teaching

    func loadSilentCommands() {
        hasLoadedSilentCommands = false
        silentCommands = silentCommandStore.load()
        hasLoadedSilentCommands = true
    }

    /// The feature take for frames recorded while teaching, or nil when the
    /// lips didn't move in them.
    func silentTake(from frames: [LipFrame]) -> LipTake? {
        let sensitivity = ArticulationSensitivity.clamped(silentModeSensitivity)
        guard let burst = SilentSpeechGate.takeFrames(frames, sensitivity: sensitivity) else { return nil }
        let features = LipSequence.features(burst)
        return features.count >= 4 ? LipTake(frames: features) : nil
    }

    /// Save a taught command: replace the one with `id`, or add a new one.
    func saveSilentCommand(id: UUID?, action: SilentCommandAction, word: String, takes: [LipTake]) {
        let kept = Array(takes.suffix(SilentCommand.maximumTakes))
        var commands = silentCommands
        if let id, let index = commands.firstIndex(where: { $0.id == id }) {
            commands[index].action = action
            commands[index].word = word
            commands[index].takes = kept
        } else {
            commands.append(SilentCommand(action: action, word: word, takes: kept))
        }
        silentCommands = commands
        VocaLogger.info(.silentMode, "Taught a silent command: \(action.title), \(kept.count) takes")
    }

    func deleteSilentCommand(_ id: UUID) {
        silentCommands.removeAll { $0.id == id }
    }

    func deleteAllSilentCommands() {
        silentCommands = []
    }

    /// Actions not yet taught, for the teach dialog.
    var untaughtSilentActions: [SilentCommandAction] {
        let taught = Set(silentCommands.map(\.action))
        let shortcuts = allowedVoiceShortcuts.map(SilentCommandAction.runShortcut)
        return (SilentCommandAction.builtIn + shortcuts).filter { !taught.contains($0) }
    }
}
