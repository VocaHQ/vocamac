// AppState+CommandMode.swift
// VocaMac
//
// Command Mode. Moved out of AppState.swift unchanged.

import Foundation
import SwiftUI
import Combine
import AppKit
import os

extension AppState {

    // MARK: Command Mode

    /// The engine Command Mode will use, after falling back from choices that
    /// can no longer work (an endpoint that was switched off).
    var commandModeEngine: CommandModeEngine {
        get {
            CommandModeEngine.resolve(
                stored: commandModeEngineStorage,
                endpointIsConfigured: !cleanupEndpoint.isLocal && cleanupEndpoint.validationProblem() == nil,
                appleIntelligenceAvailable: appleIntelligenceAvailable()
            )
        }
        set { commandModeEngineStorage = newValue.storageValue }
    }

    /// Why `engine` can't run an edit right now, worded for the error banner.
    func commandModeProblem(for engine: CommandModeEngine) -> String? {
        switch engine {
        case .appleIntelligence:
            guard !appleIntelligenceAvailable() else { return nil }
            return AppleIntelligenceTextService.availabilityProblem()
                ?? "Apple Intelligence is unavailable. Choose another model in Settings → Command Mode."
        case .endpoint:
            if cleanupEndpoint.isLocal {
                return "Command Mode is set to use the cleanup endpoint, but none is configured. Choose a model in Settings → Command Mode."
            }
            return cleanupEndpoint.validationProblem()
        case .local(let kind):
            guard transcriptCleanup.isDownloaded(kind) else {
                return "Download \(kind.descriptor.displayName) in Settings → Command Mode first."
            }
            return nil
        }
    }

    private func commandTransformer(for engine: CommandModeEngine) -> TextTransforming {
        switch engine {
        case .appleIntelligence: return appleIntelligenceService
        case .endpoint: return RemoteCleanupService(configuration: cleanupEndpoint)
        case .local(let kind): return activeCommandService ?? commandModelService(for: kind)
        }
    }

    /// Whether a local Command Mode model gets a llama.cpp slot of its own.
    ///
    /// Cleanup and Command Mode used to share one slot, so two different
    /// models swapped in and out around every edit — seconds each way, and
    /// the cleanup prompt read again afterwards. With memory for both, the
    /// small cleanup model stays resident and the edit model loads beside it.
    func usesSeparateCommandSlot(for kind: CleanupModelKind) -> Bool {
        commandModelSlot != nil && cleanupUsesLocalModel && kind != selectedCleanupModelKind
            && (systemCapabilities?.physicalMemoryGB ?? SystemInfo.physicalMemoryGB) >= CleanupModelCatalog.sharedModelMemoryGB
    }

    private func commandModelService(for kind: CleanupModelKind) -> TranscriptCleaning {
        guard let commandModelSlot, usesSeparateCommandSlot(for: kind) else { return transcriptCleanup }
        return commandModelSlot
    }

    /// Free the second slot when nothing uses it any more: the models were
    /// set to share again, or another engine or model was chosen.
    func syncCommandModelSlot() {
        guard let commandModelSlot, commandModelSlot.isLoaded, activeCommandService == nil else { return }
        if case .local(let kind) = commandModeEngine, usesSeparateCommandSlot(for: kind),
           commandModelSlot.loadedKind == kind {
            return
        }
        commandModelSlot.unload()
    }

    /// End a Command Mode session that produced nothing, saying why on
    /// screen and in the log. Without the log line, a session that ended
    /// without an edit left no trace of the reason.
    private func failCommand(_ message: String, detail: String? = nil, started: Date? = nil) {
        cursorOverlay.hide()
        var line = "Command Mode ended without a result: \(detail ?? message)"
        if let engine = activeCommandEngine { line += " [\(engine.displayName)]" }
        if let started { line += String(format: " after %.2fs", Date().timeIntervalSince(started)) }
        VocaLogger.warning(.appState, line)
        showTemporaryError(message)
    }

    /// Capture what Command Mode will act on, then record the spoken
    /// instruction.
    func beginCommandMode() async {
        // An error banner from the last attempt is not a reason to ignore
        // this one; a dictation can start over it too.
        guard appStatus == .idle || appStatus == .error, !isRecording else { return }
        dismissCommandReview()
        let engine = commandModeEngine
        if let problem = commandModeProblem(for: engine) {
            failCommand(problem)
            return
        }
        guard let target = await captureCommandTarget() else { return }
        if commandModeReleasedBeforeRecording {
            commandModeReleasedBeforeRecording = false
            showTemporaryError(Self.commandReleasedEarlyMessage)
            return
        }
        beginCommandSession(target: target, engine: engine)
        await startRecording(injectResult: false)
        // Released while the speech model was still loading for this session.
        if commandModeReleasedBeforeRecording {
            commandModeReleasedBeforeRecording = false
            if isCapturingAudio { await cancelRecording() }
            resetCommandModeState()
            showTemporaryError(Self.commandReleasedEarlyMessage)
            return
        }
        if !isRecording, activeCommandTarget != nil, !isTranscribing {
            // The microphone never started; nothing will finish this session.
            resetCommandModeState()
        }
    }

    /// Read the selection, or settle for the cursor when nothing is selected.
    /// Nil after reporting why Command Mode can't run here.
    private func captureCommandTarget() async -> CommandTarget? {
        guard let selectedTextService else {
            failCommand(SelectionCaptureFailure.noFocusedApp.message)
            return nil
        }
        switch await selectedTextService.captureSelection() {
        case .success(let captured):
            return captured.isEditable ? .selection(captured) : .readOnly(captured)
        case .failure(.nothingSelected):
            return .cursor(insertionPoint: await selectedTextService.captureInsertionPoint())
        case .failure(let failure):
            failCommand(failure.message, detail: "the selection could not be read (\(failure))")
            return nil
        }
    }

    private func beginCommandSession(target: CommandTarget, engine: CommandModeEngine) {
        activeCommandTarget = target
        activeCommandEngine = engine
        commandTargetApp = frontmostAppResolver.currentFrontmostApp()
        commandModeSession = CommandModeSession(
            kind: target.sessionKind,
            selection: target.selectedText ?? "",
            appName: commandTargetApp?.displayName,
            engineName: engine.displayName
        )
        let what: String
        switch target {
        case .selection(let snapshot):
            what = "a \(snapshot.text.count)-character selection" + (snapshot.source == .clipboard ? " via the clipboard" : "")
        case .readOnly(let snapshot):
            what = "a \(snapshot.text.count)-character read-only selection"
        case .cursor:
            what = "no selection"
        }
        VocaLogger.info(.appState, "Command Mode captured \(what)")
        // Load a local model while the user speaks, so its load time isn't
        // added to the wait after they stop.
        commandModelIdleUnload?.cancel()
        if case .local(let kind) = engine {
            let service = commandModelService(for: kind)
            activeCommandService = service
            commandModelWarmup = Task { await service.load(kind) }
        }
    }

    /// Run `instruction` on the current selection without recording anything:
    /// a saved command's shortcut, or the Shortcuts action.
    func runCommand(instruction: String) async {
        guard appStatus == .idle || appStatus == .error, !isRecording, !isTranscribing else { return }
        dismissCommandReview()
        let engine = commandModeEngine
        if let problem = commandModeProblem(for: engine) {
            failCommand(problem)
            return
        }
        guard let target = await captureCommandTarget() else { return }
        recordingGeneration = UUID()
        let generation = recordingGeneration
        beginCommandSession(target: target, engine: engine)
        activeCommandTarget = nil
        commandModeSession?.phase = .rewriting
        commandModeSession?.instruction = instruction
        if showCursorIndicator && overlayStyle != .off {
            cursorOverlay.show(style: overlayStyle, position: overlayPosition)
            cursorOverlay.setCommandSession(commandModeSession)
            cursorOverlay.transitionToProcessing()
        }
        appStatus = .processing
        isTranscribing = true
        defer {
            if generation == recordingGeneration {
                isTranscribing = false
                if appStatus == .processing { appStatus = .idle }
            }
        }
        await finishCommandMode(
            instruction: instruction, language: nil, audioSeconds: 0,
            target: target, engine: engine, generation: generation
        )
    }

    /// One Command Mode request, from the instruction to where its result goes.
    private struct CommandRun {
        var instruction: String
        var target: CommandTarget
        let engine: CommandModeEngine
        let generation: UUID
        let language: String?
        let audioSeconds: Double
        let started: Date
    }

    /// An edit that is ready, and everything needed to apply and record it.
    struct PendingCommandEdit {
        let snapshot: SelectedTextSnapshot
        let replacement: String
        let instruction: String
        let engineName: String
        let summary: String
        let note: String?
        let app: RunningAppSnapshot?
        let language: String?
        let audioSeconds: Double
    }

    func finishCommandMode(
        instruction: String,
        language: String?,
        audioSeconds: Double,
        target: CommandTarget,
        engine: CommandModeEngine,
        generation: UUID
    ) async {
        defer {
            commandModeSession = nil
            finishCommandModelUse(engine)
        }
        var instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        // "um, make this shorter" — the model doesn't need the hesitation, and
        // History and the Last Edit card shouldn't show it.
        if DictationOutputPipeline.knownLanguage(language).map(DictationOutputPipeline.isEnglish)
            ?? RewriteValidation.likelyEnglish(instruction) {
            instruction = WritingStyleEngine.removeHesitations(instruction).text
        }
        guard !instruction.isEmpty else {
            failCommand("No editing command was detected. Your selection was not changed.", detail: "no instruction was heard")
            return
        }
        // The user's own spellings: "address it to Kanishk" should not go to
        // the model as "Kanishka".
        let dictionary = dictionaryContext(contextTerms: [], language: language)
        if !dictionary.isEmpty {
            instruction = DictionaryCorrector.correct(instruction, context: dictionary, allowIdentifierJoins: false).text
        }
        // A saved command, said by name.
        if let saved = SavedCommandStore.command(named: instruction, in: savedCommands) {
            instruction = saved.instruction
        }
        commandModeSession?.instruction = instruction
        await performCommand(CommandRun(
            instruction: instruction, target: target, engine: engine, generation: generation,
            language: language, audioSeconds: audioSeconds, started: Date()
        ))
    }

    /// Decide what the instruction asks for and do it: take back the last
    /// edit, act on the Mac, apply a rule, or ask the model.
    private func performCommand(_ run: CommandRun) async {
        var run = run
        let instruction = run.instruction

        if CommandInstruction.isUndo(instruction) {
            await undoLastCommandEdit(run)
            return
        }
        // Only the user's own words choose an action. The selection is, at
        // most, what the action is given to work on.
        if voiceActionsEnabled, voiceActionPerformer != nil,
           let action = VoiceActionParser.parse(instruction, selection: run.target.selectedText) {
            await performVoiceAction(action, run: run)
            return
        }

        let intent = CommandInstruction.intent(for: instruction)
        if case .cursor = run.target,
           intent.editsExistingText || CommandExactEdit.isExactEdit(instruction),
           !CommandInstruction.asksForNewText(instruction) {
            // "shorter still", "now make it formal": the text meant is the
            // one the last edit left behind.
            guard let reselected = await reselectLastCommandEdit() else {
                failCommand(SelectionCaptureFailure.nothingSelected.message, detail: "nothing was selected and there was no recent edit to continue", started: run.started)
                return
            }
            run.target = .selection(reselected)
        }

        switch run.target {
        case .selection(let snapshot):
            if let exact = CommandExactEdit.apply(instruction: instruction, to: snapshot.text, keeping: establishedSpellings) {
                guard exact.text != snapshot.text else {
                    failCommand("Command Mode did not change the text: it is already that way.", detail: "\(exact.name) changed nothing", started: run.started)
                    return
                }
                VocaLogger.info(.appState, "Command Mode applied a rule edit (\(exact.name)) without the model")
                await deliverEdit(PendingCommandEdit(
                    snapshot: snapshot, replacement: exact.text, instruction: instruction,
                    engineName: "VocaMac", summary: "Command Mode · \(exact.name)", note: nil,
                    app: commandTargetApp, language: run.language, audioSeconds: run.audioSeconds
                ), run: run, reviews: false)
                return
            }
            guard let result = await runCommandModel(text: snapshot.text, intent: intent, mode: .replace, run: run) else { return }
            await deliverEdit(PendingCommandEdit(
                snapshot: snapshot,
                replacement: TranscriptCleanup.preservingOuterWhitespace(of: snapshot.text, in: result.output),
                instruction: instruction, engineName: run.engine.displayName,
                summary: "Command Mode · \(run.engine.displayName)", note: result.problem?.message,
                app: commandTargetApp, language: run.language, audioSeconds: run.audioSeconds
            ), run: run, reviews: commandModeReview.reviews(selection: snapshot.text))
        case .readOnly(let snapshot):
            // A rule edit of text that can't be replaced is still exact, and
            // still needs no model: show it to copy.
            if let exact = CommandExactEdit.apply(instruction: instruction, to: snapshot.text, keeping: establishedSpellings) {
                deliverAnswer(exact.text, about: snapshot.text, note: nil, run: run, engineName: "VocaMac")
                return
            }
            guard let result = await runCommandModel(text: snapshot.text, intent: intent, mode: .answer, run: run) else { return }
            deliverAnswer(result.output, about: snapshot.text, note: result.problem?.message, run: run)
        case .cursor(let insertionPoint):
            guard let result = await runCommandModel(text: instruction, intent: intent, mode: .compose, run: run) else { return }
            await deliverComposedText(result.output, at: insertionPoint, note: result.problem?.message, run: run)
        }
    }

    // MARK: Command Mode: the model

    /// Spellings the user has settled on, which a rule edit must not undo.
    private var establishedSpellings: [String] {
        vocabularyTerms + wordReplacements.map(\.replacement)
    }

    /// What the session can tell the model about where the text lives.
    private func commandContext(instruction: String, text: String) -> CommandContext {
        let haystack = (instruction + "\n" + text).lowercased()
        let terms = (vocabularyTerms + wordReplacements.map(\.replacement))
            .filter { $0.count >= 3 && haystack.contains($0.lowercased()) }
        var seen = Set<String>()
        return CommandContext(
            appName: commandTargetApp?.displayName,
            style: writingStyleEnabled ? resolveWritingStyle(for: commandTargetApp).profile.format : nil,
            terms: terms.filter { seen.insert($0.lowercased()).inserted }
        )
    }

    /// Ask the model, check what it wrote, and ask once more when the answer
    /// is plainly not what was asked for. Nil after reporting a failure, or
    /// when the session was cancelled.
    private func runCommandModel(
        text: String, intent: CommandIntent, mode: CommandMode, run: CommandRun
    ) async -> (output: String, problem: CommandOutputProblem?)? {
        let engine = run.engine, generation = run.generation
        if case .local(let kind) = engine {
            await commandModelWarmup?.value
            commandModelWarmup = nil
            guard generation == recordingGeneration else { return nil }
            var service = activeCommandService ?? commandModelService(for: kind)
            // Joins or no-ops when the warm-up already loaded it.
            await service.load(kind)
            if service.loadedKind != kind, service !== transcriptCleanup {
                // No room for a second model after all: borrow cleanup's
                // slot, as a Mac with less memory does.
                VocaLogger.info(.appState, "Command Mode is borrowing the cleanup model's slot for \(kind.descriptor.displayName)")
                service = transcriptCleanup
                activeCommandService = service
                await service.load(kind)
            }
            // Check the kind, not just "something is loaded": a load refused
            // before it starts leaves the cleanup model resident, and a 0.5B
            // cleanup model must not be handed an editing command.
            guard service.loadedKind == kind else {
                let detail: String
                if case .error(let message) = service.modelState { detail = message }
                else { detail = "\(kind.descriptor.displayName) could not be loaded." }
                failCommand("Command Mode did not change the text: \(detail)", detail: "the model could not be loaded — \(detail)", started: run.started)
                return nil
            }
        }
        guard generation == recordingGeneration else { return nil }

        let context = commandContext(instruction: run.instruction, text: mode == .compose ? "" : text)
        let transformer = commandTransformer(for: engine)
        var options = TransformOptions(allowsSplitting: mode == .replace && intent.appliesPerPart)
        options.onPartial = { [weak self] partial in
            guard let self, generation == self.recordingGeneration else { return }
            self.commandModeSession?.preview = partial
        }
        activeCommandTransformer = transformer
        let result = await CommandModelRunner.run(
            text: text, instruction: run.instruction, intent: intent, mode: mode, context: context,
            transformer: transformer, options: options,
            // Escape while the model was running: the user no longer wants
            // this edit, even if the model finished anyway.
            isCurrent: { generation == self.recordingGeneration },
            willAsk: { retryReason in
                self.commandModeSession?.preview = nil
                if let retryReason {
                    VocaLogger.info(.appState, "Command Mode is asking again: \(retryReason)")
                }
            }
        )
        activeCommandTransformer = nil
        switch result {
        case .success(let answer):
            // A model that only Command Mode uses is in use only here.
            if case .local(let kind) = engine { modelUsageLog.markUsed([.writing(kind)]) }
            return (answer.output, answer.problem)
        case .failure(.cancelled):
            VocaLogger.info(.appState, "Command Mode cancelled; selection left unchanged")
            return nil
        case .failure(.failed(let why)):
            failCommand("Command Mode did not change the text: \(why).", started: run.started)
            return nil
        }
    }

    // MARK: Command Mode: results

    /// Replace the selection with an edit, or hold it for approval first.
    private func deliverEdit(_ edit: PendingCommandEdit, run: CommandRun, reviews: Bool) async {
        if reviews {
            pendingReviewEdit = edit
            presentCommandReview(CommandReview(
                kind: .edit, instruction: edit.instruction, original: edit.snapshot.text,
                result: edit.replacement, engineName: edit.engineName, note: edit.note,
                acceptShortcut: shortcut(for: .commandMode).map { KeyCodeReference.displayName(for: $0) }
            ))
            VocaLogger.info(.appState, String(
                format: "Command Mode is holding a %d-character edit for review after %.2fs",
                edit.replacement.count, Date().timeIntervalSince(run.started)
            ))
            cursorOverlay.hide()
            appStatus = .idle
            errorMessage = nil
            return
        }
        guard await applyEdit(edit) else {
            failCommand("Command Mode did not change the text: the selection changed or its app is no longer in front.", detail: "the selection changed or its app is no longer in front", started: run.started)
            return
        }
        VocaLogger.info(.appState, String(
            format: "Command Mode queued a %d-character replacement after %.2fs",
            edit.replacement.count, Date().timeIntervalSince(run.started)
        ))
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    /// Put an edit into the document and remember it.
    private func applyEdit(_ edit: PendingCommandEdit) async -> Bool {
        guard let selectedTextService,
              await selectedTextService.replaceSelection(edit.snapshot, with: edit.replacement) else { return false }
        lastCommandEdit = CommandModeEdit(
            instruction: edit.instruction, original: edit.snapshot.text, replacement: edit.replacement,
            engineName: edit.engineName, kind: .edit, note: edit.note
        )
        lastCommandTarget = (edit.snapshot, edit.snapshot.text, edit.replacement, Date())
        recordCommandHistory(
            instruction: edit.instruction, original: edit.snapshot.text, replacement: edit.replacement,
            summary: edit.summary, app: edit.app, language: edit.language, audioSeconds: edit.audioSeconds
        )
        return true
    }

    /// Show an answer about text that can't be replaced.
    private func deliverAnswer(
        _ answer: String, about original: String, note: String?, run: CommandRun, engineName: String? = nil
    ) {
        let engineName = engineName ?? run.engine.displayName
        lastCommandEdit = CommandModeEdit(
            instruction: run.instruction, original: original, replacement: answer,
            engineName: engineName, kind: .answer, note: note
        )
        recordCommandHistory(
            instruction: run.instruction, original: original, replacement: answer,
            summary: "Command Mode · \(engineName) · answer", app: commandTargetApp,
            language: run.language, audioSeconds: run.audioSeconds
        )
        presentCommandReview(CommandReview(
            kind: .answer, instruction: run.instruction, original: original,
            result: answer, engineName: engineName, note: note
        ))
        VocaLogger.info(.appState, String(
            format: "Command Mode answered about read-only text (%d characters) after %.2fs",
            answer.count, Date().timeIntervalSince(run.started)
        ))
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    /// Type new text where the cursor was when the session began.
    ///
    /// The model ran for seconds, and typing goes to whatever has focus now.
    /// The same app in front is not enough: the cursor may have moved to
    /// another field of it, one that sends what is typed. So where the app
    /// reported its cursor at the start, it has to report the same field,
    /// position, and text now, or the result is kept in the menu bar instead.
    /// An app that reports no cursor gets the check a dictation gets: the
    /// same app must still be in front.
    private func deliverComposedText(_ text: String, at insertionPoint: InsertionPoint?, note: String?, run: CommandRun) async {
        let current = frontmostAppResolver.currentFrontmostApp() ?? frontmostAppResolver.lastActiveApp()
        guard Self.sameOutputTarget(commandTargetApp, current) else {
            heldOutput = text
            failCommand("The destination app changed. The text is saved in the menu bar; copy it to paste where you want.", detail: "the app changed before the text could be typed", started: run.started)
            return
        }
        if let insertionPoint {
            let now = await selectedTextService?.captureInsertionPoint()
            guard run.generation == recordingGeneration else { return }
            guard insertionPoint.matches(now) else {
                heldOutput = text
                failCommand("The cursor moved while the text was being written. It is saved in the menu bar; copy it to paste where you want.", detail: "the cursor moved before the text could be typed", started: run.started)
                return
            }
        }
        textInjector.inject(text: text, preserveClipboard: preserveClipboard)
        let engineName = run.engine.displayName
        lastCommandEdit = CommandModeEdit(
            instruction: run.instruction, original: "", replacement: text,
            engineName: engineName, kind: .composed, note: note
        )
        // Where it landed, so "make it shorter" can pick it up.
        lastCommandTarget = insertionPoint.map { ($0.snapshot, "", text, Date()) }
        recordCommandHistory(
            instruction: run.instruction, original: "", replacement: text,
            summary: "Command Mode · \(engineName) · new text", app: commandTargetApp,
            language: run.language, audioSeconds: run.audioSeconds
        )
        VocaLogger.info(.appState, String(
            format: "Command Mode typed %d new characters after %.2fs",
            text.count, Date().timeIntervalSince(run.started)
        ))
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    private func recordCommandHistory(
        instruction: String, original: String, replacement: String, summary: String,
        app: RunningAppSnapshot?, language: String?, audioSeconds: Double
    ) {
        guard historyRecords(app) else { return }
        // Same retention as dictations, applied now rather than at the next
        // dictation, so a run of edits can't outlive the setting.
        defer { historyStore.applyRetention(historyRetention) }
        historyStore.recordCommandEdit(
            instruction: instruction, original: original, replacement: replacement,
            summary: summary, target: app, modelID: selectedModelSize,
            language: language, audioSeconds: audioSeconds
        )
    }

    // MARK: Command Mode: follow-ups and undo

    /// The last edit, selected again, when it is recent and still there.
    private func reselectLastCommandEdit() async -> SelectedTextSnapshot? {
        guard let last = lastCommandTarget, let selectedTextService,
              Date().timeIntervalSince(last.at) <= Self.commandFollowUpWindow else { return nil }
        return await selectedTextService.reselect(last.snapshot, replacement: last.replacement)
    }

    /// "Undo that": put back what the last edit replaced.
    ///
    /// Not the app's own Undo. That takes back whatever the app did last, and
    /// once the user has typed anything since, that is their typing and not
    /// the edit. Instead the result is selected again where it was put, which
    /// only succeeds if it is still there unchanged, and the original is
    /// written over it. Where the app won't let text be selected that way,
    /// nothing is touched and the user is pointed at ⌘Z.
    private func undoLastCommandEdit(_ run: CommandRun) async {
        guard let last = lastCommandTarget, let selectedTextService else {
            failCommand("There's no Command Mode edit to undo here.", detail: "undo was asked for with no edit to undo", started: run.started)
            return
        }
        guard let reselected = await selectedTextService.reselect(last.snapshot, replacement: last.replacement) else {
            failCommand("VocaMac can't take that edit back here: the text has changed since, or this app doesn't let it be selected. Press ⌘Z in the app instead.", detail: "the last edit could not be selected again to undo it", started: run.started)
            return
        }
        // Text that was written, not replaced, has nothing to put back.
        let undone = last.original.isEmpty
            ? await selectedTextService.deleteSelection(reselected)
            : await selectedTextService.replaceSelection(reselected, with: last.original)
        guard undone else {
            failCommand("VocaMac couldn't take that edit back: the selection changed. Press ⌘Z in the app instead.", detail: "the reselected edit changed before it could be undone", started: run.started)
            return
        }
        lastCommandTarget = nil
        lastCommandEdit = nil
        VocaLogger.info(.appState, "Command Mode undid the last edit")
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    // MARK: Command Mode: actions

    /// Shortcuts a spoken instruction may run, as the user listed them.
    var allowedVoiceShortcuts: [String] {
        SavedCommandStore.shortcutNames(from: voiceActionShortcuts)
    }

    private func performVoiceAction(_ action: VoiceAction, run: CommandRun) async {
        guard let voiceActionPerformer else { return }
        let permitted: VoiceAction
        switch VoiceActionPolicy.permitted(action, allowedShortcuts: allowedVoiceShortcuts) {
        case .success(let allowed): permitted = allowed
        case .failure(let error):
            failCommand(error.message, detail: "\(action.summary) was not allowed", started: run.started)
            return
        }
        // A shortcut gets the selection as its input; nothing else does.
        var input: String?
        if case .runShortcut = permitted { input = run.target.selectedText }
        switch await voiceActionPerformer.perform(permitted, input: input) {
        case .failure(let error):
            failCommand(error.message, detail: "\(permitted.summary) failed — \(error.message)", started: run.started)
        case .success:
            lastCommandEdit = CommandModeEdit(
                instruction: run.instruction, original: "", replacement: permitted.summary,
                engineName: "VocaMac", kind: .action
            )
            recordCommandHistory(
                instruction: run.instruction, original: "", replacement: permitted.summary,
                summary: "Command Mode · action", app: commandTargetApp,
                language: run.language, audioSeconds: run.audioSeconds
            )
            VocaLogger.info(.appState, "Command Mode action: \(permitted.summary)")
            cursorOverlay.hide()
            appStatus = .idle
            errorMessage = nil
        }
    }

    // MARK: Command Mode: review

    private func presentCommandReview(_ review: CommandReview) {
        commandReview = review
        refreshCancelKeyArming()
        commandReviewPresenter?.show(
            review,
            onAccept: { [weak self] in Task { @MainActor in await self?.acceptCommandReview() } },
            onCopy: { [weak self] in self?.copyCommandReview() },
            onDismiss: { [weak self] in self?.dismissCommandReview() }
        )
    }

    /// Apply the edit being reviewed.
    func acceptCommandReview() async {
        guard let edit = pendingReviewEdit else {
            dismissCommandReview()
            return
        }
        dismissCommandReview()
        guard await applyEdit(edit) else {
            failCommand("Command Mode did not change the text: the selection changed or its app is no longer in front.", detail: "a reviewed edit could not be applied: the selection changed")
            return
        }
        VocaLogger.info(.appState, "Command Mode applied a reviewed \(edit.replacement.count)-character edit")
    }

    func copyCommandReview() {
        guard let review = commandReview else { return }
        copyToClipboard(review.result)
        // An answer has nothing else to do; an edit stays up to be approved.
        if review.kind == .answer { dismissCommandReview() }
    }

    func dismissCommandReview() {
        guard commandReview != nil || pendingReviewEdit != nil else { return }
        commandReview = nil
        pendingReviewEdit = nil
        commandReviewPresenter?.hide()
        refreshCancelKeyArming()
    }

    // MARK: Command Mode: saved commands

    var savedCommands: [SavedCommand] {
        get { SavedCommandStore.decode(savedCommandsJSON) }
        set {
            savedCommandsJSON = SavedCommandStore.encode(newValue)
            syncShortcutConfiguration()
        }
    }

    /// Run a saved command on the current selection.
    func runSavedCommand(_ id: UUID) async {
        guard isCommandModeOn,
              let command = savedCommands.first(where: { $0.id == id }), command.isUsable else { return }
        await runCommand(instruction: command.instruction)
    }

    // MARK: Command Mode: model slots

    /// Drop a Command Mode session that ended without an edit: stop its
    /// model, and hand the llama.cpp slot back to cleanup.
    func resetCommandModeState() {
        activeCommandTarget = nil
        commandModeSession = nil
        commandModePressStartedAt = nil
        activeCommandTransformer?.cancelTransform()
        activeCommandTransformer = nil
        if let engine = activeCommandEngine { finishCommandModelUse(engine) }
    }

    /// Give the cleanup model back after a Command Mode model borrowed the
    /// shared llama.cpp slot, or free a large model that nothing else needs.
    private func finishCommandModelUse(_ engine: CommandModeEngine) {
        let service = activeCommandService
        activeCommandEngine = nil
        activeCommandService = nil
        guard case .local(let kind) = engine else { return }
        commandModelIdleUnload?.cancel()
        let usedOwnSlot = commandModelSlot != nil && service === commandModelSlot
        if cleanupUsesLocalModel, !usedOwnSlot {
            if kind != selectedCleanupModelKind {
                // The next dictation needs its cleanup model resident.
                Task { await releaseCommandModelSlot() }
            } else {
                // One model does both. The edit left its own prompt in the
                // model, so the next dictation would read cleanup's again
                // from the top; read it now instead.
                Task { await warmCleanupModel() }
            }
            return
        }
        // Nothing else needs the slot. Keep the model resident unless the
        // user asked for idle unloading: a fixed timer here dropped it behind
        // their back, and the reload could then be refused for memory.
        guard let delay = commandModelIdleUnloadDelay else { return }
        commandModelIdleUnload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.commandModelIdleUnloadIsDue else { return }
            if usedOwnSlot {
                self.commandModelSlot?.unload()
            } else {
                await self.releaseCommandModelSlot()
            }
        }
    }

    /// Checked again when the timer fires, as `ModelKeepAlive` does: the user
    /// may have turned idle unloading off, or started another edit, since.
    var commandModelIdleUnloadIsDue: Bool {
        commandModelIdleUnloadDelay != nil && activeCommandEngine == nil
    }

    /// How long a Command Mode model stays loaded after its last use, or nil
    /// to keep it loaded. Follows the "Unload model when idle" setting.
    var commandModelIdleUnloadDelay: TimeInterval? {
        guard modelKeepAliveEnabled else { return nil }
        return ModelKeepAlive.clampIdleTimeout(modelKeepAliveIdleTimeoutSeconds)
    }

    var cleanupUsesLocalModel: Bool {
        transcriptCleanupEnabled && cleanupEndpoint.isLocal
            && transcriptCleanup.isDownloaded(selectedCleanupModelKind)
    }

    /// Put the cleanup model back in the shared slot, or empty it.
    private func releaseCommandModelSlot() async {
        if cleanupUsesLocalModel {
            await transcriptCleanup.load(selectedCleanupModelKind)
            await warmCleanupModel()
        } else if transcriptCleanup.isLoaded {
            transcriptCleanup.unload()
        }
    }
}
