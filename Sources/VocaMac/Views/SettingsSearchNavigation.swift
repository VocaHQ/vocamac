import SwiftUI

private struct SettingsSearchTargetKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsSearchTarget: String? {
        get { self[SettingsSearchTargetKey.self] }
        set { self[SettingsSearchTargetKey.self] = newValue }
    }
}

/// Stable scroll destinations shared with the search index. Highlighting is
/// temporary and never intercepts clicks or changes the control's AX traits.
private struct SettingsSearchTarget: ViewModifier {
    let ids: [String]
    @Environment(\.settingsSearchTarget) private var selected
    @State private var highlighted = false

    func body(content: Content) -> some View {
        content
            .id(ids[0])
            .accessibilityIdentifier(ids[0])
            // Aliases get anchors of their own over the same frame. Swapping
            // the control's id to the alias would rebuild it and drop its state.
            .background {
                ForEach(ids.dropFirst(), id: \.self) { Color.clear.id($0) }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(highlighted ? VocaDesign.accent : .clear, lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .task(id: selected) {
                highlighted = selected.map(ids.contains) ?? false
                guard highlighted else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                highlighted = false
            }
    }
}

private struct SettingsSearchReveal: ViewModifier {
    let ids: [String]
    @Binding var expanded: Bool
    @Environment(\.settingsSearchTarget) private var selected

    func body(content: Content) -> some View {
        content.onChange(of: selected, initial: true) { _, target in
            if let target, ids.contains(target) { expanded = true }
        }
    }
}

extension View {
    func settingsTarget(_ id: String, aliases: [String] = []) -> some View {
        modifier(SettingsSearchTarget(ids: [id] + aliases))
    }

    func revealSettingsTargets(_ ids: [String], expanded: Binding<Bool>) -> some View {
        modifier(SettingsSearchReveal(ids: ids, expanded: expanded))
    }
}
