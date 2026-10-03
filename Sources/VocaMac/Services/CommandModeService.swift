// CommandModeService.swift
// VocaMac
//
// Reads and replaces the active selection for hold-to-command dictation.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

struct SelectedTextSnapshot: @unchecked Sendable {
    /// How the selection was read, which decides how it can be revalidated.
    enum Source: Equatable {
        /// `kAXSelectedText` of the focused element.
        case accessibility
        /// A simulated Cmd+C, for apps whose text isn't exposed through
        /// Accessibility (Electron apps before their tree is built, terminals
        /// and editors with custom text views).
        case clipboard
    }

    let element: AXElementBox?
    /// Owner of the focused element. Differs from `deliveryProcessID` for
    /// out-of-process UI such as Open/Save panels.
    let processID: pid_t
    /// The frontmost app when the selection was read. The replacement is
    /// only delivered while it is still in front.
    let deliveryProcessID: pid_t
    let text: String
    let range: CFRange?
    let source: Source
    /// False for text that can be read but not replaced: a web page, a PDF.
    /// Command Mode shows its answer instead of pasting it.
    let isEditable: Bool
    /// What marks the field the selection was in, so text an edit leaves
    /// there can be found again in that field and no other. Nil when the
    /// selection didn't come through Accessibility.
    let anchor: FieldAnchor?

    init(
        element: AXElementBox?,
        processID: pid_t,
        deliveryProcessID: pid_t? = nil,
        text: String,
        range: CFRange?,
        source: Source = .accessibility,
        isEditable: Bool = true,
        anchor: FieldAnchor? = nil
    ) {
        self.element = element
        self.processID = processID
        self.deliveryProcessID = deliveryProcessID ?? processID
        self.text = text
        self.range = range
        self.source = source
        self.isEditable = isEditable
        self.anchor = anchor
    }
}

/// Why no selection could be captured, worded for the error banner.
enum SelectionCaptureFailure: Error, Equatable {
    case accessibilityPermission
    case noFocusedApp
    case nothingSelected
    case secureField
    case unreadable
    /// The app doesn't share its selection, and copying it is turned off.
    case needsClipboardFallback

    var message: String {
        switch self {
        case .accessibilityPermission:
            return "Command Mode needs Accessibility access. Allow VocaMac in System Settings → Privacy & Security → Accessibility."
        case .noFocusedApp:
            return "Select text in another app, then use the Command Mode shortcut."
        case .nothingSelected:
            return "Nothing is selected. Select the text to edit, then use the Command Mode shortcut."
        case .secureField:
            return "Command Mode doesn't read password fields."
        case .unreadable:
            return "VocaMac couldn't read the selection in this app. Select the text again, or copy it and try once more."
        case .needsClipboardFallback:
            return "This app doesn't share its selection with VocaMac. To edit text here, turn on “Copy the selection when an app hides it” in Settings → Command Mode."
        }
    }
}

@MainActor
protocol SelectedTextAccessing: AnyObject {
    func captureSelection() async -> Result<SelectedTextSnapshot, SelectionCaptureFailure>
    func replaceSelection(_ snapshot: SelectedTextSnapshot, with text: String) async -> Bool
    /// Select `replacement` again where it replaced `snapshot`, so the edit
    /// just made can be edited further. Nil when the app won't allow it or
    /// the text there has changed.
    func reselect(_ snapshot: SelectedTextSnapshot, replacement: String) async -> SelectedTextSnapshot?
    /// Delete the selected text, after confirming it is still the selection
    /// that was read. Taking back text that was written, not replaced.
    func deleteSelection(_ snapshot: SelectedTextSnapshot) async -> Bool
    /// Where the cursor is in the focused field. Nil when the app doesn't say.
    func captureInsertionPoint() async -> InsertionPoint?
}

extension SelectedTextAccessing {
    func reselect(_ snapshot: SelectedTextSnapshot, replacement: String) async -> SelectedTextSnapshot? { nil }
    func deleteSelection(_ snapshot: SelectedTextSnapshot) async -> Bool { false }
    func captureInsertionPoint() async -> InsertionPoint? { nil }
}

@MainActor
final class AccessibilitySelectedTextService: SelectedTextAccessing {
    private let textInjector: TextInjecting
    private let pasteboard: NSPasteboard
    /// The ⌘C fallback puts the selection on the shared clipboard for a
    /// moment, where clipboard managers can see it, so it runs only after
    /// the user turns it on.
    var allowsClipboardFallback: () -> Bool = {
        UserDefaults.standard.bool(forKey: PreferenceKey.commandModeClipboardFallback)
    }

    init(textInjector: TextInjecting = TextInjector(), pasteboard: NSPasteboard = .general) {
        self.textInjector = textInjector
        self.pasteboard = pasteboard
    }

    func captureSelection() async -> Result<SelectedTextSnapshot, SelectionCaptureFailure> {
        guard AXIsProcessTrusted() else { return .failure(.accessibilityPermission) }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return .failure(.noFocusedApp)
        }
        let pid = app.processIdentifier

        var probe = await Self.probe(frontmostPID: pid)
        // Electron apps (Discord, Slack, Notion, …) expose no text until an
        // assistive client asks for their tree. Ask, give Chromium a moment to
        // build it, and read again.
        if case .unavailable = probe,
           AccessibilityTextReader.shouldRequestManualAccessibility(for: app) {
            let newlyEnabled = await withCheckedContinuation { continuation in
                AccessibilityTextReader.queue.async {
                    continuation.resume(returning: AccessibilityTextReader.requestManualAccessibility(processID: pid))
                }
            }
            if newlyEnabled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                probe = await Self.probe(frontmostPID: pid)
            }
        }

        switch probe {
        case .selected(let element, let owner, let text, let range):
            return .success(SelectedTextSnapshot(
                element: element, processID: owner, deliveryProcessID: pid,
                text: text, range: range, source: .accessibility,
                anchor: await Self.anchor(of: element, range: range)
            ))
        case .empty:
            return .failure(.nothingSelected)
        case .secure:
            return .failure(.secureField)
        case .readOnly(let element, let owner, let text, let range):
            return .success(SelectedTextSnapshot(
                element: element, processID: owner, deliveryProcessID: pid,
                text: text, range: range, source: .accessibility, isEditable: false
            ))
        case .unavailable:
            // Last resort for apps that don't expose their text: copy it.
            guard allowsClipboardFallback() else { return .failure(.needsClipboardFallback) }
            let copy = await copySelectionViaClipboard(expectedProcessID: pid)
            guard case .copied(let copied) = copy else {
                // An app leaves the clipboard alone when nothing is selected.
                return .failure(copy == .nothing ? .nothingSelected : .unreadable)
            }
            VocaLogger.info(.appState, "Command Mode read the selection through the clipboard")
            return .success(SelectedTextSnapshot(
                element: nil, processID: pid, deliveryProcessID: pid,
                text: copied, range: nil, source: .clipboard
            ))
        }
    }

    func replaceSelection(_ snapshot: SelectedTextSnapshot, with text: String) async -> Bool {
        guard await selectionIsStillThere(snapshot) else { return false }

        // TextInjector deliberately uses direct AX writes only for controls
        // that apply them reliably, then falls back to clipboard + Cmd+V for
        // text areas used by browsers, Electron apps, editors, and terminals.
        // Calling the AX setter here made those apps report success while
        // silently leaving the selected text unchanged.
        textInjector.inject(
            text: text,
            preserveClipboard: true,
            expectedProcessID: snapshot.deliveryProcessID
        )
        return true
    }

    /// The selection that was read is still what is selected, in the app
    /// still in front. Checked before anything is typed over it: the model
    /// ran for seconds, and a reviewed edit may have waited for minutes.
    private func selectionIsStillThere(_ snapshot: SelectedTextSnapshot) async -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.deliveryProcessID else {
            return false
        }
        switch snapshot.source {
        case .accessibility:
            var probe = await Self.probe(frontmostPID: snapshot.deliveryProcessID)
            if case .unavailable = probe {
                // One slow answer is common right after a model run; a second
                // miss means the selection can't be verified, so leave it.
                try? await Task.sleep(nanoseconds: 150_000_000)
                probe = await Self.probe(frontmostPID: snapshot.deliveryProcessID)
            }
            return Self.selectionStillMatches(snapshot, probe: probe)
        case .clipboard:
            // The app never said what was selected, so ask it the way it was
            // asked the first time. Without this a different selection made
            // in the meantime would be pasted over.
            guard allowsClipboardFallback() else { return false }
            let copy = await copySelectionViaClipboard(expectedProcessID: snapshot.deliveryProcessID)
            guard case .copied(let copied) = copy else { return false }
            return Self.copiedSelectionStillMatches(snapshot, copied: copied)
        }
    }

    /// Whether a fresh copy of the selection is the text that was read.
    nonisolated static func copiedSelectionStillMatches(_ snapshot: SelectedTextSnapshot, copied: String) -> Bool {
        snapshot.source == .clipboard && copied == snapshot.text
    }

    // MARK: - Validation

    /// The user may have clicked elsewhere or changed the selection while the
    /// model ran. Replace only what was read, but don't insist on the same
    /// `AXUIElement` identity: SwiftUI and web views hand out a fresh element
    /// for the same field on every query.
    nonisolated static func selectionStillMatches(
        _ snapshot: SelectedTextSnapshot,
        probe: AccessibilityTextReader.SelectionProbe
    ) -> Bool {
        switch probe {
        case .selected(_, let owner, let text, let range):
            return owner == snapshot.processID
                && text == snapshot.text
                && (range == nil || snapshot.range == nil || rangesMatch(range, snapshot.range))
        case .readOnly(_, let owner, let text, let range):
            // Read-only text is only ever answered, never replaced; matching
            // it lets the caller confirm the same passage is still selected.
            return !snapshot.isEditable && owner == snapshot.processID && text == snapshot.text
                && (range == nil || snapshot.range == nil || rangesMatch(range, snapshot.range))
        case .unavailable, .empty, .secure:
            // A selection that can't be read again can't be shown to be the
            // one that was edited; replacing it could overwrite new text.
            return false
        }
    }

    nonisolated static func rangesMatch(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            return lhs.location == rhs.location && lhs.length == rhs.length
        case (.none, .none):
            return true
        default:
            return false
        }
    }

    private static func probe(frontmostPID: pid_t) async -> AccessibilityTextReader.SelectionProbe {
        await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.probeSelection(frontmostPID: frontmostPID))
            }
        }
    }

    // MARK: - Clipboard fallback

    /// What a simulated Cmd+C produced.
    private enum ClipboardCopy: Equatable {
        case copied(String)
        /// The app copied nothing, or only the line under the cursor: there
        /// is no selection.
        case nothing
        /// The app can't be asked, or copied something that isn't text.
        case failed
    }

    /// Copy the selection with a simulated Cmd+C and put the clipboard back.
    private func copySelectionViaClipboard(expectedProcessID pid: pid_t) async -> ClipboardCopy {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return .failed }
        let saved = PasteboardContents(pasteboard)
        let before = pasteboard.changeCount
        postShortcut("c", fallback: CGKeyCode(kVK_ANSI_C))

        for _ in 0..<20 where pasteboard.changeCount == before {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard pasteboard.changeCount != before else { return .nothing }
        defer { saved.restore(to: pasteboard) }
        // VS Code and its forks copy the whole current line when nothing
        // is selected. That line is not a selection; replacing "it" would
        // paste a rewritten copy next to the original.
        if Self.isEditorEmptySelectionCopy(pasteboard) { return .nothing }
        guard let copied = pasteboard.string(forType: .string) else { return .failed }
        return copied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothing : .copied(copied)
    }

    // MARK: - Editing again, and undo

    func reselect(_ snapshot: SelectedTextSnapshot, replacement: String) async -> SelectedTextSnapshot? {
        // Without the field's anchor there is no telling this field from
        // another that holds the same words, so nothing is selected.
        guard snapshot.source == .accessibility, let location = snapshot.range?.location,
              let anchor = snapshot.anchor,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.deliveryProcessID else {
            return nil
        }
        let pid = snapshot.deliveryProcessID
        let selected = await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.selectText(
                    replacement, at: location, in: anchor, frontmostPID: pid
                ))
            }
        }
        guard selected else { return nil }
        // Read it back: an app may accept the range and select something else.
        guard case .selected(let element, let owner, let text, let range) = await Self.probe(frontmostPID: pid),
              text == replacement else { return nil }
        return SelectedTextSnapshot(
            element: element, processID: owner, deliveryProcessID: pid,
            text: text, range: range, source: .accessibility,
            anchor: await Self.anchor(of: element, range: range)
        )
    }

    private static func anchor(of element: AXElementBox, range: CFRange?) async -> FieldAnchor {
        await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.fieldAnchor(of: element.element, range: range))
            }
        }
    }

    func captureInsertionPoint() async -> InsertionPoint? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        return await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.insertionPoint(processID: pid))
            }
        }
    }

    func deleteSelection(_ snapshot: SelectedTextSnapshot) async -> Bool {
        guard AXIsProcessTrusted(), await selectionIsStillThere(snapshot) else { return false }
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Delete), keyDown: isDown
            ) else { return false }
            event.flags = []
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
        return true
    }

    nonisolated static func isEditorEmptySelectionCopy(_ pasteboard: NSPasteboard) -> Bool {
        let type = NSPasteboard.PasteboardType("vscode-editor-data")
        guard let data = pasteboard.data(forType: type),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["isFromEmptySelection"] as? Bool == true
    }

    /// Press Command plus `character`, found on the current keyboard layout.
    private func postShortcut(_ character: Character, fallback: CGKeyCode) {
        let keyCode = TextInjector.keyCode(forCharacter: character) ?? fallback
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { return }
            event.flags = [.maskCommand]
            event.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}

/// Every item and type on a pasteboard, deep-copied so it can be put back
/// after a simulated copy.
private struct PasteboardContents {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Marks the restore for clipboard managers (nspasteboard.org), so
    /// putting the user's own clipboard back doesn't show up as a new copy.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.filter { !$0.isEmpty }.map { types -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            item.setData(Data(), forType: Self.transientType)
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
