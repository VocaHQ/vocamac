// CalmLayout.swift
// VocaMac
//
// The v3 Patterns board: page column, headers, group labels, panels with
// setting rows, lists, empty states and cards (feature, stat, tip,
// streak, heatmap).

import SwiftUI

// MARK: - Page container

/// How wide a page's column may grow.
enum CalmPageLayout: Sendable {
    /// Lists and feeds: max 940 including padding 44 / 48, gap 26.
    case list
    /// Forms: max 860 including padding 44 / 48, gap 26.
    case form
    /// Inside the Settings sheet body: full width, padding 40 / 48, gap 24.
    case sheet

    var maxWidth: CGFloat? {
        switch self {
        case .list: return CalmMetrics.pageMaxWidthList
        case .form: return CalmMetrics.pageMaxWidthForm
        case .sheet: return nil
        }
    }

    var padding: EdgeInsets {
        switch self {
        case .list, .form:
            return EdgeInsets(
                top: CalmMetrics.pageTopPadding, leading: CalmMetrics.pageSidePadding,
                bottom: CalmMetrics.pageBottomPadding, trailing: CalmMetrics.pageSidePadding
            )
        case .sheet: return CalmMetrics.sheetBodyPadding
        }
    }

    var gap: CGFloat { self == .sheet ? CalmMetrics.sheetGap : CalmMetrics.pageGap }
}

/// A scrolling page column, centred in the content area. It scrolls to a
/// Settings search target (`.settingsTarget(_:)`) when one is selected,
/// so pages only need to tag their controls.
///
/// ```swift
/// CalmPage(.form) {
///     CalmPageHeader("General")
///     CalmPanel { … }
/// }
/// ```
struct CalmPage<Content: View>: View {
    let layout: CalmPageLayout
    let spacing: CGFloat?
    let content: Content

    @Environment(\.settingsSearchTarget) private var searchTarget

    init(_ layout: CalmPageLayout = .list, spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.layout = layout
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The max width includes the padding, as in the design's border-box column.
                VStack(alignment: .leading, spacing: spacing ?? layout.gap) {
                    content
                }
                // minWidth 0: the column is as wide as the page allows,
                // whatever its content would like.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(layout.padding)
                .frame(maxWidth: layout.maxWidth ?? .infinity)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .task(id: searchTarget) {
                guard let searchTarget else { return }
                // One layout pass for a newly shown page or revealed row first.
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(searchTarget, anchor: .center) }
            }
        }
    }
}

// MARK: - Page headers

/// A page header: the New York 30 title, an optional description (SF 14
/// muted, 6 below), an optional back link above (sub-pages), and trailing
/// actions on the right (at most one primary).
///
/// ```swift
/// CalmPageHeader("Insights")
/// CalmPageHeader("Dictionary") { Button { … } label: { CalmButtonLabel("Add new", icon: .plus) }.calmButton(.primary) }
/// CalmPageHeader("Styles", description: "How your words look in each kind of app.")
/// CalmPageHeader("Languages", back: CalmBack("General") { navigator.goBack() })
/// ```
/// Inside the Settings sheet, prefer `CalmSubPageHeader`, which fills the
/// back link from the navigator.
struct CalmPageHeader<Trailing: View>: View {
    let title: String
    var description: String?
    var back: CalmBack?
    let trailing: Trailing

    init(
        _ title: String, description: String? = nil, back: CalmBack? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.description = description
        self.back = back
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let back {
                CalmBackLink(title: back.title, action: back.action)
            }
            // The actions centre on the title line, not on title plus
            // description (Styles' ⋯ sat halfway down the description).
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 14) {
                    Text(title)
                        .calmType(.title)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    trailing
                }
                if let description {
                    Text(description)
                        .calmType(.pageDescription)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

extension CalmPageHeader where Trailing == EmptyView {
    init(_ title: String, description: String? = nil, back: CalmBack? = nil) {
        self.init(title, description: description, back: back) { EmptyView() }
    }
}

/// A sub-page back link: the page it returns to and how to get there.
struct CalmBack {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// The header of a Settings sub-page. Its back link names and returns to
/// the page it came from, using the window's `CalmNavigator`.
///
/// ```swift
/// CalmSubPageHeader("Languages")
/// ```
struct CalmSubPageHeader<Trailing: View>: View {
    let title: String
    var description: String?
    let trailing: Trailing

    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?

    init(_ title: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.trailing = trailing()
    }

    var body: some View {
        CalmPageHeader(title, description: description, back: back) { trailing }
    }

    private var back: CalmBack? {
        guard let navigator, let destination = navigator.backDestination else { return nil }
        return CalmBack(destination.title) { navigator.goBack() }
    }
}

extension CalmSubPageHeader where Trailing == EmptyView {
    init(_ title: String, description: String? = nil) {
        self.init(title, description: description) { EmptyView() }
    }
}

/// The muted “‹ General” link above a sub-page title.
struct CalmBackLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                CalmIcon(.chevLeft, size: 13)
                Text(title)
            }
        }
        .calmLink(muted: true, font: CalmFont.backLink)
        .accessibilityLabel("Back to \(title)")
    }
}

/// A feature page header: title, an optional on/off switch, and the
/// feature's shortcut pill (a button when `onShortcutTap` is set).
///
/// ```swift
/// CalmFeatureHeader("Commands", shortcut: ["⌃", "⌥", "E"], shortcutCaption: "to edit by voice") { showRecorder = true }
/// ```
struct CalmFeatureHeader: View {
    let title: String
    var isOn: Binding<Bool>?
    var shortcut: [String]?
    /// Words after the caps in the pill (“to edit by voice”).
    var shortcutCaption: String?
    var onShortcutTap: (() -> Void)?

    init(
        _ title: String, isOn: Binding<Bool>? = nil, shortcut: [String]? = nil,
        shortcutCaption: String? = nil, onShortcutTap: (() -> Void)? = nil
    ) {
        self.title = title
        self.isOn = isOn
        self.shortcut = shortcut
        self.shortcutCaption = shortcutCaption
        self.onShortcutTap = onShortcutTap
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .calmType(.title)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let isOn {
                HStack(spacing: 10) {
                    Text(isOn.wrappedValue ? "On" : "Off").font(CalmFont.control).foregroundStyle(CalmColor.ink)
                    CalmSwitch(isOn: isOn)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
            }
            if let shortcut {
                if let onShortcutTap {
                    Button(action: onShortcutTap) { CalmShortcutPill(shortcut, caption: shortcutCaption) }
                        .buttonStyle(CalmPlainFocusStyle(radius: 10))
                        .focusEffectDisabled()
                        .accessibilityLabel(
                            shortcut.isEmpty ? (shortcutCaption ?? "Shortcut") : "Shortcut \(shortcut.joined(separator: " ")). Change"
                        )
                } else {
                    CalmShortcutPill(shortcut, caption: shortcutCaption)
                }
            }
        }
    }
}

/// A serif section title (New York 22), used once or twice per page.
struct CalmSectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).calmType(.sectionSerif).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Groups and panels

/// A group label (SF 14/600) 10 above its content.
///
/// ```swift
/// CalmGroup("Sound and recording") { CalmPanel { … } }
/// ```
struct CalmGroup<Content: View>: View {
    let label: String?
    let content: Content

    init(_ label: String?, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CalmMetrics.groupLabelGap) {
            if let label {
                Text(label)
                    .calmType(.groupLabel)
                    .padding(.leading, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
    }
}

/// A soft panel holding 2–5 setting rows with a 1 pt line between them,
/// inset 22. Never put a panel inside a panel.
///
/// ```swift
/// CalmPanel {
///     CalmToggleRow("Open at login", isOn: $openAtLogin)
///     CalmValueRow("Microphone", value: name) { showPicker = true }
/// }
/// ```
/// Rows hidden with `if` leave no stray divider.
struct CalmPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        _VariadicView.Tree(CalmDividedStack(inset: CalmMetrics.rowInset)) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
    }
}

extension View {
    /// The panel surface (panel fill, radius 14) for free-form panel content.
    func calmPanelBackground(radius: CGFloat = CalmMetrics.Radius.panel) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(CalmColor.panel))
    }

    /// An outlined content card: content fill, radius 14, 1 pt line2 or,
    /// when selected, a 2 pt ink ring (style and pick cards).
    func calmCard(selected: Bool = false, radius: CGFloat = CalmMetrics.Radius.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(shape.fill(CalmColor.content))
            .overlay(shape.strokeBorder(selected ? CalmColor.ink : CalmColor.line2, lineWidth: selected ? 2 : 1))
    }

    /// The “Create your own” card outline: 1.5 pt line2, no fill.
    func calmCreateCard(radius: CGFloat = CalmMetrics.Radius.panel) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(CalmColor.line2, lineWidth: 1.5))
    }

    /// A row whose parent setting is off: 50% opacity and not interactive,
    /// but still shown. Controls inside skip their own disabled dimming.
    func calmDisabledByParent(_ isDisabled: Bool) -> some View {
        self
            .disabled(isDisabled)
            .environment(\.calmDimsWhenDisabled, !isDisabled)
            .opacity(isDisabled ? 0.5 : 1)
    }
}

/// Stacks children with a divider between each pair.
private struct CalmDividedStack: _VariadicView_UnaryViewRoot {
    let inset: CGFloat

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child
                if child.id != lastID {
                    Rectangle().fill(CalmColor.line).frame(height: 1).padding(.horizontal, inset)
                }
            }
        }
    }
}

// MARK: - Setting rows

/// A setting row: title (SF 14/560) and optional description (SF 13
/// muted) on the left, controls on the right, vertically centred. Rows
/// sit inset 22 with 17 vertical padding.
///
/// ```swift
/// CalmRow("Longest recording") { CalmDropdown(selection: $limit, options: limits) }
/// CalmRow("Saved now", description: "1,284 dictations · 212 MB") {
///     Button("Clear history") { … }.calmButton(.quietDestructive)
/// }
/// CalmRow("Dictation key") {
///     CalmKeyedLine([.text("Hold"), .keys(["Right ⌥"]), .text("and speak.")])
/// } trailing: { Button("Change") { … }.calmButton() }
/// ```
struct CalmRow<Description: View, Trailing: View>: View {
    let title: String
    let description: Description
    let trailing: Trailing

    init(_ title: String, @ViewBuilder description: () -> Description, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: CalmMetrics.rowSpacing) {
            CalmRowLabel(title: title) { description }
            trailing
        }
        .padding(.vertical, CalmMetrics.rowVerticalPadding)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension CalmRow where Description == CalmRowDescription {
    init(_ title: String, description: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.init(title, description: { CalmRowDescription(text: description) }, trailing: trailing)
    }
}

extension CalmRow where Description == CalmRowDescription, Trailing == EmptyView {
    /// A read-only row with no control.
    init(_ title: String, description: String? = nil) {
        self.init(title, description: { CalmRowDescription(text: description) }, trailing: { EmptyView() })
    }
}

/// The plain-text description under a row title (nothing when nil).
struct CalmRowDescription: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text)
                .calmType(.description)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The title + description block of a row, filling the space left of the controls.
struct CalmRowLabel<Description: View>: View {
    let title: String
    let description: Description

    init(title: String, @ViewBuilder description: () -> Description) {
        self.title = title
        self.description = description()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).calmType(.rowTitle).fixedSize(horizontal: false, vertical: true)
            description
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Value + Change: the most common row. The button opens a dialog.
struct CalmValueRow: View {
    let title: String
    let value: String?
    var actionTitle: String = "Change"
    let action: () -> Void

    init(_ title: String, value: String?, actionTitle: String = "Change", action: @escaping () -> Void) {
        self.title = title
        self.value = value
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        CalmRow(title, description: value) {
            Button(actionTitle, action: action).calmButton(.secondary)
        }
    }
}

/// A switch row; the whole row is clickable.
struct CalmToggleRow: View {
    let title: String
    var description: String?
    @Binding var isOn: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: String, description: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        _isOn = isOn
    }

    var body: some View {
        CalmRow(title, description: description) {
            CalmSwitch(isOn: $isOn)
                .accessibilityLabel(title)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { isOn.toggle() }
        }
    }
}

/// Status + fix: a 28-point icon circle before the title. Warning rows
/// carry their fix on the right; the allowed state shows a teal tick and
/// “Allowed” in muted text.
///
/// ```swift
/// CalmStatusRow("Input Monitoring", description: "To notice the dictation key", tone: .warning) {
///     Button("Grant access") { … }.calmButton(.primary)
/// }
/// CalmStatusRow("Microphone", description: "To hear you", tone: .success) { CalmAllowedLabel() }
/// ```
struct CalmStatusRow<Trailing: View>: View {
    let title: String
    var description: String?
    var tone: CalmTone
    let trailing: Trailing

    init(_ title: String, description: String? = nil, tone: CalmTone, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.description = description
        self.tone = tone
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: CalmMetrics.rowSpacing) {
            CalmIconCircle(tone: tone)
            CalmRowLabel(title: title) { CalmRowDescription(text: description) }
            trailing
        }
        .padding(.vertical, CalmMetrics.rowVerticalPadding)
        .padding(.horizontal, CalmMetrics.rowInset)
    }
}

/// The muted “Allowed” text for a granted permission row.
struct CalmAllowedLabel: View {
    var text = "Allowed"

    var body: some View {
        Text(text).font(CalmFont.description).foregroundStyle(CalmColor.muted)
    }
}

/// One piece of a line that mixes words and key caps.
enum CalmKeyedPart: Hashable {
    case text(String)
    case keys([String])
}

/// A line of muted text with key caps in it (“Hold [Right ⌥] and speak.”).
///
/// ```swift
/// CalmKeyedLine([.text("Press"), .keys(["⌃", "⌥", "Space"]), .text("to start, again to stop")], spacing: 4)
/// ```
struct CalmKeyedLine: View {
    let parts: [CalmKeyedPart]
    var spacing: CGFloat = 6
    var capSize: CalmKeyCapSize = .regular
    var font: Font = CalmFont.description
    var color: Color = CalmColor.muted

    init(
        _ parts: [CalmKeyedPart], spacing: CGFloat = 6, capSize: CalmKeyCapSize = .regular,
        font: Font = CalmFont.description, color: Color = CalmColor.muted
    ) {
        self.parts = parts
        self.spacing = spacing
        self.capSize = capSize
        self.font = font
        self.color = color
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text): Text(text).font(font).foregroundStyle(color).fixedSize()
                case .keys(let caps): CalmKeyCombo(caps, size: capSize)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lists

/// A list: content fill, 1 pt line2 outline, radius 14, a 1 pt line between
/// items. Hovered rows tint to panel within the rounded shape.
///
/// ```swift
/// CalmList {
///     ForEach(entries) { entry in CalmListRow { … } actions: { … } }
/// }
/// ```
struct CalmList<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.list, style: .continuous)
        _VariadicView.Tree(CalmDividedStack(inset: 0)) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(CalmColor.content))
        .clipShape(shape)
        .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
    }
}

/// List row padding: regular 16 / 18 / 16 / 20 (feed), compact 14 / 14 /
/// 14 / 20 (dictionary, snippets).
enum CalmListRowPadding: Sendable {
    case regular
    case compact

    var insets: EdgeInsets {
        self == .regular ? CalmMetrics.listRowPadding : CalmMetrics.listCompactRowPadding
    }
}

/// A list item. With `alwaysShowsActions` the actions sit in their own
/// column. Otherwise they float over the row's top-right corner on hover
/// or while one of them has keyboard focus, so the text keeps the row's
/// full width and never jumps.
///
/// ```swift
/// CalmListRow {
///     CalmTimeColumn(time: "1:04 pm", app: "Slack")
///     Text(entry.text).calmType(.body)
/// } actions: {
///     Button { copy() } label: { CalmIcon(.copy, size: 16) }.calmIconButton().accessibilityLabel("Copy")
/// }
/// ```
struct CalmListRow<Content: View, Actions: View>: View {
    var padding: CalmListRowPadding = .regular
    var alignment: VerticalAlignment = .top
    /// Show the actions all the time (e.g. an edit pencil in short lists).
    var alwaysShowsActions = false
    let content: Content
    let actions: Actions

    @Environment(\.calmPreviewInteraction) private var forced
    @State private var hoveredForReal = false
    @State private var actionHasFocus = false

    private var isHovered: Bool { hoveredForReal || forced == .hover }

    init(
        padding: CalmListRowPadding = .regular, alignment: VerticalAlignment = .top,
        alwaysShowsActions: Bool = false,
        @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions
    ) {
        self.padding = padding
        self.alignment = alignment
        self.alwaysShowsActions = alwaysShowsActions
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        Group {
            if alwaysShowsActions {
                HStack(alignment: alignment, spacing: 16) {
                    content
                    HStack(spacing: 2) { actions }
                        .padding(.top, alignment == .top ? -5 : 0)
                }
                .padding(padding.insets)
            } else {
                HStack(alignment: alignment, spacing: 16) { content }
                    .padding(padding.insets)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: alignment == .top ? .topTrailing : .trailing) { floatingActions }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? CalmColor.panel : .clear)
        .contentShape(Rectangle())
        .onHover { hoveredForReal = $0 }
    }

    /// Hover actions on the row's own hover fill, with a short fade on
    /// their leading edge so the text they cover tucks under them.
    private var floatingActions: some View {
        let showsActions = isHovered || actionHasFocus
        let insets = padding.insets
        return HStack(spacing: 2) { actions }
            .padding(.leading, 4)
            .background(alignment: .leading) {
                HStack(spacing: 0) {
                    LinearGradient(colors: [CalmColor.panel.opacity(0), CalmColor.panel], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 20)
                    CalmColor.panel
                }
                .padding(.leading, -20)
            }
            .padding(.top, alignment == .top ? max(0, insets.top - 5) : 0)
            .padding(.trailing, max(0, insets.trailing - 6))
            // Not 0: SwiftUI drops fully transparent views from the
            // accessibility tree, which left VoiceOver no way to copy a
            // dictation or reach its menu. 0.001 is invisible.
            .opacity(showsActions ? 1 : 0.001)
            .allowsHitTesting(showsActions)
            .onPreferenceChange(CalmFocusPresenceKey.self) { actionHasFocus = $0 }
    }
}

extension CalmListRow where Actions == EmptyView {
    init(
        padding: CalmListRowPadding = .regular, alignment: VerticalAlignment = .top,
        @ViewBuilder content: () -> Content
    ) {
        self.init(padding: padding, alignment: alignment, content: content) { EmptyView() }
    }
}

/// Whether any Calm control in a subtree has keyboard focus. Calm button
/// styles publish it so a list row can reveal its hover actions.
struct CalmFocusPresenceKey: SwiftUI.PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The 70-point time / app column of a feed row (13 and 12, muted).
struct CalmTimeColumn: View {
    let time: String
    var app: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(time).font(CalmFont.listTime)
            if let app {
                // Two lines rather than “Brave Bro…”: the column is narrow.
                Text(app).font(CalmFont.listApp).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(CalmColor.muted)
        .padding(.top, 1)
        .frame(width: CalmMetrics.listTimeColumn, alignment: .leading)
    }
}

/// A caption-styled label (TODAY, SETTINGS): SF 11/650, +8%, uppercase, muted.
struct CalmCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).calmType(.caption).accessibilityAddTraits(.isHeader)
    }
}

/// A day caption 10 above its list (“TODAY”, “YESTERDAY”, “MON 12 OCT”).
struct CalmDaySection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CalmCaption(title).padding(.leading, 2)
            content
        }
    }

    /// The caption for a day: Today, Yesterday, then “Mon 12 Oct”.
    static func caption(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }
}

/// Empty state: 1.5 pt line2 outline, a 44-point icon tile, a 15/600
/// title and a 13 muted hint, centred.
///
/// ```swift
/// CalmEmptyState(icon: .mic, title: "No dictations yet") {
///     CalmKeyedLine([.text("Hold"), .keys(["Right ⌥"]), .text("and speak in any app.")], capSize: .inline)
/// }
/// ```
struct CalmEmptyState<Message: View>: View {
    let icon: CalmIconName
    let title: String
    let message: Message

    init(icon: CalmIconName, title: String, @ViewBuilder message: () -> Message) {
        self.icon = icon
        self.title = title
        self.message = message()
    }

    var body: some View {
        VStack(spacing: 10) {
            CalmIcon(icon, size: 20)
                .foregroundStyle(CalmColor.ink2)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CalmColor.panel))
            Text(title).font(CalmFont.emptyTitle).foregroundStyle(CalmColor.ink)
            message
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .calmCreateCard()
    }
}

extension CalmEmptyState where Message == Text {
    init(icon: CalmIconName, title: String, message: String) {
        self.init(icon: icon, title: title) { Text(message) }
    }
}

/// “No models match “whispr”. Clear search” under a search with no hits.
struct CalmNoResults: View {
    let message: String
    var clearTitle = "Clear search"
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(message).foregroundStyle(CalmColor.muted)
            Button(action: onClear) {
                Text(clearTitle).underline().fontWeight(.medium).foregroundStyle(CalmColor.ink)
            }
            .buttonStyle(CalmPlainFocusStyle(radius: 4))
            .focusEffectDisabled()
        }
        .font(CalmFont.control)
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Feature card

/// The dark feature (hero) card, once per feature page: hero fill, r16,
/// padding 30 / 34, gap 14, New York 32 title, 14.5 body at 86%, and the
/// seven faint wave bars on the right. With a `dismissKey` it shows a
/// close button and stays hidden for good once dismissed.
///
/// ```swift
/// CalmFeatureCard(dismissKey: "dictionary",
///                 title: Text("VocaMac spells the way ") + Text("you").italic() + Text(" do."),
///                 message: "Add names, product words and jargon so they come out right every time.") {
///     Button("Add a word") { … }.calmButton(.heroPrimary)
///     Button { … } label: { CalmHeroChipLabel("Kubernetes") }.calmButton(.heroChip)
/// }
/// ```
/// Read `CalmFeatureCard.isDismissed(_:)` (or `@AppStorage(CalmFeatureCard.storageKey(_:))`)
/// to show a fallback when the card is gone.
struct CalmFeatureCard<Actions: View>: View {
    let title: Text
    let message: String?
    let actions: Actions
    /// The decorative bars on the right, as each page draws them.
    let waveHeights: [CGFloat]
    private let dismissKey: String?

    @AppStorage private var isDismissed: Bool
    @State private var width: CGFloat = 900

    private var isCompact: Bool { width < CalmMetrics.heroCompactWidth }

    /// Width the wave bars take at the right edge (7-point bars 7 apart,
    /// 28 from the edge), less the card's own padding, plus a little air.
    private var waveReserve: CGFloat {
        let count = CGFloat(waveHeights.count)
        let bars = count * 7 + max(count - 1, 0) * 7 + 28
        let padding = isCompact ? CalmMetrics.heroCompactPadding.trailing : CalmMetrics.heroPadding.trailing
        return max(bars - padding + 16, 0)
    }

    /// The bars most pages use.
    static var defaultWave: [CGFloat] { [40, 86, 130, 64, 150, 96, 52] }

    init(
        dismissKey: String?, title: Text, message: String?,
        waveHeights: [CGFloat] = Self.defaultWave, @ViewBuilder actions: () -> Actions
    ) {
        self.dismissKey = dismissKey
        self.title = title
        self.message = message
        self.waveHeights = waveHeights
        self.actions = actions()
        _isDismissed = AppStorage(wrappedValue: false, Self.storageKey(dismissKey ?? "always"))
    }

    /// The `UserDefaults` key that remembers a dismissed card.
    static func storageKey(_ dismissKey: String) -> String { "calm.featureCard.dismissed.\(dismissKey)" }

    /// Whether the card for `dismissKey` was dismissed.
    static func isDismissed(_ dismissKey: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey(dismissKey))
    }

    var body: some View {
        if !(dismissKey != nil && isDismissed) {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: isCompact ? CalmMetrics.heroCompactGap : CalmMetrics.heroGap) {
            title
                .font(isCompact ? CalmFont.featureTitleCompact : CalmFont.featureTitle)
                .tracking(-0.48)
                .foregroundStyle(CalmColor.heroText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, dismissKey == nil ? 0 : 30)
                .accessibilityAddTraits(.isHeader)
            if let message {
                // 14.5 on a 1.5 line: SwiftUI adds the extra only between
                // lines, so the half-leading above and below is padding.
                Text(message)
                    .font(CalmFont.heroBody)
                    .lineSpacing(4.5)
                    .padding(.vertical, 2.2)
                    .foregroundStyle(CalmColor.heroText.opacity(0.86))
                    .frame(maxWidth: 560, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Kept clear of the wave bars: wrapping chips (Commands'
            // examples, suggested words) ran underneath them.
            HStack(spacing: 8) { actions }
                .padding(.trailing, waveReserve)
        }
        .padding(isCompact ? CalmMetrics.heroCompactPadding : CalmMetrics.heroPadding)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            if newWidth > 0, abs(newWidth - width) > 0.5 { width = newWidth }
        }
        .background(alignment: .trailing) {
            HStack(spacing: 7) {
                ForEach(Array(waveHeights.enumerated()), id: \.offset) { _, height in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(CalmColor.heroText.opacity(0.09))
                        .frame(width: 7, height: height)
                }
            }
            .padding(.trailing, 28)
            .accessibilityHidden(true)
        }
        .background(CalmColor.hero)
        .clipShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.hero, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if dismissKey != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isDismissed = true }
                } label: {
                    CalmIcon(.close, size: 14, weight: 2)
                }
                .calmIconButton(size: 30, onHero: true)
                .padding(14)
                .accessibilityLabel("Dismiss")
            }
        }
    }
}

extension CalmFeatureCard where Actions == EmptyView {
    init(dismissKey: String?, title: Text, message: String?, waveHeights: [CGFloat] = Self.defaultWave) {
        self.init(dismissKey: dismissKey, title: title, message: message, waveHeights: waveHeights) { EmptyView() }
    }
}

/// A feature-card chip label: the word with a 13-point plus after it.
struct CalmHeroChipLabel: View {
    let title: String
    var icon: CalmIconName? = .plus

    init(_ title: String, icon: CalmIconName? = .plus) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            if let icon { CalmIcon(icon, size: 13, weight: 2) }
        }
    }
}

// MARK: - Small cards

/// Stat card: New York 30 number, 13.5/560 label, 12.5 muted note, on panel.
struct CalmStatCard: View {
    let value: String
    let label: String
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(CalmFont.statNumber).foregroundStyle(CalmColor.ink).monospacedDigit()
            Text(label).font(CalmFont.statLabel).foregroundStyle(CalmColor.ink)
            if let note {
                Text(note).font(CalmFont.note).foregroundStyle(CalmColor.muted)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
        .accessibilityElement(children: .combine)
    }
}

/// A big serif number with its unit (“7,019 words”): New York 28 + SF 14 ink2.
struct CalmBigNumber: View {
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(CalmFont.bigNumber).foregroundStyle(CalmColor.ink).monospacedDigit()
            Text(unit).font(CalmFont.bigNumberUnit).foregroundStyle(CalmColor.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A dismissable tip on panel: 14/600 title, 13 muted message, a primary
/// action, and a 28-point close button. Dismissal is remembered under
/// `dismissKey`.
///
/// ```swift
/// CalmTipCard(dismissKey: "home.editByVoice", title: "Edit text by voice", actionTitle: "Try it", action: { … }) {
///     CalmKeyedLine([.text("Select text, press"), .keys(["⌃", "⌥", "E"])], capSize: .inline)
///     Text("and say what to change.")
/// }
/// ```
struct CalmTipCard<Message: View>: View {
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
    let message: Message

    @AppStorage private var isDismissed: Bool

    init(
        dismissKey: String, title: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
        @ViewBuilder message: () -> Message
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
        self.message = message()
        _isDismissed = AppStorage(wrappedValue: false, Self.storageKey(dismissKey))
    }

    /// The `UserDefaults` key that remembers a dismissed tip.
    static func storageKey(_ dismissKey: String) -> String { "calm.tip.dismissed.\(dismissKey)" }

    var body: some View {
        if !isDismissed {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(CalmFont.tipTitle).foregroundStyle(CalmColor.ink).padding(.trailing, 24)
                VStack(alignment: .leading, spacing: 2) { message }
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
                    .lineSpacing(3)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).calmButton(.primary).padding(.top, 4)
                }
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .calmPanelBackground()
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isDismissed = true }
                } label: {
                    CalmIcon(.close, size: 14)
                }
                .calmIconButton(size: 28)
                .padding(8)
                .accessibilityLabel("Dismiss tip")
            }
        }
    }
}

extension CalmTipCard where Message == Text {
    init(dismissKey: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(dismissKey: dismissKey, title: title, actionTitle: actionTitle, action: action) { Text(message) }
    }
}

// MARK: - Streak

/// One day of the streak week.
struct CalmStreakDay: Hashable, Identifiable {
    /// The weekday letter under the dot (F, S, S, M, …).
    let letter: String
    /// The day's name for VoiceOver (“Friday”, “Today”).
    let name: String
    let isDone: Bool
    var isToday = false
    var id: String { name }
}

/// A streak day dot: 22, accent with an 11-point tick when done, a 1.5 pt
/// line2 ring when missed; today adds a 1.5 pt accent ring 2 outside.
struct CalmStreakDot: View {
    let isDone: Bool
    var isToday = false

    var body: some View {
        ZStack {
            if isDone {
                Circle().fill(CalmColor.accent)
                CalmIcon(.check, size: 11, weight: 2.8).foregroundStyle(CalmColor.content)
            } else {
                Circle().strokeBorder(CalmColor.line2, lineWidth: 1.5)
            }
        }
        .frame(width: 22, height: 22)
        .overlay {
            if isToday {
                Circle().strokeBorder(CalmColor.accent, lineWidth: 1.5).padding(-3.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The last seven days as dots with weekday letters (10.5/600 muted, 6 below).
struct CalmStreakWeek: View {
    let days: [CalmStreakDay]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                if index > 0 { Spacer(minLength: 0) }
                VStack(spacing: 6) {
                    CalmStreakDot(isDone: day.isDone, isToday: day.isToday)
                    Text(day.letter)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(CalmColor.muted)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.name): \(day.isDone ? "dictated" : "no dictation")")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Last 7 days")
    }
}

// MARK: - Heatmap

/// The heatmap scale: words dictated that day → level 0…4.
enum CalmHeatLevel {
    /// 0 words → 0, 1–219 → 1, 220–479 → 2, 480–799 → 3, 800+ → 4.
    static func level(forWords words: Int) -> Int {
        switch words {
        case ..<1: return 0
        case 1..<220: return 1
        case 220..<480: return 2
        case 480..<800: return 3
        default: return 4
        }
    }
}

/// How big the heatmap's cells are and how many weeks it shows, so the
/// grid always fits its panel: 12-point cells 3 apart where there's room,
/// shrinking to 8-point cells 2 apart, then dropping the oldest weeks.
struct CalmHeatmapFit: Equatable {
    var cell: CGFloat
    var gap: CGFloat
    /// The most recent weeks to show (at most the weeks given).
    var weeks: Int

    static let maxCell: CGFloat = 12
    static let minCell: CGFloat = 8
    /// Cells smaller than this sit 2 apart instead of 3.
    static let tightCell: CGFloat = 10

    /// The grid's width for this fit.
    var width: CGFloat { CGFloat(weeks) * cell + CGFloat(max(0, weeks - 1)) * gap }

    /// Fits `weekCount` columns into `width` points.
    static func fit(width: CGFloat, weekCount: Int) -> CalmHeatmapFit {
        let weekCount = max(1, weekCount)
        func cell(gap: CGFloat, weeks: Int) -> CGFloat {
            let room = width - CGFloat(weeks - 1) * gap
            return (room / CGFloat(weeks) * 2).rounded(.down) / 2
        }
        let loose = cell(gap: 3, weeks: weekCount)
        if loose >= tightCell {
            return CalmHeatmapFit(cell: min(maxCell, loose), gap: 3, weeks: weekCount)
        }
        let tight = cell(gap: 2, weeks: weekCount)
        if tight >= minCell {
            return CalmHeatmapFit(cell: min(tightCell, tight), gap: 2, weeks: weekCount)
        }
        // Too narrow for a year: keep the smallest cell, show fewer weeks.
        let weeks = Int(((width + 2) / (minCell + 2)).rounded(.down))
        return CalmHeatmapFit(cell: minCell, gap: 2, weeks: min(weekCount, max(1, weeks)))
    }
}

/// One heatmap day: 12, r3, coloured by level; selected adds a 1.5 pt
/// content gap and a 1.5 pt ink ring. Cells sit 3 apart, 53 weeks × 7.
struct CalmHeatCell: View {
    let level: Int
    var size: CGFloat = 12
    var isSelected = false

    var body: some View {
        RoundedRectangle(cornerRadius: 3 * size / 12, style: .continuous)
            .fill(CalmColor.heat(level))
            .frame(width: size, height: size)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3 * size / 12 + 3, style: .continuous)
                        .strokeBorder(CalmColor.ink, lineWidth: 1.5)
                        .padding(-3)
                    RoundedRectangle(cornerRadius: 3 * size / 12 + 1.5, style: .continuous)
                        .strokeBorder(CalmColor.content, lineWidth: 1.5)
                        .padding(-1.5)
                }
            }
    }
}

/// “Less ▢▢▢▢▢ More” under the heatmap (SF 11 muted).
struct CalmHeatLegend: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Less").padding(.trailing, 4)
            ForEach(0..<5, id: \.self) { CalmHeatCell(level: $0) }
            Text("More").padding(.leading, 4)
        }
        .font(.system(size: 11))
        .foregroundStyle(CalmColor.muted)
        .accessibilityHidden(true)
    }
}

// MARK: - Cached results

/// Remembers one computed value until its inputs change, so a page can
/// read an expensive result (stats summary, heatmap, history search) in
/// `body` without recomputing it on every redraw. Hold it in `@State`;
/// it is not observed, so reading it never triggers a redraw.
@MainActor
final class CalmMemo<Key: Equatable, Value> {
    private var cached: (key: Key, value: Value)?

    /// The value for `key`, computed only when `key` differs from last time.
    func value(for key: Key, compute: () -> Value) -> Value {
        if let cached, cached.key == key { return cached.value }
        let value = compute()
        cached = (key, value)
        return value
    }
}
