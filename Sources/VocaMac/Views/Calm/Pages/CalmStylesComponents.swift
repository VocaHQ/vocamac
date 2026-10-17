// CalmStylesComponents.swift
// VocaMac
//
// Pieces of the Styles page: the style card with its live sample, the
// “Used in” app chips, a wrapping row layout, app icons and the compact
// rows the Styles dialogs use.

import AppKit
import SwiftUI

// MARK: - Style card

/// A style card (Patterns board): a live sample on panel, then the name, a
/// short line and a radio. Selected cards get the 2 pt ink ring.
struct CalmStyleCard: View {
    let style: WritingStyle
    let sample: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CalmStyleSample(sample, dialect: style.defaultRules.emphasisDialect).text(
                    font: style.calmSampleIsMonospaced ? .system(size: 13, design: .monospaced) : CalmFont.body
                )
                    .lineSpacing(5)
                    .foregroundStyle(CalmColor.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 110 - 32, alignment: .topLeading)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CalmColor.panel))
                    .padding([.horizontal, .top], 12)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(style.displayName)
                            .font(CalmFont.cardTitle)
                            .foregroundStyle(CalmColor.ink)
                        Text(style.calmTagline)
                            .font(CalmFont.sf(12.5, weight: 400))
                            .lineSpacing(1.5)
                            .foregroundStyle(CalmColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CalmRadio(isOn: isSelected)
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .calmCard(selected: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous))
        }
        .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.panel))
        .focusEffectDisabled()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(style.displayName). \(style.calmTagline). Example: "
                + CalmStyleSample(sample, dialect: style.defaultRules.emphasisDialect).plainText
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Sample rendering

/// A style card's sample as the target app would show it: Slack's
/// `*bold*` or Markdown's `**bold**` in bold, `` `code` `` in monospace
/// and “- ” list items as bullets, instead of the raw markup VocaMac types.
struct CalmStyleSample: Equatable {
    /// How a run of text looks.
    enum Look: Equatable {
        case regular
        case bold
        case italic
        case code
    }

    struct Run: Equatable {
        var text: String
        var look: Look = .regular
    }

    struct Line: Equatable {
        var isBullet = false
        var runs: [Run]
    }

    let lines: [Line]

    init(_ typed: String, dialect: EmphasisDialect) {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        lines = trimmed.components(separatedBy: "\n").map { Self.line($0, dialect: dialect) }
    }

    /// The sample as plain words (for VoiceOver), bullets as “•”.
    var plainText: String {
        lines.map { line in
            (line.isBullet ? "• " : "") + line.runs.map(\.text).joined()
        }
        .joined(separator: "\n")
    }

    /// The sample as one `Text` in `font`, with bold, italic and code runs.
    func text(font: Font) -> Text {
        guard !lines.isEmpty else { return Text(verbatim: " ") }
        var pieces: [Text] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { pieces.append(Text(verbatim: "\n")) }
            if line.isBullet { pieces.append(Text(verbatim: "•  ").font(font)) }
            pieces += line.runs.map { Self.piece($0, font: font) }
        }
        // Text has `+` but no `+=`, so the pieces are joined in one fold.
        return pieces.reduce(Text(verbatim: ""), +)
    }

    private static func piece(_ run: Run, font: Font) -> Text {
        let text = Text(verbatim: run.text)
        switch run.look {
        case .regular: return text.font(font)
        case .bold: return text.font(font).bold()
        case .italic: return text.font(font).italic()
        case .code: return text.font(.system(size: 13, design: .monospaced))
        }
    }

    private static func line(_ raw: String, dialect: EmphasisDialect) -> Line {
        var body = Substring(raw)
        var isBullet = false
        if body.hasPrefix("- ") || body.hasPrefix("• ") {
            isBullet = true
            body = body.dropFirst(2)
        }
        return Line(isBullet: isBullet, runs: runs(in: String(body), dialect: dialect))
    }

    /// The markers this dialect uses, longest first.
    private static func markers(for dialect: EmphasisDialect) -> [(String, Look)] {
        switch dialect {
        case .none: return [("`", .code)]
        case .slackMrkdwn: return [("`", .code), ("*", .bold), ("_", .italic)]
        case .markdown: return [("`", .code), ("**", .bold), ("*", .italic), ("_", .italic)]
        }
    }

    private static func runs(in text: String, dialect: EmphasisDialect) -> [Run] {
        let markers = markers(for: dialect)
        var runs: [Run] = []
        var plain = ""
        var rest = Substring(text)
        func flush() {
            if !plain.isEmpty { runs.append(Run(text: plain)) }
            plain = ""
        }
        while let first = rest.first {
            // A marker counts only when it opens a word and closes later on
            // the line around non-space text.
            if let (marker, look) = markers.first(where: { rest.hasPrefix($0.0) }) {
                let inner = rest.dropFirst(marker.count)
                if let close = inner.range(of: marker),
                   !inner[..<close.lowerBound].isEmpty,
                   inner.first?.isWhitespace == false,
                   inner[..<close.lowerBound].last?.isWhitespace == false {
                    flush()
                    runs.append(Run(text: String(inner[..<close.lowerBound]), look: look))
                    rest = inner[close.upperBound...]
                    continue
                }
            }
            plain.append(first)
            rest = rest.dropFirst()
        }
        flush()
        return runs.isEmpty ? [Run(text: "")] : runs
    }
}

// MARK: - Chips

/// The look of an app chip in “Used in”: h32, px12, r9, panel fill, SF 13.
struct CalmStylesChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalmStylesChipBody(configuration: configuration)
    }
}

private struct CalmStylesChipBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
        configuration.label
            .font(CalmFont.sf(13, weight: 400))
            .foregroundStyle(CalmColor.ink)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(shape.fill(isHovered && isEnabled ? CalmColor.panel2 : CalmColor.panel))
            .contentShape(shape)
            .calmPressed(configuration.isPressed, scheme: scheme)
            .calmFocusRing(isFocused && isEnabled, radius: CalmMetrics.Radius.button)
            .calmDisabledDimming()
            .onHover { isHovered = $0 }
    }
}

/// A non-interactive chip (“All other apps”).
struct CalmStylesStaticChip: View {
    let title: String

    var body: some View {
        Text(title)
            .font(CalmFont.sf(13, weight: 400))
            .foregroundStyle(CalmColor.muted)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous).fill(CalmColor.panel))
    }
}

/// A chip's text: the name, then muted notes (“Paused”, another style).
struct CalmStylesChipLabel: View {
    let name: String
    let notes: [String]
    var isDimmed = false

    var body: some View {
        HStack(spacing: 6) {
            Text(name).foregroundStyle(isDimmed ? CalmColor.muted : CalmColor.ink)
            if !notes.isEmpty {
                Text(notes.joined(separator: " · ")).foregroundStyle(CalmColor.muted)
            }
        }
    }
}

/// The secondary button beside the chips, 32 tall to sit level with them.
struct CalmStylesChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CalmStylesChipButtonBody(configuration: configuration)
    }
}

private struct CalmStylesChipButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var scheme
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
        configuration.label
            .font(CalmFont.button)
            .foregroundStyle(CalmColor.ink)
            .lineLimit(1)
            .padding(.horizontal, CalmMetrics.buttonPadding)
            .frame(height: 32)
            .background(shape.fill(isHovered && isEnabled ? CalmColor.line2 : CalmColor.panel2))
            .contentShape(shape)
            .calmPressed(configuration.isPressed, scheme: scheme)
            .calmFocusRing(isFocused && isEnabled, radius: CalmMetrics.Radius.button)
            .calmDisabledDimming()
            .onHover { isHovered = $0 }
    }
}

/// “+ Add app or website”: a 13-point plus at stroke 2, gap 7.
struct CalmStylesAddLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 7) {
            CalmIcon(.plus, size: 13, weight: 2)
            Text(title)
        }
    }
}

// MARK: - Dialog rows

/// A compact row inside a Styles dialog: title (SF 14/560) and an optional
/// muted note on the left, the control on the right.
struct CalmStylesDialogRow<Control: View>: View {
    let title: String
    var note: String?
    let control: Control

    init(_ title: String, note: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.note = note
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).calmType(.rowTitle).fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note)
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

/// A switch row inside a Styles dialog.
struct CalmStylesDialogToggle: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    init(_ title: String, note: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        _isOn = isOn
    }

    var body: some View {
        CalmStylesDialogRow(title, note: note) {
            CalmSwitch(isOn: $isOn).accessibilityLabel(title)
        }
    }
}

/// “You say … → VocaMac types …” for one style, run through the real engine.
struct CalmStylesExample: View {
    @EnvironmentObject private var appState: AppState
    let style: WritingStyle
    var rules: WritingStyleRules?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(style.shortDescription)
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("“\(style.exampleSentence)”")
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.ink2)
                CalmIcon(.arrowRight, size: 13)
                    .foregroundStyle(CalmColor.muted)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                Text(appState.writingStylePreview(style.exampleSentence, rules: rules ?? style.defaultRules))
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(CalmColor.ink)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CalmColor.panel))
    }
}

/// The “Advanced” disclosure link inside a dialog.
struct CalmStylesDisclosure: View {
    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                CalmIcon(isExpanded ? .chevDown : .chevRight, size: 13, weight: 2)
            }
        }
        .calmLink()
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
