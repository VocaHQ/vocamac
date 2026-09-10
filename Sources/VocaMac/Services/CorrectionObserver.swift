// CorrectionObserver.swift
// VocaMac
//
// Watches for the user fixing a word VocaMac just typed. It reads the field
// once just after the dictation lands and once more when the user starts
// the next dictation or 20 seconds pass, whichever comes first. Two one-shot
// reads, never polling.

import AppKit
import Foundation

@MainActor
protocol CorrectionObserving: AnyObject {
    /// Called on the main actor with any corrections found.
    var onCorrections: (([CorrectionLearner.Correction]) -> Void)? { get set }
    /// Start watching the field `text` was just typed into.
    func observe(insertedText text: String, processID: pid_t, isKnownWord: @escaping (String) -> Bool)
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

    private struct Observation {
        let id: UUID
        let text: String
        let processID: pid_t
        let isKnownWord: (String) -> Bool
        var baseline: FocusedTextSnapshot?
    }

    private var observation: Observation?
    private var comparisonWork: DispatchWorkItem?

    func observe(insertedText text: String, processID: pid_t, isKnownWord: @escaping (String) -> Bool) {
        flush()
        let id = UUID()
        observation = Observation(id: id, text: text, processID: processID, isKnownWord: isKnownWord)

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
        let isKnownWord = current.isKnownWord
        AccessibilityTextReader.queue.async { [weak self] in
            guard let after = AccessibilityTextReader.value(of: baseline.element.element),
                  after != baseline.value else { return }
            let before = baseline.value
            let caret = baseline.caretLocation.map { utf16Offset in
                // Character offsets, to match how the learner indexes text.
                let utf16 = before.utf16
                let clamped = min(max(utf16Offset, 0), utf16.count)
                let index = utf16.index(utf16.startIndex, offsetBy: clamped)
                return before.distance(from: before.startIndex, to: index)
            }
            DispatchQueue.main.async {
                let corrections = CorrectionLearner.corrections(
                    inserted: inserted, before: before, after: after,
                    caretLocation: caret, isKnownWord: isKnownWord
                )
                guard !corrections.isEmpty else { return }
                VocaLogger.info(.dictionary, "Noticed \(corrections.count) correction(s) to dictated text")
                self?.onCorrections?(corrections)
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
        AccessibilityTextReader.queue.async { [weak self] in
            guard let element = AccessibilityTextReader.focusedTextElement(processID: processID),
                  let value = AccessibilityTextReader.value(of: element),
                  value.contains(inserted) else { return }
            let snapshot = FocusedTextSnapshot(
                element: AXElementBox(element: element),
                processID: processID,
                value: value,
                caretLocation: AccessibilityTextReader.caretLocation(of: element)
            )
            DispatchQueue.main.async {
                guard let self, self.observation?.id == id else { return }
                self.observation?.baseline = snapshot
            }
        }
    }
}
