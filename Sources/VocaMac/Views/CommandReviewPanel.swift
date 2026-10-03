// CommandReviewPanel.swift
// VocaMac
//
// A floating panel for a Command Mode result that isn't pasted straight away:
// an edit waiting to be approved, or an answer about text that can't be edited.

import AppKit
import SwiftUI

/// A Command Mode result held for the user instead of pasted.
struct CommandReview: Equatable, Identifiable {
    enum Kind: Equatable {
        /// An edit of the selection, applied when accepted.
        case edit
        /// An answer about text that can't be replaced. There is nothing to
        /// apply; it can be copied.
        case answer
    }

    let id = UUID()
    let kind: Kind
    let instruction: String
    let original: String
    let result: String
    let engineName: String
    /// Something the checks noticed about the result ("a link is missing").
    var note: String?
    /// The keys that accept the edit, for the hint line.
    var acceptShortcut: String?

    static func == (lhs: CommandReview, rhs: CommandReview) -> Bool {
        lhs.kind == rhs.kind && lhs.instruction == rhs.instruction && lhs.original == rhs.original
            && lhs.result == rhs.result && lhs.engineName == rhs.engineName && lhs.note == rhs.note
    }
}

/// Shows a `CommandReview`. A protocol so the flow can be tested without a
/// window server.
@MainActor
protocol CommandReviewPresenting: AnyObject {
    func show(_ review: CommandReview, onAccept: @escaping () -> Void, onCopy: @escaping () -> Void, onDismiss: @escaping () -> Void)
    func hide()
}

@MainActor
final class CommandReviewPanelController: CommandReviewPresenting {
    private var panel: NSPanel?

    static let width: CGFloat = 560
    static let maximumHeight: CGFloat = 460

    func show(
        _ review: CommandReview,
        onAccept: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let view = CommandReviewView(review: review, onAccept: onAccept, onCopy: onCopy, onDismiss: onDismiss)
        let hosting = FirstMouseHostingView(rootView: view)
        hosting.appearance = nil
        let fitting = hosting.fittingSize
        let size = CGSize(width: Self.width, height: min(Self.maximumHeight, max(140, fitting.height)))
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        panel.contentView = hosting
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    /// Never takes focus: the selection it is about lives in another app, and
    /// activating VocaMac would be the end of it.
    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    /// Upper middle of the screen the pointer is on: near where the user is
    /// looking, and clear of most text being edited.
    private static func origin(for size: CGSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return .zero }
        return NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - max(60, frame.height * 0.12)
        )
    }
}

/// Buttons in a panel that never becomes key would otherwise swallow the
/// first click as "activate the window".
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct CommandReviewView: View {
    let review: CommandReview
    let onAccept: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: review.kind == .edit ? "wand.and.stars" : "text.bubble")
                    .foregroundStyle(VocaDesign.command)
                Text(review.kind == .edit ? "Review the edit" : "Answer")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(review.engineName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("“\(review.instruction)”")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            ScrollView {
                Text(Self.content(for: review, colorScheme: colorScheme))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 280)
            .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(VocaDesign.line))

            if let note = review.note {
                Label("Check this: \(note).", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(VocaDesign.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(review.kind == .edit ? "Discard" : "Close", action: onDismiss)
                Button("Copy", action: onCopy)
                if review.kind == .edit {
                    Button("Replace", action: onAccept)
                        .buttonStyle(.borderedProminent)
                        .tint(VocaDesign.command)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: CommandReviewPanelController.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VocaDesign.command.opacity(0.35))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(review.kind == .edit ? "Command Mode edit to review" : "Command Mode answer")
    }

    private var hint: String {
        switch review.kind {
        case .edit:
            let accept = review.acceptShortcut.map { "\($0) replaces" } ?? "Replace applies it"
            return "\(accept) · Esc discards"
        case .answer:
            return "Esc closes"
        }
    }

    /// The result as text to show: an edit as what changed, an answer as it is.
    static func content(for review: CommandReview, colorScheme: ColorScheme) -> AttributedString {
        guard review.kind == .edit else { return AttributedString(review.result) }
        var text = AttributedString()
        for segment in WordDiff.segments(from: review.original, to: review.result) {
            var part = AttributedString(segment.text)
            switch segment.kind {
            case .same:
                break
            case .removed:
                part.foregroundColor = VocaDesign.clay.opacity(colorScheme == .dark ? 0.95 : 0.9)
                part.strikethroughStyle = .single
            case .added:
                part.foregroundColor = VocaDesign.accent
                part.underlineStyle = .single
            }
            text += part
        }
        return text
    }
}
