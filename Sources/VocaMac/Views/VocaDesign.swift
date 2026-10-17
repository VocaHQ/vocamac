import SwiftUI

/// The Quiet Wonder palette: cool, faintly green paper that sits easily
/// under the brand teal, with ink and clay by day; the same hues on a deep
/// night ink in dark mode. Petrol and mist remain for the scene art.
enum VocaPalette {
    static let ivory = NSColor(srgbRed: 0.941, green: 0.957, blue: 0.933, alpha: 1)    // #F0F4EE
    static let paper = NSColor(srgbRed: 0.973, green: 0.980, blue: 0.965, alpha: 1)    // #F8FAF6
    static let sand = NSColor(srgbRed: 0.890, green: 0.918, blue: 0.878, alpha: 1)     // #E3EAE0
    static let ink = NSColor(srgbRed: 0.094, green: 0.125, blue: 0.137, alpha: 1)      // #182023
    static let teal = NSColor(srgbRed: 0.059, green: 0.420, blue: 0.341, alpha: 1)     // #0F6B57
    static let mint = NSColor(srgbRed: 0.333, green: 0.761, blue: 0.627, alpha: 1)     // #55C2A0
    static let petrol = NSColor(srgbRed: 0.208, green: 0.392, blue: 0.459, alpha: 1)   // #356475
    static let mist = NSColor(srgbRed: 0.498, green: 0.702, blue: 0.761, alpha: 1)     // #7FB3C2
    static let clay = NSColor(srgbRed: 0.722, green: 0.400, blue: 0.290, alpha: 1)     // #B8664A
    static let nightCanvas = NSColor(srgbRed: 0.067, green: 0.106, blue: 0.090, alpha: 1)  // #111B17
    static let nightSurface = NSColor(srgbRed: 0.098, green: 0.145, blue: 0.122, alpha: 1) // #19251F
    static let nightSand = NSColor(srgbRed: 0.047, green: 0.082, blue: 0.063, alpha: 1)    // #0C1510

    /// One color per appearance.
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}

/// Shared, adaptive surfaces for the app. System text colors retain contrast in both appearances.
enum VocaDesign {
    /// The brand teal by day, a lighter mint at night so icons and selection
    /// still read against the dark ink canvas.
    static let accent = Color(nsColor: VocaPalette.adaptive(light: VocaPalette.teal, dark: VocaPalette.mint))
    /// Fill for prominent buttons. White text needs the deeper teal in both
    /// appearances; the mint accent is too light to carry it.
    static let accentSolid = Color(nsColor: VocaPalette.teal)

    /// Success and "ready" states. A system green next to the teal accent
    /// would read as two meanings, so ready uses the accent itself.
    static var success: Color { accent }

    /// Command Mode's own color. Editing selected text is a different act
    /// from dictating, so every surface that shows it — overlay, menu bar
    /// icon, menu, settings — uses violet instead of the dictation teal.
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
    /// Cool, faintly green paper by day, deep night ink in dark mode.
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

extension View {
    /// A secondary action in the paper outline style.
    func vocaGlassButton() -> some View {
        buttonStyle(VocaOutlineButtonStyle())
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
            // Pages set `.toggleStyle(.switch)` for their rows, and a menu
            // can't draw a switch: it greys the item out and ignores clicks.
            .toggleStyle(.automatic)
    }
}

// MARK: - Key caps

/// A menu or button whose face is a key cap with a small chevron.
struct VocaKeyCapButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(minWidth: 48, minHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.16))
                    .offset(y: configuration.isPressed ? 0.5 : 2)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered && isEnabled ? VocaDesign.accent.opacity(0.08) : Color.clear)
                    .background(VocaDesign.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .offset(y: configuration.isPressed ? 1.5 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? VocaDesign.accent : Color.primary.opacity(isHovered ? 0.28 : 0.16),
                                  lineWidth: isActive ? 1.5 : 1)
                    .offset(y: configuration.isPressed ? 1.5 : 0)
            }
            .padding(.bottom, 2)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { isHovered = $0 }
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
