// WordTeachingSession.swift
// VocaMac
//
// One “Say it” dialog: up to `WordTeaching.maximumTakes` takes of a word,
// each ended by Done or after `takeSeconds`, and what they were heard as.
// The dialog only draws this, so the take flow is tested without a view.

import Foundation

@MainActor
final class WordTeachingSession: ObservableObject {
    enum Phase: Equatable {
        case ready
        case listening
        case decoding
    }

    let term: String

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var takes = 0
    @Published private(set) var transcripts: [String] = []
    /// Spoken forms chosen to save.
    @Published var selected: Set<String> = []
    @Published private(set) var notice: String?

    private weak var appState: AppState?
    private let takeSeconds: TimeInterval
    /// Forms already offered, so a choice the user changed stays changed.
    private var offered: Set<String> = []
    private var autoStop: Task<Void, Never>?

    init(term: String, appState: AppState, takeSeconds: TimeInterval = WordTeaching.takeSeconds) {
        self.term = term
        self.appState = appState
        self.takeSeconds = takeSeconds
    }

    var heard: [WordTeaching.Heard] {
        guard let appState else { return [] }
        return WordTeaching.review(
            term: term, transcripts: transcripts, replacements: appState.wordReplacements,
            isKnownWord: { appState.isKnownWord($0, appState.spellingLanguage) }
        )
    }

    var chosenForms: [String] {
        heard.filter { $0.isLearnable && selected.contains($0.form) }.map(\.form)
    }

    var canStartTake: Bool {
        phase == .ready && takes < WordTeaching.maximumTakes && appState?.canTeachWord == true
    }

    var canSave: Bool { phase == .ready && !chosenForms.isEmpty }

    func toggle(_ form: String) {
        if selected.contains(form) {
            selected.remove(form)
        } else {
            selected.insert(form)
        }
    }

    /// Open the microphone for the next take; it ends on `finishTake` or
    /// after `takeSeconds`.
    func startTake() async {
        guard canStartTake, let appState else { return }
        notice = nil
        phase = .listening
        guard await appState.startTeachingTake() else {
            // Cancelled while opening, or the microphone wouldn't open.
            if phase == .listening {
                phase = .ready
                notice = "The microphone isn’t free right now. Try again in a moment."
            }
            return
        }
        guard phase == .listening else { return }
        let seconds = takeSeconds
        autoStop = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            // Finishing cancels this timer, so the decode runs in its own
            // task; in this one it would be cancelled before it started.
            Task { @MainActor [weak self] in await self?.finishTake() }
        }
    }

    /// End the take and add what it was heard as.
    func finishTake() async {
        guard phase == .listening, let appState else { return }
        autoStop?.cancel()
        autoStop = nil
        phase = .decoding
        let text = await appState.finishTeachingTake()
        phase = .ready
        takes += 1
        guard let text else {
            notice = "The speech model couldn’t run. Check Settings › Models."
            return
        }
        guard !WordTeaching.spokenForm(of: text).isEmpty else {
            notice = "Nothing was heard. Say it again, a little closer to the microphone."
            return
        }
        transcripts.append(text)
        // New ways of hearing it start chosen.
        for item in heard where item.isLearnable && offered.insert(item.form).inserted {
            selected.insert(item.form)
        }
    }

    /// Close the microphone without decoding (Cancel, or the dialog closed).
    func cancel() async {
        autoStop?.cancel()
        autoStop = nil
        guard phase == .listening else { return }
        phase = .ready
        await appState?.cancelTeachingTake()
    }

    func save() {
        appState?.teachWord(term, heardForms: chosenForms)
    }
}
