// VocaMotion.swift
// VocaMac
//
// Entrance motion and the primary controls of the Quiet Wonder look: text
// that resolves out of a blur, content that rises into place, and the one
// ink button per screen.

import SwiftUI

// MARK: - Rise in

/// Fades a view up into place from a slight blur, after `delay` seconds.
/// Under Reduce Motion it simply appears.
struct RiseIn: ViewModifier {
    let delay: Double
    var distance: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        let shown = isShown || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : distance)
            .blur(radius: shown ? 0 : 5)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.spring(response: 0.75, dampingFraction: 0.9).delay(delay)) {
                    isShown = true
                }
            }
    }
}

extension View {
    func riseIn(delay: Double = 0, distance: CGFloat = 16) -> some View {
        modifier(RiseIn(delay: delay, distance: distance))
    }
}

// MARK: - Headline reveal

/// A headline whose words resolve one after another out of a blur.
///
/// Remount it (`.id(...)`) to play the reveal again. VoiceOver reads the
/// whole line once, not word by word.
struct RevealHeadline: View {
    let text: String
    var size: CGFloat = 48
    var delay: Double = 0
    var stagger: Double = 0.08

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        WordFlowLayout(spacing: size * 0.22, lineSpacing: size * 0.02) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                Text(word)
                    .font(VocaDesign.display(size))
                    .modifier(WordReveal(delay: delay + Double(index) * stagger))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct WordReveal: ViewModifier {
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShown = false

    func body(content: Content) -> some View {
        let shown = isShown || reduceMotion
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 12)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 1.0).delay(delay)) {
                    isShown = true
                }
            }
    }
}

/// Lays words out left to right, wrapping to a new line when one would
/// overflow the proposed width.
struct WordFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Buttons

/// The one primary action on a screen: an ink capsule that lifts on hover.
struct VocaPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(VocaDesign.onInk)
            .padding(.horizontal, 22)
            .frame(minHeight: 40)
            .background(VocaDesign.ink, in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .offset(y: isHovered && isEnabled && !configuration.isPressed ? -1 : 0)
            .shadow(color: .black.opacity(isHovered && isEnabled ? 0.18 : 0), radius: 10, y: 5)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isHovered)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A title and a trailing arrow that nudges forward while the pointer is
/// over the button.
struct VocaArrowLabel: View {
    let title: String
    var systemImage = "arrow.right"

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .offset(x: isHovered && !reduceMotion ? 3 : 0)
        }
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isHovered)
    }
}

/// A secondary action: an outlined capsule that fills with ink on hover.
struct VocaOutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let filled = isHovered && isEnabled
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(filled ? VocaDesign.onInk : Color.primary)
            .padding(.horizontal, 14)
            .frame(minHeight: 28)
            .background(filled ? VocaDesign.ink : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(filled ? 0 : 0.22)))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Step progress

/// Short dashes for a multi-step flow; the current one is longer.
struct VocaStepProgress: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? VocaDesign.ink : Color.primary.opacity(0.15))
                    .frame(width: index == current ? 28 : 14, height: 3)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}
