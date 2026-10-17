// CalmDialog.swift
// VocaMac
//
// Small modal dialogs (Dialogs board): 440 wide (520 for lists), r14,
// padding 24, gap 18, centred over the whole window with the scrim. They
// render inside the window, above the Settings sheet when it is open, so
// no extra NSWindow is involved. A dialog never grows past the window: its
// content scrolls between the title and the footer instead.

import SwiftUI

// MARK: - Dialog container

/// The dialog card: SF 17/650 title, optional SF 13 muted description,
/// content, and a footer whose buttons sit on the right. A dialog can
/// replace the title block with its own header (the model details dialog
/// puts a logo beside the name).
///
/// ```swift
/// CalmDialog("Clear all history?", description: "This deletes 1,284 dictations.", width: CalmMetrics.confirmDialogWidth) {
///     EmptyView()
/// } footer: {
///     CalmDialogFooter(primaryTitle: "Clear history", primaryKind: .destructive) { clear() }
/// }
/// ```
struct CalmDialog<Header: View, Content: View, Footer: View>: View {
    let title: String
    var description: String?
    var width: CGFloat = CalmMetrics.dialogWidth
    /// Replaces the title and description when set.
    let header: Header?
    let content: Content
    let footer: Footer

    /// A dialog with its own header. `title` is still what VoiceOver
    /// announces for the dialog.
    init(
        _ title: String, width: CGFloat = CalmMetrics.dialogWidth,
        @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.description = nil
        self.width = width
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.dialog, style: .continuous)
        VStack(alignment: .leading, spacing: CalmMetrics.dialogGap) {
            if let header {
                header
            } else {
                titleBlock
            }
            if !(content is EmptyView) {
                fittedContent
            }
            footer
        }
        .padding(CalmMetrics.dialogPadding)
        .frame(width: width, alignment: .leading)
        // The shadow belongs to the card's shape only: on the whole dialog
        // every field and button inside would cast one too.
        .background(shape.fill(CalmColor.content).shadow(color: .black.opacity(0.22), radius: 30, y: 24))
        .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(title)
    }

    /// The content as laid out, or, when the dialog would be taller than
    /// the window, scrolling between the fixed title and footer so every
    /// row and the footer's buttons stay reachable.
    private var fittedContent: some View {
        ViewThatFits(in: .vertical) {
            contentStack
            ScrollView(.vertical) {
                // Room for focus rings, which the scroll view would clip.
                contentStack.padding(Self.focusRingRoom)
            }
            .padding(-Self.focusRingRoom)
        }
    }

    private static var focusRingRoom: CGFloat { 4 }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: CalmMetrics.dialogGap) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(CalmFont.dialogTitle)
                .foregroundStyle(CalmColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let description {
                Text(description)
                    .calmType(.description)
                    .lineSpacing(3.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension CalmDialog where Header == EmptyView {
    init(
        _ title: String, description: String? = nil, width: CGFloat = CalmMetrics.dialogWidth,
        @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.description = description
        self.width = width
        self.header = nil
        self.content = content()
        self.footer = footer()
    }
}

extension CalmDialog where Header == EmptyView, Content == EmptyView {
    /// A confirmation: title, description and footer only.
    init(_ title: String, description: String? = nil, width: CGFloat = CalmMetrics.confirmDialogWidth, @ViewBuilder footer: () -> Footer) {
        self.init(title, description: description, width: width, content: { EmptyView() }, footer: footer)
    }
}

/// The standard dialog footer: an optional action far left, then Cancel
/// and the primary action on the right. Return triggers the primary
/// action, Esc triggers Cancel. Cancel defaults to closing the dialog.
///
/// ```swift
/// CalmDialogFooter(primaryTitle: "Save", isPrimaryEnabled: isValid) { save() } leading: {
///     Button("Use default") { … }.calmButton(.quiet)
/// }
/// CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil) { }   // pickers: Esc also closes
/// ```
struct CalmDialogFooter<Leading: View>: View {
    let primaryTitle: String
    var primaryKind: CalmButtonKind = .primary
    var isPrimaryEnabled = true
    /// Nil hides Cancel (pickers apply immediately; Done just closes).
    var cancelTitle: String? = "Cancel"
    /// Runs on Cancel / Esc instead of just closing.
    var onCancel: (() -> Void)?
    /// Close the dialog after the primary action runs.
    var dismissesOnPrimary = true
    let onPrimary: () -> Void
    let leading: Leading

    @Environment(\.calmDismissDialog) private var dismissDialog

    init(
        primaryTitle: String, primaryKind: CalmButtonKind = .primary, isPrimaryEnabled: Bool = true,
        cancelTitle: String? = "Cancel", onCancel: (() -> Void)? = nil, dismissesOnPrimary: Bool = true,
        onPrimary: @escaping () -> Void, @ViewBuilder leading: () -> Leading
    ) {
        self.primaryTitle = primaryTitle
        self.primaryKind = primaryKind
        self.isPrimaryEnabled = isPrimaryEnabled
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.dismissesOnPrimary = dismissesOnPrimary
        self.onPrimary = onPrimary
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 0)
            if let cancelTitle {
                Button(cancelTitle, action: cancel)
                    .calmButton(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Button(primaryTitle) {
                onPrimary()
                if dismissesOnPrimary { dismissDialog?() }
            }
            .calmButton(primaryKind)
            .keyboardShortcut(.defaultAction)
            .disabled(!isPrimaryEnabled)
        }
        .background {
            if cancelTitle == nil {
                // Esc still closes a dialog that has no Cancel button.
                Button("Close", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private func cancel() {
        if let onCancel { onCancel() } else { dismissDialog?() }
    }
}

extension CalmDialogFooter where Leading == EmptyView {
    init(
        primaryTitle: String, primaryKind: CalmButtonKind = .primary, isPrimaryEnabled: Bool = true,
        cancelTitle: String? = "Cancel", onCancel: (() -> Void)? = nil, dismissesOnPrimary: Bool = true,
        onPrimary: @escaping () -> Void
    ) {
        self.init(
            primaryTitle: primaryTitle, primaryKind: primaryKind, isPrimaryEnabled: isPrimaryEnabled,
            cancelTitle: cancelTitle, onCancel: onCancel, dismissesOnPrimary: dismissesOnPrimary,
            onPrimary: onPrimary
        ) { EmptyView() }
    }
}

// MARK: - Lists in dialogs

extension View {
    /// A list inside a dialog: its own height while short, scrolling past
    /// `maxHeight`, so a long one leaves the rest of the dialog in view.
    func calmDialogScrollingList(maxHeight: CGFloat = CalmMetrics.dialogListMaxHeight) -> some View {
        ScrollView(.vertical) { self }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Dismiss action

/// Closes the dialog that is showing. Read with `@Environment(\.calmDismissDialog)`.
struct CalmDismissDialogAction {
    let action: @MainActor () -> Void

    @MainActor func callAsFunction() { action() }
}

private struct CalmDismissDialogKey: EnvironmentKey {
    static var defaultValue: CalmDismissDialogAction? { nil }
}

extension EnvironmentValues {
    /// Closes the presented Calm dialog (nil outside a dialog).
    var calmDismissDialog: CalmDismissDialogAction? {
        get { self[CalmDismissDialogKey.self] }
        set { self[CalmDismissDialogKey.self] = newValue }
    }
}

// MARK: - Presentation

/// One presented dialog travelling up to the window's dialog host.
struct CalmDialogEntry: Identifiable {
    let id: UUID
    let content: AnyView
    let dismiss: @MainActor () -> Void
}

/// Collects presented dialogs from anywhere in the window (pages, the
/// Settings sheet). The last one shows.
struct CalmDialogStackKey: SwiftUI.PreferenceKey {
    static var defaultValue: [CalmDialogEntry] { [] }
    static func reduce(value: inout [CalmDialogEntry], nextValue: () -> [CalmDialogEntry]) {
        value.append(contentsOf: nextValue())
    }
}

/// Whether any Calm dialog is showing, for the window's own Esc handling.
struct CalmDialogPresenceKey: SwiftUI.PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct CalmDialogPresenter<Dialog: View>: ViewModifier {
    @Binding var isPresented: Bool
    let dialog: () -> Dialog

    @State private var id = UUID()

    init(isPresented: Binding<Bool>, @ViewBuilder dialog: @escaping () -> Dialog) {
        _isPresented = isPresented
        self.dialog = dialog
    }

    func body(content: Content) -> some View {
        let binding = $isPresented
        let shows = isPresented
        let entryID = id
        let dialog = dialog
        // `transformPreference`, not `preference`: a view with several
        // `.calmDialog` modifiers (or a page whose rows present their own)
        // must keep the entries from inside it. `.preference` replaces
        // them, so only the outermost dialog could ever open.
        content
            .transformPreference(CalmDialogStackKey.self) { entries in
                guard shows else { return }
                entries.append(CalmDialogEntry(id: entryID, content: AnyView(dialog()), dismiss: { binding.wrappedValue = false }))
            }
            .transformPreference(CalmDialogPresenceKey.self) { value in
                value = value || shows
            }
    }
}

extension View {
    /// Presents a Calm dialog centred over the window, with the scrim, while
    /// `isPresented` is true. Works from any page and from inside the
    /// Settings sheet; the window's `calmDialogHost()` draws it.
    ///
    /// ```swift
    /// .calmDialog(isPresented: $showClear) {
    ///     CalmDialog("Clear all history?", description: "…") {
    ///         CalmDialogFooter(primaryTitle: "Clear history", primaryKind: .destructive) { clear() }
    ///     }
    /// }
    /// ```
    func calmDialog<Dialog: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Dialog) -> some View {
        modifier(CalmDialogPresenter(isPresented: isPresented, dialog: content))
    }

    /// Presents a Calm dialog for `item` while it is non-nil.
    func calmDialog<Item, Dialog: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Dialog) -> some View {
        let isPresented = Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
        return modifier(CalmDialogPresenter(isPresented: isPresented) {
            if let value = item.wrappedValue { content(value) }
        })
    }

    /// Draws presented Calm dialogs over this view: the scrim fills it and
    /// the top dialog sits centred. Apply once, at the window root.
    func calmDialogHost() -> some View {
        overlayPreferenceValue(CalmDialogStackKey.self) { entries in
            CalmDialogLayer(entry: entries.last)
        }
    }
}

private struct CalmDialogLayer: View {
    let entry: CalmDialogEntry?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let entry {
                CalmColor.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity)
                    .accessibilityHidden(true)
                entry.content
                    // Keeps a tall dialog inside the window: `CalmDialog`
                    // scrolls its content when this is too short for it.
                    .padding(CalmMetrics.dialogWindowMargin)
                    .environment(\.calmDismissDialog, CalmDismissDialogAction(action: entry.dismiss))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .id(entry.id)
            }
        }
        .animation(.easeOut(duration: 0.18), value: entry?.id)
    }
}
