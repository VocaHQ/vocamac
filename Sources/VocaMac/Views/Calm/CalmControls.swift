// CalmControls.swift
// VocaMac
//
// Every control on the v3 Controls board, in all its states: default,
// hover, pressed (92% brightness, 115% in dark), keyboard focus (3 pt focus
// ring outside the shape) and disabled (40% opacity).

import AppKit
import SwiftUI

// MARK: - Shared state helpers

extension View {
    /// Draws the 3 pt Calm focus ring outside a rounded shape.
    ///
    /// - Parameters:
    ///   - isFocused: Whether to show the ring.
    ///   - radius: The corner radius of the shape the ring hugs.
    func calmFocusRing(_ isFocused: Bool, radius: CGFloat) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius + CalmMetrics.focusRingWidth, style: .continuous)
                    .strokeBorder(CalmColor.focus, lineWidth: CalmMetrics.focusRingWidth)
                    .padding(-CalmMetrics.focusRingWidth)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The pressed look: 92% brightness in light, 115% in dark.
    func calmPressed(_ isPressed: Bool, scheme: ColorScheme) -> some View {
        colorMultiply(isPressed && scheme != .dark ? Color(white: 0.92) : .white)
            .brightness(isPressed && scheme == .dark ? 0.1 : 0)
    }
}

/// Whether Calm controls draw their own 40% disabled look. A row disabled
/// by its parent (`calmDisabledByParent`) dims as a whole instead.
private struct CalmDimsWhenDisabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// See `View.calmDisabledByParent(_:)`.
    var calmDimsWhenDisabled: Bool {
        get { self[CalmDimsWhenDisabledKey.self] }
        set { self[CalmDimsWhenDisabledKey.self] = newValue }
    }
}

private struct CalmDisabledDimming: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.calmDimsWhenDisabled) private var dims

    func body(content: Content) -> some View {
        content.opacity(isEnabled || !dims ? 1 : 0.4)
    }
}

extension View {
    /// The disabled look: 40% opacity, unless the whole row already dims.
    func calmDisabledDimming() -> some View {
        modifier(CalmDisabledDimming())
    }
}

// MARK: - Forced states (previews)

/// An interaction state to draw without the pointer or keyboard, for
/// previews and the component gallery. Never set in the app.
enum CalmPreviewInteraction: Sendable {
    case hover
    case pressed
    case focus
}

private struct CalmPreviewInteractionKey: EnvironmentKey {
    static let defaultValue: CalmPreviewInteraction? = nil
}

extension EnvironmentValues {
    /// Forces Calm controls to draw hovered, pressed or focused.
    var calmPreviewInteraction: CalmPreviewInteraction? {
        get { self[CalmPreviewInteractionKey.self] }
        set { self[CalmPreviewInteractionKey.self] = newValue }
    }
}

// MARK: - Buttons

/// What a Calm button means. One primary button per view at most; row
/// actions such as “Change” are secondary.
enum CalmButtonKind: Sendable {
    /// Ink fill, onPrimary text; hover priHover.
    case primary
    /// panel2 fill, ink text; hover line2.
    case secondary
    /// Amber fill, content text. Only inside confirmation dialogs.
    case destructive
    /// Secondary with amber text, for rows like Reset.
    case quietDestructive
    /// No fill until hovered, ink text (“Use default”, “Skip this version”).
    case quiet
    /// No fill until hovered, amber text (Delete at the far left of a dialog).
    case quietAmber
    /// The feature card's main button: #F3F6F1 fill, hero text.
    case heroPrimary
    /// A feature-card chip: white 14% fill, hero text.
    case heroChip
}

/// Calm button sizes: regular h34 r9 px16 SF 13.5; small h28 r8 px12 SF 12.5.
enum CalmButtonSize: Sendable {
    case regular
    case small
}

/// The Calm text button style.
///
/// ```swift
/// Button("Change") { … }.calmButton(.secondary)
/// Button { … } label: { CalmButtonLabel("Add new", icon: .plus) }.calmButton(.primary)
/// Button("Grant access") { … }.calmButton(.primary, size: .small)
/// ```
/// Prefer `calmButton(_:size:)`: it also turns off the system focus ring
/// so only the Calm ring shows.
struct CalmButtonStyle: ButtonStyle {
    var kind: CalmButtonKind = .secondary
    var size: CalmButtonSize = .regular
    /// Stretch to the available width (status card, dialog footers).
    var fillsWidth = false

    func makeBody(configuration: Configuration) -> some View {
        CalmButtonBody(configuration: configuration, kind: kind, size: size, fillsWidth: fillsWidth)
    }
}

private struct CalmButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: CalmButtonKind
    let size: CalmButtonSize
    let fillsWidth: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredForReal = false

    private var height: CGFloat { size == .small ? CalmMetrics.smallButtonHeight : CalmMetrics.buttonHeight }
    private var radius: CGFloat { size == .small ? CalmMetrics.Radius.smallButton : CalmMetrics.Radius.button }
    private var padding: CGFloat {
        switch kind {
        case .heroChip: return 14
        default: return size == .small ? CalmMetrics.smallButtonPadding : CalmMetrics.buttonPadding
        }
    }
    private var font: Font {
        if kind == .heroPrimary { return CalmFont.heroButton }
        return size == .small ? CalmFont.buttonSmall : CalmFont.button
    }

    private var fill: Color {
        let hovered = isHovered && isEnabled
        switch kind {
        case .primary: return hovered ? CalmColor.primaryHover : CalmColor.primary
        case .secondary, .quietDestructive: return hovered ? CalmColor.line2 : CalmColor.panel2
        case .destructive: return CalmColor.amber
        case .quiet, .quietAmber: return hovered ? CalmColor.line2 : .clear
        case .heroPrimary: return CalmColor.heroText.opacity(hovered ? 0.9 : 1)
        case .heroChip: return CalmColor.heroText.opacity(hovered ? 0.2 : 0.14)
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: return CalmColor.onPrimary
        case .secondary, .quiet: return CalmColor.ink
        case .destructive: return CalmColor.content
        case .quietDestructive, .quietAmber: return CalmColor.amber
        case .heroPrimary: return Color(nsColor: CalmNSColor.rgb(0x123F36))
        case .heroChip: return CalmColor.heroText
        }
    }

    private var isHovered: Bool { hoveredForReal || forced == .hover }
    private var isFocused: Bool { focusedForReal || forced == .focus }
    private var isPressed: Bool { configuration.isPressed || forced == .pressed }

    var body: some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, padding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .calmPressed(isPressed, scheme: scheme)
            .calmFocusRing(isFocused && isEnabled, radius: radius)
            .preference(key: CalmFocusPresenceKey.self, value: isFocused)
            .calmDisabledDimming()
            .onHover { hoveredForReal = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A button label with a leading icon: icon 14 at stroke 2, gap 7.
struct CalmButtonLabel: View {
    let title: String
    let icon: CalmIconName

    init(_ title: String, icon: CalmIconName) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 7) {
            CalmIcon(icon, size: 14, weight: 2)
            Text(title)
        }
    }
}

/// 32 × 32 icon-only button: muted icon, ink with a panel2 fill on hover.
/// Always give the button an accessibility label.
///
/// ```swift
/// Button { … } label: { CalmIcon(.search, size: 17) }
///     .calmIconButton()
///     .accessibilityLabel("Search")
/// ```
struct CalmIconButtonStyle: ButtonStyle {
    var size: CGFloat = CalmMetrics.iconButtonSize
    /// Use the hero colours (the feature card's round close button).
    var onHero = false

    func makeBody(configuration: Configuration) -> some View {
        CalmIconButtonBody(configuration: configuration, size: size, onHero: onHero)
    }
}

private struct CalmIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    let onHero: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredForReal = false

    private var radius: CGFloat { onHero ? size / 2 : CalmMetrics.Radius.iconButton * size / CalmMetrics.iconButtonSize }

    private var isHovered: Bool { hoveredForReal || forced == .hover }
    private var isFocused: Bool { focusedForReal || forced == .focus }
    private var isPressed: Bool { configuration.isPressed || forced == .pressed }

    var body: some View {
        let hovered = isHovered && isEnabled
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .foregroundStyle(onHero ? CalmColor.heroText : (hovered ? CalmColor.ink : CalmColor.muted))
            .frame(width: size, height: size)
            .background(shape.fill(onHero
                ? CalmColor.heroText.opacity(hovered ? 0.2 : 0.14)
                : (hovered ? CalmColor.panel2 : .clear)))
            .contentShape(shape)
            .calmPressed(isPressed, scheme: scheme)
            .calmFocusRing(isFocused && isEnabled, radius: radius)
            .preference(key: CalmFocusPresenceKey.self, value: isFocused)
            .calmDisabledDimming()
            .onHover { hoveredForReal = $0 }
    }
}

/// The label of an icon-only `Menu` (the ⋯ menus). `CalmIcon` is hidden
/// from VoiceOver, and a `Menu` whose label is all hidden drops out of the
/// accessibility tree, `.accessibilityLabel` or not. The title keeps it
/// there and names it.
///
/// ```swift
/// Menu { … } label: { CalmIconMenuLabel("Share and more", icon: .more, size: 18, weight: 2.4) }
/// ```
struct CalmIconMenuLabel: View {
    let title: String
    let icon: CalmIconName
    var size: CGFloat = 16
    var weight: CGFloat = 1.6

    init(_ title: String, icon: CalmIconName, size: CGFloat = 16, weight: CGFloat = 1.6) {
        self.title = title
        self.icon = icon
        self.size = size
        self.weight = weight
    }

    var body: some View {
        // A container that is itself an accessibility element: the hidden
        // icon inside contributes nothing, the container carries the name.
        ZStack { CalmIcon(icon, size: size, weight: weight) }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// Text link: SF 13 / 550, ink, no underline, accent on hover. Add the
/// 13-point chevron when it navigates.
///
/// ```swift
/// Button("See your year") { … }.calmLink(chevron: true)
/// ```
struct CalmLinkButtonStyle: ButtonStyle {
    var chevron = false
    /// Muted text (back links, “Change languages”).
    var muted = false
    var font: Font = CalmFont.link

    func makeBody(configuration: Configuration) -> some View {
        CalmLinkBody(configuration: configuration, chevron: chevron, muted: muted, font: font)
    }
}

private struct CalmLinkBody: View {
    let configuration: ButtonStyleConfiguration
    let chevron: Bool
    let muted: Bool
    let font: Font

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.colorScheme) private var scheme
    @State private var hoveredForReal = false

    private var isHovered: Bool { hoveredForReal || forced == .hover }
    private var isFocused: Bool { focusedForReal || forced == .focus }
    private var isPressed: Bool { configuration.isPressed || forced == .pressed }

    var body: some View {
        HStack(spacing: 4) {
            configuration.label
            if chevron { CalmIcon(.chevRight, size: 13) }
        }
        .font(font)
        .foregroundStyle(isHovered && isEnabled ? CalmColor.accent : (muted ? CalmColor.muted : CalmColor.ink))
        .contentShape(Rectangle())
        .calmPressed(isPressed, scheme: scheme)
        .calmFocusRing(isFocused && isEnabled, radius: 4)
        .preference(key: CalmFocusPresenceKey.self, value: isFocused)
        .calmDisabledDimming()
        .onHover { hoveredForReal = $0 }
    }
}

extension View {
    /// Styles a button as a Calm text button and hides the system focus ring.
    func calmButton(_ kind: CalmButtonKind = .secondary, size: CalmButtonSize = .regular, fillsWidth: Bool = false) -> some View {
        buttonStyle(CalmButtonStyle(kind: kind, size: size, fillsWidth: fillsWidth)).focusEffectDisabled()
    }

    /// Styles a button as a 32-point (or `size`) Calm icon button.
    func calmIconButton(size: CGFloat = CalmMetrics.iconButtonSize, onHero: Bool = false) -> some View {
        buttonStyle(CalmIconButtonStyle(size: size, onHero: onHero)).focusEffectDisabled()
    }

    /// Styles a button as a Calm text link.
    func calmLink(chevron: Bool = false, muted: Bool = false, font: Font = CalmFont.link) -> some View {
        buttonStyle(CalmLinkButtonStyle(chevron: chevron, muted: muted, font: font)).focusEffectDisabled()
    }
}

// MARK: - Switch

/// The Calm switch: 40 × 24 track, padding 3, knob 18 sliding 150 ms.
/// Track ink when on, `off` when off. Shows the label to the left when it
/// is not hidden.
///
/// ```swift
/// Toggle("Open at login", isOn: $on).toggleStyle(CalmSwitchToggleStyle()).labelsHidden()
/// ```
/// In a panel, use `CalmToggleRow`, which makes the whole row clickable.
struct CalmSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.label
            CalmSwitch(isOn: configuration.$isOn)
        }
    }
}

/// The bare switch control; prefer `Toggle` with `CalmSwitchToggleStyle`.
struct CalmSwitch: View {
    @Binding var isOn: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Only the track animates (`CalmSwitchTrack`). Toggling inside
        // `withAnimation` animated everything the setting changed across
        // the whole window, which made every switch feel slow.
        Button {
            isOn.toggle()
        } label: {
            EmptyView()
        }
        .buttonStyle(CalmSwitchTrackStyle(isOn: isOn, animation: reduceMotion ? nil : .easeOut(duration: 0.15)))
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle("", isOn: $isOn)
        }
    }
}

private struct CalmSwitchTrackStyle: ButtonStyle {
    let isOn: Bool
    let animation: Animation?

    func makeBody(configuration: Configuration) -> some View {
        CalmSwitchTrack(isOn: isOn, isPressed: configuration.isPressed, animation: animation)
    }
}

private struct CalmSwitchTrack: View {
    let isOn: Bool
    let isPressed: Bool
    let animation: Animation?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.colorScheme) private var scheme

    private var isFocused: Bool { focusedForReal || forced == .focus }

    var body: some View {
        let size = CalmMetrics.switchSize
        // Off, a 1 pt outline drawn as a capsule behind an inset one: a
        // stroked capsule left stray marks at its ends.
        Capsule()
            .fill(isOn ? CalmColor.ink : CalmColor.offBorder)
            .overlay {
                if !isOn { Capsule().fill(CalmColor.off).padding(1) }
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(isOn ? CalmColor.knobOn : CalmColor.knobOff)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                    .frame(width: CalmMetrics.switchKnob, height: CalmMetrics.switchKnob)
                    .padding(3)
            }
            .animation(animation, value: isOn)
            .contentShape(Capsule())
            .calmPressed(isPressed, scheme: scheme)
            .calmFocusRing(isFocused && isEnabled, radius: size.height / 2)
            .calmDisabledDimming()
    }
}

// MARK: - Segmented control

/// One option of a segmented control, tab bar or dropdown.
struct CalmOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

/// Segmented control for 2–4 short, equal choices. Track panel2 r9 p3;
/// options h28 px12 r7 SF 13/550 muted; the selected one sits on content
/// with ink text and a soft shadow. Arrow keys move the choice while the
/// control has keyboard focus.
///
/// ```swift
/// CalmSegmentedControl(selection: $mode, options: [
///     CalmOption(.mine, "My languages"), CalmOption(.any, "Any"),
/// ])
/// ```
struct CalmSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [CalmOption<Value>]
    var accessibilityLabel: String = ""

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.calmPreviewInteraction) private var forced
    @FocusState private var hasFocus: Bool
    @State private var hovered: Value?

    private var isFocused: Bool { hasFocus || forced == .focus }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                optionView(option)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous).fill(CalmColor.panel2))
        // Like a button: a keyboard stop only with keyboard navigation on.
        .focusable(isEnabled, interactions: .activate)
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .calmFocusRing(isFocused && isEnabled, radius: CalmMetrics.Radius.button)
        .calmDisabledDimming()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func optionView(_ option: CalmOption<Value>) -> some View {
        let isSelected = option.value == selection
        return Text(option.title)
            .font(CalmFont.segment)
            .lineLimit(1)
            .foregroundStyle(isSelected || hovered == option.value ? CalmColor.ink : CalmColor.muted)
            .padding(.horizontal, 12)
            .frame(height: CalmMetrics.segmentOptionHeight)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: CalmMetrics.Radius.segmentOption, style: .continuous)
                        .fill(CalmColor.content)
                        .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { selection = option.value } }
            .onHover { hovered = $0 ? option.value : (hovered == option.value ? nil : hovered) }
            .accessibilityElement()
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { selection = option.value }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.value == selection }) else { return .ignored }
        let next = index + step
        guard options.indices.contains(next) else { return .handled }
        selection = options[next].value
        return .handled
    }
}

// MARK: - Underline tabs

/// Underline tabs switch the view on the same page. SF 14; the selected tab
/// is ink 600 with a 2 pt ink underline; others muted (ink on hover); 28
/// apart; a 1 pt line runs under the whole row. An optional trailing view
/// sits at the right end of the row (e.g. a compact dropdown).
///
/// ```swift
/// CalmTabs(selection: $tab, tabs: [CalmOption(.all, "All"), CalmOption(.words, "Words")])
/// CalmTabs(selection: $tab, tabs: tabs) { CalmDropdown(…) }
/// ```
struct CalmTabs<Value: Hashable, Trailing: View>: View {
    @Binding var selection: Value
    let tabs: [CalmOption<Value>]
    let trailing: Trailing

    init(selection: Binding<Value>, tabs: [CalmOption<Value>], @ViewBuilder trailing: () -> Trailing) {
        _selection = selection
        self.tabs = tabs
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            ForEach(tabs) { tab in
                CalmTabButton(title: tab.title, isSelected: tab.value == selection) { selection = tab.value }
            }
            Spacer(minLength: 0)
            trailing.padding(.bottom, 6)
        }
        .background(alignment: .bottom) {
            Rectangle().fill(CalmColor.line).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

extension CalmTabs where Trailing == EmptyView {
    init(selection: Binding<Value>, tabs: [CalmOption<Value>]) {
        self.init(selection: selection, tabs: tabs) { EmptyView() }
    }
}

private struct CalmTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.calmPreviewInteraction) private var forced
    @State private var hoveredForReal = false

    private var isHovered: Bool { hoveredForReal || forced == .hover }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isSelected ? CalmFont.tabSelected : CalmFont.tab)
                .foregroundStyle(isSelected || isHovered ? CalmColor.ink : CalmColor.muted)
                .padding(.bottom, 11)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(isSelected ? CalmColor.ink : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(CalmPlainFocusStyle(radius: 4))
        .focusEffectDisabled()
        .onHover { hoveredForReal = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A plain button that only adds the Calm focus ring and pressed look.
struct CalmPlainFocusStyle: ButtonStyle {
    var radius: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        CalmPlainFocusBody(configuration: configuration, radius: radius)
    }
}

private struct CalmPlainFocusBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.colorScheme) private var scheme

    private var isFocused: Bool { focusedForReal || forced == .focus }
    private var isPressed: Bool { configuration.isPressed || forced == .pressed }

    var body: some View {
        configuration.label
            .calmPressed(isPressed, scheme: scheme)
            .calmFocusRing(isFocused && isEnabled, radius: radius)
            .preference(key: CalmFocusPresenceKey.self, value: isFocused)
            .calmDisabledDimming()
    }
}

// MARK: - Dropdown

/// A dropdown that opens a native menu: h34 r9 on content with a 1 pt
/// line2 outline (muted on hover, ink + focus ring when focused) and a
/// muted 14-point chevron. The menu shows a check on the chosen item.
///
/// ```swift
/// CalmDropdown(selection: $days, options: [CalmOption(7, "7 days"), CalmOption(30, "30 days")])
/// CalmDropdown(title: "5 minutes") { Button("1 minute") { … }; Divider(); … }
/// ```
struct CalmDropdown<MenuContent: View>: View {
    let title: String
    let menuContent: MenuContent

    /// A dropdown with any menu content under a fixed title.
    init(title: String, @ViewBuilder content: () -> MenuContent) {
        self.title = title
        self.menuContent = content()
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            Text(title)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmDropdownButtonStyle())
        .focusEffectDisabled()
        .fixedSize()
    }
}

extension CalmDropdown {
    /// A dropdown choosing one of `options`; the menu checks the current one.
    init<Value: Hashable>(
        selection: Binding<Value>, options: [CalmOption<Value>]
    ) where MenuContent == CalmDropdownPicker<Value> {
        self.title = options.first { $0.value == selection.wrappedValue }?.title ?? ""
        self.menuContent = CalmDropdownPicker(selection: selection, options: options)
    }
}

/// The inline picker inside a `CalmDropdown` menu.
struct CalmDropdownPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [CalmOption<Value>]

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.value)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// The look of a dropdown's closed button, usable on any `Menu`.
struct CalmDropdownButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalmDropdownBody(configuration: configuration)
    }
}

private struct CalmDropdownBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var focusedForReal
    @Environment(\.calmPreviewInteraction) private var forced
    @State private var hoveredForReal = false

    private var isHovered: Bool { hoveredForReal || forced == .hover }
    private var isFocused: Bool { focusedForReal || forced == .focus }
    private var isPressed: Bool { configuration.isPressed || forced == .pressed }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
        let outline = isFocused ? CalmColor.ink : (isHovered && isEnabled ? CalmColor.muted : CalmColor.line2)
        HStack(spacing: 10) {
            configuration.label
                .font(CalmFont.control)
                .foregroundStyle(CalmColor.ink)
                .lineLimit(1)
            CalmIcon(.chevDown, size: 14)
                .foregroundStyle(CalmColor.muted)
        }
        .padding(.leading, 14)
        .padding(.trailing, 11)
        .frame(height: CalmMetrics.buttonHeight)
        .background(shape.fill(CalmColor.content))
        .overlay(shape.strokeBorder(outline, lineWidth: 1))
        .contentShape(shape)
        .calmFieldFocusRing(isFocused && isEnabled, radius: CalmMetrics.Radius.button)
        .calmDisabledDimming()
        .onHover { hoveredForReal = $0 }
    }
}

extension View {
    /// The 4 pt focus halo text fields and dropdowns use (outside a 1 pt ink outline).
    func calmFieldFocusRing(_ isFocused: Bool, radius: CGFloat) -> some View {
        overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: radius + 4, style: .continuous)
                    .strokeBorder(CalmColor.focus, lineWidth: 3)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Text fields

/// A labelled single-line text field: label SF 13/560 above, field h36 r9
/// on content with a 1 pt line2 outline. Focus: 1 pt ink + 4 pt focus ring.
/// Error: 1.5 pt amber and a 12.5 amber message below.
///
/// ```swift
/// CalmTextField("Word", text: $word, prompt: "e.g. Kubernetes", error: duplicateMessage)
/// ```
struct CalmTextField: View {
    let label: String?
    @Binding var text: String
    var prompt: String = ""
    var error: String?
    var isSecure = false
    var focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ label: String?, text: Binding<String>, prompt: String = "", error: String? = nil,
        isSecure: Bool = false, focus: FocusState<Bool>.Binding? = nil
    ) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.error = error
        self.isSecure = isSecure
        self.focus = focus
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label).font(CalmFont.fieldLabel).foregroundStyle(CalmColor.ink)
            }
            field
                .textFieldStyle(.plain)
                .font(CalmFont.field)
                .foregroundStyle(CalmColor.ink)
                .focused(focusBinding)
                .padding(.horizontal, 12)
                .frame(height: CalmMetrics.fieldHeight)
                .calmFieldChrome(isFocused: (focusBinding.wrappedValue || forced == .focus) && isEnabled, hasError: error != nil)
                .accessibilityLabel(label ?? prompt)
            if let error {
                Text(error).font(CalmFont.note).foregroundStyle(CalmColor.amber)
            }
        }
        .calmDisabledDimming()
    }

    @ViewBuilder
    private var field: some View {
        let placeholder = Text(prompt).foregroundStyle(CalmColor.muted)
        if isSecure {
            SecureField("", text: $text, prompt: placeholder)
        } else {
            TextField("", text: $text, prompt: placeholder)
        }
    }
}

/// A labelled multi-line field: 88 points tall when short, growing with
/// its text up to `maxHeight`, then scrolling. It never takes more height
/// than its text needs, so it can sit in a dialog that offers the whole
/// window.
struct CalmTextEditor: View {
    let label: String?
    @Binding var text: String
    var prompt: String = ""
    var minHeight: CGFloat = CalmMetrics.multilineFieldMinHeight
    var maxHeight: CGFloat = CalmMetrics.multilineFieldMaxHeight
    var error: String?
    var focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @State private var contentHeight: CGFloat = 0
    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.isEnabled) private var isEnabled

    init(
        _ label: String?, text: Binding<String>, prompt: String = "",
        minHeight: CGFloat = CalmMetrics.multilineFieldMinHeight,
        maxHeight: CGFloat = CalmMetrics.multilineFieldMaxHeight,
        error: String? = nil, focus: FocusState<Bool>.Binding? = nil
    ) {
        self.label = label
        _text = text
        self.prompt = prompt
        self.minHeight = minHeight
        self.maxHeight = max(minHeight, maxHeight)
        self.error = error
        self.focus = focus
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }

    private var height: CGFloat { min(max(contentHeight, minHeight), maxHeight) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label).font(CalmFont.fieldLabel).foregroundStyle(CalmColor.ink)
            }
            TextEditor(text: $text)
                .font(CalmFont.field)
                .foregroundStyle(CalmColor.ink)
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                // The field grows with its text, so it only scrolls once it
                // reaches maxHeight; before that, a scroller (always shown
                // with a mouse attached) would sit in an empty field.
                .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
                .focused(focusBinding)
                .padding(.horizontal, 7)
                .padding(.vertical, 8)
                .frame(height: height, alignment: .topLeading)
                .background(alignment: .topLeading) { sizer }
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        // The system placeholder colour, as single-line
                        // fields draw theirs (macOS ignores a TextField
                        // prompt's own colour), so both prompts match.
                        Text(prompt)
                            .font(CalmFont.field)
                            .lineSpacing(3)
                            .foregroundStyle(Color(nsColor: .placeholderTextColor))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }
                .calmFieldChrome(isFocused: (focusBinding.wrappedValue || forced == .focus) && isEnabled, hasError: error != nil)
                .accessibilityLabel(label ?? prompt)
            if let error {
                Text(error).font(CalmFont.note).foregroundStyle(CalmColor.amber)
            }
        }
        .calmDisabledDimming()
    }

    /// The text laid out the way the editor lays it out, unseen, to measure
    /// how tall the field should be. The trailing space keeps a final
    /// empty line (after Return) counted.
    private var sizer: some View {
        Text((text.isEmpty ? prompt : text) + " ")
            .font(CalmFont.field)
            .lineSpacing(3)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
    }
}

private extension View {
    func calmFieldChrome(isFocused: Bool, hasError: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.field, style: .continuous)
        return background(shape.fill(CalmColor.content))
            .overlay(shape.strokeBorder(
                hasError ? CalmColor.amber : (isFocused ? CalmColor.ink : CalmColor.line2),
                lineWidth: hasError ? 1.5 : 1
            ))
            .calmFieldFocusRing(isFocused && !hasError, radius: CalmMetrics.Radius.field)
    }
}

// MARK: - Search field

/// Search field. Empty and unfocused: panel fill, no outline. Focused or
/// typing: content fill, 1 pt ink + focus ring, and a clear button once
/// there is text.
///
/// ```swift
/// CalmSearchField(text: $query, prompt: "Search models")
/// CalmSearchField(text: $query, prompt: "Search settings", focus: $isSearchFocused)
/// ```
struct CalmSearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    var focus: FocusState<Bool>.Binding?
    /// Esc with nothing typed (close the search). The field's editor
    /// keeps Esc for itself, so whatever holds the field can't see it.
    var onEscapeWhenEmpty: (() -> Void)?
    var onSubmit: () -> Void = {}

    @FocusState private var ownFocus: Bool
    @Environment(\.calmPreviewInteraction) private var forced

    init(
        text: Binding<String>, prompt: String = "Search",
        focus: FocusState<Bool>.Binding? = nil, onEscapeWhenEmpty: (() -> Void)? = nil,
        onSubmit: @escaping () -> Void = {}
    ) {
        _text = text
        self.prompt = prompt
        self.focus = focus
        self.onEscapeWhenEmpty = onEscapeWhenEmpty
        self.onSubmit = onSubmit
    }

    private var focusBinding: FocusState<Bool>.Binding { focus ?? $ownFocus }

    var body: some View {
        let active = focusBinding.wrappedValue || forced == .focus
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.field, style: .continuous)
        HStack(spacing: 8) {
            CalmIcon(.search, size: 15)
                .foregroundStyle(CalmColor.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(CalmColor.muted))
                .textFieldStyle(.plain)
                .font(CalmFont.control)
                .foregroundStyle(CalmColor.ink)
                .focused(focusBinding)
                .onSubmit(onSubmit)
                // Esc clears the query, then closes the search, or (with no
                // closure) goes on to whatever holds the field: the sheet or
                // dialog closes.
                .onExitCommand(perform: text.isEmpty && onEscapeWhenEmpty == nil ? nil : {
                    if !text.isEmpty { text = "" } else { onEscapeWhenEmpty?() }
                })
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    CalmIcon(.close, size: 12, weight: 2)
                }
                .calmIconButton(size: 24)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 6)
        .frame(height: CalmMetrics.fieldHeight)
        .background(shape.fill(active ? CalmColor.content : CalmColor.panel))
        .overlay(shape.strokeBorder(active ? CalmColor.ink : .clear, lineWidth: 1))
        .calmFieldFocusRing(active, radius: CalmMetrics.Radius.field)
        .contentShape(shape)
        .onTapGesture { focusBinding.wrappedValue = true }
    }
}

// MARK: - Selection marks

/// Radio mark for one-of-many rows: 18, 1.5 pt line2 ring; on = 5.5 pt ink ring.
struct CalmRadio: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? CalmColor.ink : CalmColor.line2, lineWidth: isOn ? 5.5 : 1.5)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }
}

/// Check circle for picked cards: 20, 1.5 pt line2 ring; on = ink fill and
/// a content-coloured tick.
struct CalmCheckCircle: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            if isOn {
                Circle().fill(CalmColor.ink)
                CalmIcon(.check, size: 11, weight: 3).foregroundStyle(CalmColor.content)
            } else {
                Circle().strokeBorder(CalmColor.line2, lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

// MARK: - Key caps

/// Key-cap sizes: regular h24 SF 12/600; inline in text h21 SF 11/600;
/// large h34 SF 15/600 (shortcut recorder dialogs).
enum CalmKeyCapSize: Sendable {
    case regular
    case inline
    case large
}

/// A shortcut key shown as a cap, never as plain text: content fill, 1 pt
/// line2 outline and a 1 pt line2 bottom edge, radius 6.
///
/// ```swift
/// CalmKeyCap("⌥")
/// CalmKeyCap("Right ⌥", size: .inline)
/// ```
struct CalmKeyCap: View {
    let label: String
    var size: CalmKeyCapSize = .regular

    init(_ label: String, size: CalmKeyCapSize = .regular) {
        self.label = label
        self.size = size
    }

    private var height: CGFloat {
        switch size {
        case .regular: return CalmMetrics.keyCapHeight
        case .inline: return CalmMetrics.keyCapInlineHeight
        case .large: return 34
        }
    }

    private var font: Font {
        switch size {
        case .regular: return CalmFont.keyCap
        case .inline: return CalmFont.keyCapInline
        case .large: return .system(size: 15, weight: .semibold)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.key, style: .continuous)
        Text(label)
            .font(font)
            .foregroundStyle(CalmColor.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size == .large && label.count > 1 ? 14 : 7)
            .frame(minWidth: size == .large ? 34 : 22, minHeight: height, maxHeight: height)
            .background {
                ZStack {
                    shape.fill(CalmColor.line2).offset(y: 1)
                    shape.fill(CalmColor.content)
                }
            }
            .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
    }
}

/// Several caps for one shortcut, 4 apart.
///
/// ```swift
/// CalmKeyCombo(["⌃", "⌥", "Space"])
/// CalmKeyCombo(combo: HotKeyCombo(keyCode: appState.hotKeyCode, modifiers: appState.hotKeyModifiers))
/// ```
struct CalmKeyCombo: View {
    let caps: [String]
    var size: CalmKeyCapSize = .regular

    init(_ caps: [String], size: CalmKeyCapSize = .regular) {
        self.caps = caps
        self.size = size
    }

    init(combo: HotKeyCombo, size: CalmKeyCapSize = .regular) {
        self.init(CalmKeyCaps.labels(for: combo), size: size)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                CalmKeyCap(cap, size: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caps.joined(separator: " "))
    }
}

/// The shortcut pill in a feature page header: caps in a 1 pt line2
/// outline, with an optional caption (“to edit by voice”). Use it as a
/// button label when clicking opens the recorder.
struct CalmShortcutPill: View {
    let caps: [String]
    var caption: String?

    init(_ caps: [String], caption: String? = nil) {
        self.caps = caps
        self.caption = caption
    }

    var body: some View {
        let radius: CGFloat = caption == nil ? 10 : 9
        HStack(spacing: 4) {
            if !caps.isEmpty { CalmKeyCombo(caps) }
            if let caption {
                Text(caption)
                    .font(.system(size: 13))
                    .foregroundStyle(CalmColor.ink2)
                    .padding(.leading, caps.isEmpty ? 4 : 2)
                    .padding(.trailing, 4)
            }
        }
        // Caps or not (“Set a shortcut”), the pill keeps the caps' height.
        .frame(minHeight: CalmMetrics.keyCapHeight)
        .padding(.vertical, 6)
        .padding(.horizontal, caption == nil ? 6 : 8)
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(CalmColor.line2, lineWidth: 1))
    }
}

/// The waiting cap while a shortcut is recorded: accent ring with a soft
/// halo that pulses every 1.2 s.
struct CalmRecordingKeyCap: View {
    var text: String = "Press keys…"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.key, style: .continuous)
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(CalmColor.muted)
            .padding(.horizontal, 12)
            .frame(minWidth: 120, minHeight: 32, maxHeight: 32)
            .background(shape.fill(CalmColor.content))
            .overlay(shape.strokeBorder(CalmColor.accent, lineWidth: 1.5))
            .overlay {
                RoundedRectangle(cornerRadius: CalmMetrics.Radius.key + 3.5, style: .continuous)
                    .strokeBorder(CalmColor.accentSoft, lineWidth: 3.5)
                    .padding(-5)
                    .opacity(pulse ? 0.35 : 1)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

/// Turns hotkeys into the caps the design draws: modifier symbols one per
/// cap, then the key (“Right ⌥”, “Space”, “F5”).
enum CalmKeyCaps {
    /// The caps for a combo, modifiers first in macOS menu order (⌃⌥⇧⌘ fn).
    static func labels(for combo: HotKeyCombo) -> [String] {
        var caps: [String] = []
        if combo.modifiers.contains(.control) { caps.append("⌃") }
        if combo.modifiers.contains(.option) { caps.append("⌥") }
        if combo.modifiers.contains(.shift) { caps.append("⇧") }
        if combo.modifiers.contains(.command) { caps.append("⌘") }
        if combo.modifiers.contains(.function) { caps.append("fn") }
        caps.append(keyLabel(for: combo.keyCode))
        return caps
    }

    /// One key's cap: sided modifiers keep their side (“Right ⌥”).
    static func keyLabel(for keyCode: Int) -> String {
        switch keyCode {
        case 61: return "Right ⌥"
        case 58: return "Left ⌥"
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 60: return "Right ⇧"
        case 56: return "Left ⇧"
        case 62: return "Right ⌃"
        case 59: return "Left ⌃"
        case 63: return "Fn"
        default: return KeyCodeReference.displayName(for: HotKeyCombo(keyCode: keyCode, modifiers: []))
        }
    }
}

// MARK: - Tags and notices

/// What a tag, notice or icon circle says about its subject.
enum CalmTone: Sendable {
    /// Teal: on, in use, learned, saved.
    case success
    /// Amber: needs attention.
    case warning
    /// panel2 / ink2: plain facts (Built in).
    case neutral
    /// Ink fill (Beta).
    case label
    /// panel2 / ink2 circle with an info glyph.
    case info
}

/// Tag: h22 px8 r6 SF 11.5/600.
///
/// ```swift
/// CalmTag("In use", tone: .success)
/// ```
struct CalmTag: View {
    let text: String
    var tone: CalmTone = .neutral

    init(_ text: String, tone: CalmTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var colors: (fill: Color, text: Color) {
        switch tone {
        case .success: return (CalmColor.accentSoft, CalmColor.accent)
        case .warning: return (CalmColor.amberSoft, CalmColor.amber)
        case .neutral, .info: return (CalmColor.panel2, CalmColor.ink2)
        case .label: return (CalmColor.primary, CalmColor.onPrimary)
        }
    }

    var body: some View {
        Text(text)
            .font(CalmFont.tag)
            .foregroundStyle(colors.text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: CalmMetrics.tagHeight)
            .background(RoundedRectangle(cornerRadius: CalmMetrics.Radius.key, style: .continuous).fill(colors.fill))
    }
}

/// A one-line notice under the thing it explains: 13-point icon + 12.5 text.
///
/// ```swift
/// CalmInlineNotice("Doesn’t understand German", tone: .warning)
/// CalmInlineNotice("Saved", tone: .success)
/// ```
struct CalmInlineNotice: View {
    let text: String
    var tone: CalmTone = .warning

    init(_ text: String, tone: CalmTone = .warning) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Group {
                switch tone {
                case .success: CalmIcon(.check, size: 13, weight: 2.4)
                case .info, .neutral, .label: CalmIcon(.info, size: 13)
                case .warning: CalmIcon(.warning, size: 13, weight: 2)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text(text).font(CalmFont.note).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(tone == .success ? CalmColor.accent : (tone == .warning ? CalmColor.amber : CalmColor.ink2))
        .accessibilityElement(children: .combine)
    }
}

/// The 28-point icon circle at the start of a status row: ok (teal tick),
/// warning (amber triangle) or info (ink2 i).
struct CalmIconCircle: View {
    var tone: CalmTone = .success

    var body: some View {
        ZStack {
            switch tone {
            case .success:
                Circle().fill(CalmColor.accentSoft)
                CalmIcon(.check, size: 14, weight: 2.4).foregroundStyle(CalmColor.accent)
            case .warning:
                Circle().fill(CalmColor.amberSoft)
                CalmIcon(.warning, size: 15, weight: 2).foregroundStyle(CalmColor.amber)
            case .info, .neutral, .label:
                Circle().fill(CalmColor.panel2)
                CalmIcon(.info, size: 15).foregroundStyle(CalmColor.ink2)
            }
        }
        .frame(width: CalmMetrics.iconCircle, height: CalmMetrics.iconCircle)
        .accessibilityHidden(true)
    }
}

// MARK: - Progress and levels

/// Determinate progress: h6 r3, panel2 track, accent fill. Give it a title
/// and detail for the board's “Downloading · 210 of 483 MB” line.
struct CalmProgressBar: View {
    /// 0...1.
    let value: Double
    var title: String?
    var detail: String?

    init(value: Double, title: String? = nil, detail: String? = nil) {
        self.value = value
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || detail != nil {
                HStack {
                    if let title { Text(title).foregroundStyle(CalmColor.ink) }
                    Spacer(minLength: 8)
                    if let detail { Text(detail).foregroundStyle(CalmColor.muted) }
                }
                .font(CalmFont.note)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CalmColor.panel2)
                    Capsule().fill(CalmColor.accent)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Progress")
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded())) percent")
    }
}

/// Indeterminate spinner: 18, 2 pt, one turn every 0.8 s.
struct CalmSpinner: View {
    var size: CGFloat = 18
    /// Stroke width on the 20-point grid.
    var weight: CGFloat = 2

    @State private var spinning = false

    var body: some View {
        let width = weight * size / 20
        ZStack {
            Circle()
                .stroke(CalmColor.line2, lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(CalmColor.ink, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .padding(size * 3 / 20)
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityLabel("Loading")
    }
}

/// Ring progress used in model rows: 16, line2 track, accent arc.
struct CalmRingProgress: View {
    /// 0...1.
    let value: Double
    var size: CGFloat = 16
    /// Show the percentage after the ring (SF 12.5 muted, gap 6).
    var showsPercent = false

    var body: some View {
        HStack(spacing: 6) {
            let width = 2.2 * size / 20
            ZStack {
                Circle().stroke(CalmColor.line2, lineWidth: width)
                Circle()
                    .trim(from: 0, to: min(max(value, 0), 1))
                    .stroke(CalmColor.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(size * 2.5 / 20)
            .frame(width: size, height: size)
            if showsPercent {
                Text("\(Int((min(max(value, 0), 1) * 100).rounded()))%")
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((min(max(value, 0), 1) * 100).rounded())) percent")
    }
}

/// Bar levels: lit bars in accent, the rest in `off`. The board's height
/// pattern repeats for longer meters.
struct CalmLevelBars: View {
    /// 0...1.
    let level: Float
    var barCount = 12
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2
    var height: CGFloat = 18

    static let pattern: [CGFloat] = [5, 9, 13, 16, 11, 8, 14, 17, 10, 6, 4, 3]

    var body: some View {
        let lit = Int((CGFloat(min(max(level, 0), 1)) * CGFloat(barCount)).rounded())
        HStack(spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2 + 0.5)
                    .fill(index < lit ? CalmColor.accent : CalmColor.off)
                    .frame(width: barWidth, height: Self.pattern[index % Self.pattern.count] * height / 18)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The live microphone level meter (12 bars, 3 wide, gap 2), bound to the
/// app's `AudioMeterState` so only the meter redraws on level changes.
///
/// ```swift
/// CalmMicLevelMeter(meter: appState.audioMeter)
/// ```
struct CalmMicLevelMeter: View {
    @ObservedObject var meter: AudioMeterState
    var barCount = 12

    var body: some View {
        CalmLevelBars(level: meter.level, barCount: barCount)
            .animation(.easeOut(duration: 0.1), value: meter.level)
            .accessibilityElement()
            .accessibilityLabel("Input level")
            .accessibilityValue("\(Int(meter.level * 100)) percent")
    }
}
