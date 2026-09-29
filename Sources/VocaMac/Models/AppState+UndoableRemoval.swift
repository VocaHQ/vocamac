// AppState+UndoableRemoval.swift
// VocaMac
//
// List removals in Settings that can be taken back. The views only dispatch
// these; what counts as a conflicting entry, and how a removal is restored,
// lives here with the rest of the app's state.

import Foundation

extension AppState {
    /// Remove a snippet, offering Undo.
    func removeSnippet(_ snippet: Snippet) {
        undoCenter.remove(
            id: snippet.id, from: \.snippets, of: self,
            message: "Removed snippet “\(snippet.trigger)”",
            conflictsWith: Snippet.sharesTrigger
        )
    }

    /// Remove a replacement, offering Undo.
    func removeWordReplacement(_ replacement: WordReplacement) {
        undoCenter.remove(
            id: replacement.id, from: \.wordReplacements, of: self,
            message: "Removed replacement for “\(replacement.replacement)”",
            conflictsWith: WordReplacement.overlaps
        )
    }

    /// Remove a vocabulary term, offering Undo that puts it back in place.
    func removeVocabularyTermWithUndo(_ term: String) {
        guard let index = vocabularyTerms.firstIndex(of: term) else { return }
        removeVocabularyTerm(term)
        undoCenter.offer("Removed “\(term)”") { [weak self] in
            self?.restoreVocabularyTerm(term, at: index)
        }
    }

    /// Remove a per-website style rule, offering Undo.
    func removeWebsiteRule(_ rule: WebsiteStyleBinding) {
        undoCenter.remove(
            id: rule.id, from: \.websiteStyleBindings, of: self,
            message: "Removed \(rule.displayName)",
            conflictsWith: WebsiteStyleBinding.sharesHost
        )
    }

    /// Remove a per-app style rule, offering Undo.
    func removeAppStyleBinding(_ binding: AppStyleBinding) {
        undoCenter.remove(
            id: binding.id, from: \.writingStyleBindings, of: self,
            message: "Removed \(binding.displayName)",
            conflictsWith: AppStyleBinding.sharesApp
        )
    }

    /// Remove every per-app style rule, offering Undo. `onUndo` runs after a
    /// restore, so the caller can clear a notice that said they were removed.
    func removeAllAppStyleBindingsWithUndo(onUndo: @escaping () -> Void = {}) {
        let count = writingStyleBindings.count
        guard count > 0 else { return }
        VocaLogger.info(.appState, "Removed all writing style rules")
        undoCenter.removeAll(
            from: \.writingStyleBindings, of: self,
            message: "Removed \(count) apps",
            conflictsWith: AppStyleBinding.sharesApp,
            afterUndo: onUndo
        )
    }

    /// Remove an app from the auto-pause list, offering Undo.
    func removeAutoPauseApp(_ app: AutoPauseAppEntry) {
        undoCenter.remove(
            id: app.id, from: \.autoPauseApps, of: self,
            message: "Removed \(app.displayName)"
        )
    }
}
