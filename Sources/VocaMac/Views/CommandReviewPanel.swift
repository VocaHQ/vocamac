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

    /// The design's Command Mode preview card: 480 wide.
    static let width: CGFloat = 480
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

/// The Command Mode preview: the instruction as its title, the selection
/// struck through, the result in a panel, and Keep original / Replace. Uses
/// the normal theme, since it asks for a decision; violet only marks it as
/// Command Mode.
struct CommandReviewView: View {
    let review: CommandReview
    let onAccept: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if review.kind == .edit {
                        Text(review.original.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 14))
                            .lineSpacing(5)
                            .foregroundStyle(CalmColor.muted)
                            .strikethrough(true, color: CalmColor.amber)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel("Before: \(review.original)")
                    }
                    Text(review.result.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(CalmFont.sf(14, weight: 500))
                        .lineSpacing(5)
                        .foregroundStyle(CalmColor.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 14)
                        .background(
                            RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous)
                                .fill(CalmColor.panel)
                        )
                        .accessibilityLabel(review.kind == .edit ? "After: \(review.result)" : "Answer: \(review.result)")
                }
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)

            if let note = review.note {
                CalmInlineNotice("Check this: \(note).", tone: .warning)
            }

            footer
        }
        .padding(CalmMetrics.dialogPadding)
        .frame(width: CommandReviewPanelController.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: CalmMetrics.Radius.dialog, style: .continuous)
                .fill(CalmColor.content)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CalmMetrics.Radius.dialog, style: .continuous)
                .strokeBorder(CalmColor.line2, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(review.kind == .edit ? "Command Mode edit to review" : "Command Mode answer")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            CalmIcon(.commands, size: 15)
                .foregroundStyle(CalmColor.violet)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Self.violetSoft)
                )
            Text(Self.title(for: review))
                .font(CalmFont.sf(15, weight: 650))
                .foregroundStyle(CalmColor.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(review.engineName)
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .lineLimit(1)
                .help("The model that wrote this")
            if review.kind == .edit {
                // Copy sits up here so the footer keeps the design's two
                // buttons at full width.
                Button(action: onCopy) {
                    CalmIcon(.copy, size: 15)
                }
                .calmIconButton(size: 28)
                .help("Copy the result")
                .accessibilityLabel("Copy the result")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(review.kind == .edit ? "Say “undo” to go back later" : "Esc closes")
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 8)
            if review.kind == .edit {
                Button("Keep original", action: onDismiss)
                    .calmButton(.secondary)
                    .fixedSize()
                    .help("Leave the text as it is (Esc)")
                Button(action: onAccept) {
                    HStack(spacing: 4) {
                        Text("Replace")
                        if let keys = review.acceptShortcut {
                            Self.keyCap(keys)
                        }
                    }
                }
                .calmButton(.primary)
                .fixedSize()
                .help(review.acceptShortcut.map { "Replace the selection (\($0))" } ?? "Replace the selection")
            } else {
                Button("Close", action: onDismiss)
                    .calmButton(.secondary)
                    .help("Close (Esc)")
                Button("Copy", action: onCopy)
                    .calmButton(.primary)
            }
        }
    }

    /// The keys that accept, on the primary button: a 20-point cap with a
    /// faint ring in the button's own text colour.
    private static func keyCap(_ keys: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.key, style: .continuous)
        return Text(keys)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20, maxHeight: 20)
            .overlay(shape.strokeBorder(CalmColor.onPrimary.opacity(0.3), lineWidth: 1))
    }

    /// Violet at 9% (light) or 13% (dark), behind the Command Mode icon.
    static let violetSoft = Color(nsColor: NSColor.calmAdaptive(
        light: CalmNSColor.rgb(0x7047DB, 0.09), dark: CalmNSColor.rgb(0xB89EFF, 0.13)
    ))

    /// The instruction as a title: "make this shorter" → "Make this shorter".
    static func title(for review: CommandReview) -> String {
        let instruction = review.instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"."))
        guard let first = instruction.first else {
            return review.kind == .edit ? "Review the edit" : "Answer"
        }
        return first.uppercased() + instruction.dropFirst()
    }
}
