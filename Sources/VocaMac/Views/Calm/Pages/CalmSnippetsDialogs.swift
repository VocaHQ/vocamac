// CalmSnippetsDialogs.swift
// VocaMac
//
// “New snippet” and “Edit snippet”: Say (the trigger) and Type (the text,
// several lines allowed). Editing shows Delete at the far left, which
// removes the snippet with Undo on offer.

import SwiftUI

/// What the snippet editor opens for.
enum CalmSnippetEditorRequest: Identifiable {
    case add
    case edit(Snippet)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let snippet): return snippet.id.uuidString
        }
    }
}

/// Add or edit a snippet. Save stays disabled until both fields have text;
/// a trigger another snippet already uses says so under the field.
struct CalmSnippetEditor: View {
    let request: CalmSnippetEditorRequest

    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    @State private var trigger: String
    @State private var expansion: String
    @FocusState private var isTriggerFocused: Bool

    init(request: CalmSnippetEditorRequest) {
        self.request = request
        switch request {
        case .add:
            _trigger = State(initialValue: "")
            _expansion = State(initialValue: "")
        case .edit(let snippet):
            _trigger = State(initialValue: snippet.trigger)
            _expansion = State(initialValue: snippet.expansion)
        }
    }

    private var editingSnippet: Snippet? {
        if case .edit(let snippet) = request { return snippet }
        return nil
    }

    var body: some View {
        let check = appState.checkSnippet(trigger: trigger, expansion: expansion, editing: editingSnippet?.id)
        CalmDialog(editingSnippet == nil ? "New snippet" : "Edit snippet") {
            CalmTextField("Say", text: $trigger, prompt: "e.g. my address", error: check.message, focus: $isTriggerFocused)
                .help("Say this while dictating and VocaMac types the text below instead.")
            CalmTextEditor("Type", text: $expansion, prompt: "The text VocaMac types for it")
        } footer: {
            CalmDialogFooter(
                primaryTitle: editingSnippet == nil ? "Add" : "Save",
                isPrimaryEnabled: check.isValid,
                onPrimary: save
            ) {
                if let snippet = editingSnippet {
                    Button("Delete") {
                        appState.removeSnippet(snippet)
                        dismissDialog?()
                    }
                    .calmButton(.quietAmber)
                }
            }
        }
        .onAppear {
            guard editingSnippet == nil else { return }
            DispatchQueue.main.async { isTriggerFocused = true }
        }
    }

    private func save() {
        guard appState.checkSnippet(trigger: trigger, expansion: expansion, editing: editingSnippet?.id).isValid else { return }
        appState.saveSnippet(id: editingSnippet?.id, trigger: trigger, expansion: expansion)
    }
}
