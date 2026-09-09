import SwiftUI

/// Shared, adaptive surfaces for the app. System text colors retain contrast in both appearances.
enum VocaDesign {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.47, green: 0.85, blue: 0.74, alpha: 1)
            : BrandAssets.brandGreen
    })
    /// Fill for prominent buttons. The mint accent is tuned for icons and
    /// selection on a dark surface; white button text needs a deeper green to
    /// stay legible, so prominent fills use this instead.
    static let accentSolid = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.090, green: 0.470, blue: 0.380, alpha: 1)
            : BrandAssets.brandGreen
    })

    /// Success and "ready" states. The brand is already green, so a second
    /// system green next to it reads as two different greens rather than one
    /// meaning.
    static var success: Color { accent }
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color.primary.opacity(0.10)
}

/// Consistent card treatment without overriding native control behavior.
/// A 3.5% primary fill nearly vanishes on the dark window background, so the
/// hairline carries the card edge in both appearances.
struct VocaCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(VocaDesign.line))
    }
}

extension View {
    func vocaCard() -> some View { modifier(VocaCard()) }
}

struct VocaPageHeader: View {
    let title: String
    let subtitle: String
    var horizontalPadding: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 25, weight: .semibold, design: .rounded))
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 20)
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
            .font(.headline)
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
                    .fill(isSelected ? VocaDesign.accent.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? VocaDesign.accent.opacity(0.55) : VocaDesign.line,
                        lineWidth: isSelected ? 1.5 : 1
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
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(VocaDesign.accent)
                        .frame(width: 20)
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
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(subtitle)

            if isExpanded {
                Divider().padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
    }
}
