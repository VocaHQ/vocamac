import SwiftUI

/// The Quiet Wonder palette: warm ivory paper, ink, petrol and clay by day;
/// the same hues on a deep night ink in dark mode.
enum VocaPalette {
    static let ivory = NSColor(srgbRed: 0.969, green: 0.961, blue: 0.937, alpha: 1)    // #F7F5EF
    static let paper = NSColor(srgbRed: 0.988, green: 0.984, blue: 0.969, alpha: 1)    // #FCFBF7
    static let sand = NSColor(srgbRed: 0.937, green: 0.922, blue: 0.882, alpha: 1)     // #EFEBE1
    static let ink = NSColor(srgbRed: 0.094, green: 0.125, blue: 0.137, alpha: 1)      // #182023
    static let petrol = NSColor(srgbRed: 0.208, green: 0.392, blue: 0.459, alpha: 1)   // #356475
    static let mist = NSColor(srgbRed: 0.498, green: 0.702, blue: 0.761, alpha: 1)     // #7FB3C2
    static let clay = NSColor(srgbRed: 0.722, green: 0.400, blue: 0.290, alpha: 1)     // #B8664A
    static let nightCanvas = NSColor(srgbRed: 0.071, green: 0.098, blue: 0.110, alpha: 1)  // #12191C
    static let nightSurface = NSColor(srgbRed: 0.102, green: 0.141, blue: 0.157, alpha: 1) // #1A2428
    static let nightSand = NSColor(srgbRed: 0.055, green: 0.082, blue: 0.090, alpha: 1)    // #0E1517

    /// One color per appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Shared, adaptive surfaces for the app. System text colors retain contrast in both appearances.
enum VocaDesign {
    /// Petrol by day, a lighter mist at night so icons and selection still
    /// read against the dark ink canvas.
    static let accent = Color(nsColor: VocaPalette.adaptive(light: VocaPalette.petrol, dark: VocaPalette.mist))
    /// Fill for prominent buttons. White text needs the deeper petrol in both
    /// appearances; the mist accent is too light to carry it.
    static let accentSolid = Color(nsColor: VocaPalette.petrol)

    /// Success and "ready" states. A system green next to the petrol accent
    /// would read as two meanings, so ready uses the accent itself.
    static var success: Color { accent }

    /// Command Mode's own color. Editing selected text is a different act
    /// from dictating, so every surface that shows it — overlay, menu bar
    /// icon, menu, settings — uses violet instead of the dictation petrol.
    /// Clay would sit beside the palette more quietly, but it is too close to
    /// the amber `warning` to tell apart at a glance.
    static let command = Color(nsColor: commandNSColor)
    static let commandNSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.72, green: 0.62, blue: 1.0, alpha: 1)
            : NSColor(red: 0.44, green: 0.28, blue: 0.86, alpha: 1)
    }
    /// Something needs attention. System orange and yellow fall under 3:1
    /// against a light window, so text and glyphs use a deeper amber there.
    static let warning = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)
            : NSColor(red: 0.74, green: 0.36, blue: 0.0, alpha: 1)
    })

    /// Work in progress ("Transcribing…"): distinct from `warning`, since
    /// waiting is not a problem.
    static let busy = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1)
            : NSColor(red: 0.62, green: 0.45, blue: 0.0, alpha: 1)
    })
    /// Warm ivory paper by day, deep night ink in dark mode.
    static let canvas = Color(nsColor: canvasNSColor)
    static let canvasNSColor = VocaPalette.adaptive(light: VocaPalette.ivory, dark: VocaPalette.nightCanvas)
    /// Cards: a lighter sheet of paper laid on the canvas.
    static let surface = Color(nsColor: VocaPalette.adaptive(light: VocaPalette.paper, dark: VocaPalette.nightSurface))
    /// Sidebars sit one shade under the canvas.
    static let sidebar = Color(nsColor: VocaPalette.adaptive(light: VocaPalette.sand, dark: VocaPalette.nightSand))
    /// Ink by day, ivory by night: the fill of the one primary action.
    static let ink = Color(nsColor: VocaPalette.adaptive(light: VocaPalette.ink, dark: VocaPalette.ivory))
    /// Text on `ink`.
    static let onInk = Color(nsColor: VocaPalette.adaptive(light: VocaPalette.ivory, dark: VocaPalette.ink))
    static let clay = Color(nsColor: VocaPalette.clay)
    /// Hairlines and card edges: present, never heavy. Fainter at night,
    /// where the lighter card face already carries the edge.
    static let line = Color(nsColor: VocaPalette.adaptive(
        light: NSColor.black.withAlphaComponent(0.075),
        dark: NSColor.white.withAlphaComponent(0.05)
    ))

    /// Editorial serif for headlines. New York ships with macOS, so there is
    /// no font file to bundle or license.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }

    /// The small tracked capitals above a heading ("THREE PERMISSIONS").
    static let eyebrow = Font.system(size: 11, weight: .semibold)
}

/// Consistent card treatment without overriding native control behavior:
/// a sheet of paper on the canvas, with a hairline to carry the edge.
struct VocaCard: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
                contrast == .increased ? Color.primary.opacity(0.35) : VocaDesign.line
            ))
    }
}

extension View {
    func vocaCard() -> some View { modifier(VocaCard()) }
}

struct VocaPageHeader: View {
    let title: String
    let subtitle: String?
    var horizontalPadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(VocaDesign.display(subtitle == nil ? 30 : 32))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 20)
        .padding(.bottom, subtitle == nil ? 4 : 20)
    }
}

struct VocaGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            configuration.label.font(.headline)
            configuration.content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
    }
}

extension View {
    @ViewBuilder
    func vocaGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// Native sidebar vibrancy for onboarding and older macOS releases.
struct VocaSidebarMaterial: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context: Context) -> NSVisualEffectView {
        NSVisualEffectView()
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : nil
    }
}

/// The heading that sits above every settings card.
///
/// It carries an icon only where the heading has siblings it must be told
/// apart from — the speech engines. A heading that is unique on its page
/// ("Behavior", "Your Text", "Streak") stays text-only, which is also what
/// `Form(.grouped)` draws for its own `Section` headers.
struct VocaSectionHeader: View {
    let title: String
    var systemImage: String?
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(VocaDesign.accent)
                }
                Text(title)
            }
            .font(VocaDesign.display(20))
            .accessibilityAddTraits(.isHeader)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 8)
    }
}

/// Compact settings groups with a consistent heading and bounded row spacing.
///
/// The heading sits above the card so hand-built pages match the `Section`
/// headers that `Form(.grouped)` draws on the pages still using a `Form`.
struct VocaSettingsGroup<Content: View>: View {
    let title: String
    var systemImage: String?
    var subtitle: String?
    @ViewBuilder let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VocaSectionHeader(title: title, systemImage: systemImage, subtitle: subtitle)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .vocaCard()
        }
    }
}

/// Scroll container shared by the hand-built settings pages so their content
/// insets match the `Form(.grouped)` pages either side of them in the sidebar.
struct VocaSettingsPageContent<Content: View>: View {
    var spacing: CGFloat = 20
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }
}

/// Side-by-side option cards for picking the activation gesture.
///
/// A segmented control can only show two short labels, so the gesture itself
/// had to be explained in a caption underneath that changed as you switched —
/// you could not compare the two without toggling between them. Cards show
/// both descriptions at once.
struct ActivationModeSelector: View {
    @Binding var selection: ActivationMode
    var onChange: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(ActivationMode.allCases) { mode in
                card(for: mode)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activation mode")
    }

    private func card(for mode: ActivationMode) -> some View {
        let isSelected = selection == mode
        return Button {
            guard selection != mode else { return }
            selection = mode
            onChange()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: mode.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isSelected ? VocaDesign.accent : .secondary)
                        // The two glyphs have different heights; a fixed box
                        // keeps both card titles on the same baseline.
                        .frame(width: 18, height: 16)
                    Text(mode.shortName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(VocaDesign.accent)
                        .opacity(isSelected ? 1 : 0)
                }
                Text(mode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // maxHeight lets the shorter card stretch to the taller one, so a
            // one-line description does not leave the pair ragged.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? VocaDesign.accent.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? VocaDesign.accent.opacity(0.6) : VocaDesign.line,
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(mode.shortName)
        .accessibilityHint(mode.description)
        .help(mode.description)
    }
}

/// A card that hides secondary controls behind a labelled row.
///
/// `DisclosureGroup`'s bare label leaves a collapsed row reading as an empty
/// box with a stray chevron; this gives it a title, a subtitle, and a status
/// badge so the row says something while it is shut.
struct VocaDisclosureCard<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badge: String?
    @Binding var isExpanded: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VocaDesign.accent)
                        .frame(width: 30, height: 30)
                        .background(VocaDesign.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if let badge {
                        Text(badge)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    VocaDisclosureChevron(isExpanded: isExpanded)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(VocaDisclosureHeaderButtonStyle())
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(subtitle)

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VocaDesign.surface, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(VocaDesign.line))
    }
}

/// The trailing affordance for every expandable row: a chevron in a small
/// round well, so the row reads as something that opens even while shut.
struct VocaDisclosureChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.07), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Highlights a whole disclosure header on hover and press.
struct VocaDisclosureHeaderButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.07 : isHovered ? 0.035 : 0))
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// `DisclosureGroup` inside a card. The system style only responds to its
/// tiny leading triangle; this makes the whole labelled row the control.
struct VocaDisclosureGroupStyle: DisclosureGroupStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    VocaDisclosureChevron(isExpanded: configuration.isExpanded)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(VocaDisclosureHeaderButtonStyle())
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -10)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    configuration.content
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
    }
}

/// One choice in a pull-down `Menu`, checked when it is the current value.
///
/// A `Toggle` becomes a menu item with its state set, so the menu draws the
/// checkmark itself. A `checkmark` symbol image does not survive: macOS 27
/// hides symbol images in menus for apps built on the macOS 26 SDK and later,
/// which left no sign of the current choice.
struct VocaMenuChoice: View {
    let title: String
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        // Choosing the checked item selects it again, as the plain buttons did.
        Toggle(title, isOn: Binding(get: { isSelected }, set: { _ in select() }))
    }
}

/// The placeholder for a list with nothing in it yet: what the list is for,
/// and the one action that starts it.
struct VocaEmptyState: View {
    let title: String
    let message: String
    var systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.bottom, 2)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(VocaDesign.accentSolid)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

/// "Removed · Undo" bar shown at the bottom of a settings page.
struct UndoToastView: View {
    let undoCenter: UndoCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let entry = undoCenter.current {
                HStack(spacing: 12) {
                    Text(entry.message).font(.callout)
                    Button("Undo") { undoCenter.undo() }
                        .buttonStyle(.borderless)
                        .fontWeight(.semibold)
                        .foregroundStyle(VocaDesign.accent)
                    Button {
                        undoCenter.dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(VocaDesign.line))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 16)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .id(entry.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: undoCenter.current?.id)
    }
}
