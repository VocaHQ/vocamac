// CorrectionObserver.swift
// VocaMac
//
// Watches for the user fixing a word VocaMac just typed. It reads the field
// once just after the dictation lands and once more when the user starts
// the next dictation or 20 seconds pass, whichever comes first. Two one-shot
// reads, never polling. The second reading also says what became of the
// dictation as a whole (`DictationEditObservation`).

import AppKit
import Foundation

@MainActor
protocol CorrectionObserving: AnyObject {
    /// Called on the main actor with any corrections found.
    var onCorrections: (([CorrectionLearner.Correction]) -> Void)? { get set }
    /// Called on the main actor with each dictation read back, edited or not,
    /// before `onCorrections`.
    var onEdit: ((DictationEditObservation) -> Void)? { get set }
    /// Start watching the field `text` was just typed into.
    /// - Parameters:
    ///   - language: The dictation's language, stamped on each correction
    ///     found in it.
    ///   - historyID: The dictation's History entry, passed back in `onEdit`.
    ///   - app: The app it was typed into, passed back in `onEdit`.
    func observe(
        insertedText text: String, processID: pid_t, language: String?,
        historyID: UUID?, app: RunningAppSnapshot?,
        isKnownWord: @escaping @MainActor @Sendable (String) -> Bool
    )
    /// Compare now instead of waiting for the timer.
    func flush()
    func cancel()
}

@MainActor
final class CorrectionObserver: CorrectionObserving {

    /// Time for the paste to land before the first read.
    static let baselineDelay: TimeInterval = 0.8
    /// Longest wait before comparing, when the user doesn't dictate again.
    static let comparisonDelay: TimeInterval = 20

    var onCorrections: (([CorrectionLearner.Correction]) -> Void)?
    var onEdit: ((DictationEditObservation) -> Void)?

    /// Its own queue, not `AccessibilityTextReader.queue`: reading a long
    /// field back (up to 50,000 characters) happens as the next dictation
    /// starts, and on the shared queue it used up the screen-context read's
    /// 300 ms budget before that read could begin.
    private static let queue = DispatchQueue(label: "com.vocamac.correction-observer", qos: .utility)

    private struct Observation {
        let id: UUID
        let text: String
        let processID: pid_t
        let language: String?
        let historyID: UUID?
        let app: RunningAppSnapshot?
        /// Main actor: spell checking goes through NSSpellChecker.
        let isKnownWord: @MainActor @Sendable (String) -> Bool
        var baseline: FocusedTextSnapshot?
    }

    private var observation: Observation?
    private var comparisonWork: DispatchWorkItem?

    func observe(
        insertedText text: String, processID: pid_t, language: String?,
        historyID: UUID?, app: RunningAppSnapshot?,
        isKnownWord: @escaping @MainActor @Sendable (String) -> Bool
    ) {
        flush()
        let id = UUID()
        observation = Observation(
            id: id, text: text, processID: processID, language: language,
            historyID: historyID, app: app, isKnownWord: isKnownWord
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.baselineDelay) { [weak self] in
            self?.captureBaseline(for: id)
        }
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        comparisonWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.comparisonDelay, execute: work)
    }

    func flush() {
        comparisonWork?.cancel()
        comparisonWork = nil
        guard let current = observation else { return }
        observation = nil
        guard let baseline = current.baseline else { return }

        let inserted = current.text
        let language = current.language
        let historyID = current.historyID
        let app = current.app
        let isKnownWord = current.isKnownWord
        Self.queue.async { [weak self] in
            guard let after = AccessibilityTextReader.value(of: baseline.element.element) else { return }
            let before = baseline.value
            let caret = baseline.caretLocation.map { utf16Offset in
                // Character offsets, to match how the learner indexes text.
                let utf16 = before.utf16
                let clamped = min(max(utf16Offset, 0), utf16.count)
                let index = utf16.index(utf16.startIndex, offsetBy: clamped)
                return before.distance(from: before.startIndex, to: index)
            }
            let reading = DictationEditReader.read(
                inserted: inserted, before: before, after: after, caretLocation: caret
            )
            let observer = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let reading {
                        observer?.onEdit?(DictationEditObservation(
                            inserted: inserted.trimmingCharacters(in: .whitespacesAndNewlines),
                            editedText: reading.editedText, precedingCharacter: reading.precedingCharacter,
                            historyID: historyID, app: app
                        ))
                    }
                    guard after != before else { return }
                    let corrections = CorrectionLearner.corrections(
                        inserted: inserted, before: before, after: after,
                        caretLocation: caret, isKnownWord: isKnownWord
                    ).map { CorrectionLearner.Correction(heard: $0.heard, corrected: $0.corrected, language: language) }
                    guard !corrections.isEmpty else { return }
                    VocaLogger.info(.dictionary, "Noticed \(corrections.count) correction(s) to dictated text")
                    observer?.onCorrections?(corrections)
                }
            }
        }
    }

    func cancel() {
        comparisonWork?.cancel()
        comparisonWork = nil
        observation = nil
    }

    private func captureBaseline(for id: UUID) {
        guard let current = observation, current.id == id else { return }
        let processID = current.processID
        let inserted = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.queue.async { [weak self] in
            guard let element = AccessibilityTextReader.focusedTextElement(processID: processID),
                  let value = AccessibilityTextReader.value(of: element),
                  value.contains(inserted) else { return }
            let snapshot = FocusedTextSnapshot(
                element: AXElementBox(element: element),
                processID: processID,
                value: value,
                caretLocation: AccessibilityTextReader.caretLocation(of: element)
            )
            let observer = self
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let observer, observer.observation?.id == id else { return }
                    observer.observation?.baseline = snapshot
                }
            }
        }
    }
}
