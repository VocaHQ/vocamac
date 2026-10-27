// CalmModelsParts.swift
// VocaMac
//
// The pieces of Settings › Models (Model chooser parts board): pick cards
// in every state, the “You're using X” row, the Browse link row, family
// headers, model rows with their state on the right, and the error notice.

import SwiftUI

// MARK: - Pick card

/// The footer of a pick card: what picking it costs, or where it stands.
enum CalmPickCardFooter: Equatable {
    /// “483 MB · On this Mac”.
    case onThisMac(size: String)
    /// “627 MB · ⬇ Downloads when picked”.
    case downloadsWhenPicked(size: String)
    /// A model with nothing to download (Apple Speech).
    case builtIn
    case downloading(Double)
    case loading(String)
    case failed
}

/// One pick card: a big radio button. Panel fill, r14, padding 18/18/16,
/// min height 176; hover panel2; selected content fill with a 2 pt ink
/// ring and a filled check top-right. Clicking anywhere picks it.
struct CalmPickCard: View {
    let kind: String
    let name: String
    /// The muted word the lists show after the name (“Multilingual”), so a
    /// card and its row read the same.
    var variant: String?
    let logo: CalmLogoName
    let reason: String
    let footer: CalmPickCardFooter
    let isSelected: Bool
    let onPick: () -> Void
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}

    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @State private var hoveredForReal = false
    @FocusState private var hasFocus: Bool

    private var isHovered: Bool { hoveredForReal || forced == .hover }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            Text(kind)
                .font(CalmFont.sf(12, weight: 600))
                .foregroundStyle(CalmColor.muted)
                .padding(.trailing, 26)
            HStack(spacing: 10) {
                CalmLogo(logo, box: 32)
                (Text(name).font(CalmFont.sf(15.5, weight: 600)).foregroundStyle(CalmColor.ink)
                    + Text(variant.map { " \($0)" } ?? "").font(CalmFont.body).foregroundStyle(CalmColor.muted))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
            Text(reason)
                .font(CalmFont.description)
                .lineSpacing(2.5)
                .foregroundStyle(CalmColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            footerView
                .padding(.top, 12)
        }
        .padding(EdgeInsets(top: 18, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, minHeight: 176, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(isSelected ? CalmColor.content : (isHovered && isEnabled ? CalmColor.panel2 : CalmColor.panel)))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel + 2, style: .continuous)
                    .strokeBorder(CalmColor.ink, lineWidth: 2)
                    .padding(-2)
            }
        }
        .overlay(alignment: .topTrailing) {
            CalmCheckCircle(isOn: isSelected).padding(16)
        }
        .contentShape(shape)
        .onTapGesture { if isEnabled { onPick() } }
        .onHover { hoveredForReal = $0 }
        .focusable(isEnabled, interactions: .activate)
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(.space) { onPick(); return .handled }
        .calmFocusRing((hasFocus || forced == .focus) && isEnabled, radius: CalmMetrics.Radius.panel)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind): \([name, variant].compactMap { $0 }.joined(separator: " "))")
        .accessibilityHint(reason)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onPick() }
    }

    @ViewBuilder
    private var footerView: some View {
        switch footer {
        case .onThisMac(let size):
            footerLine { Text(size).fixedSize(); Text("·"); Text("On this Mac") }
        case .builtIn:
            footerLine { Text("Built into macOS") }
        case .downloadsWhenPicked(let size):
            ViewThatFits(in: .horizontal) {
                footerLine { Text("\(size) ·").fixedSize(); downloadsWhenPicked }
                // Stacked, the size needs no separator after it.
                VStack(alignment: .leading, spacing: 4) {
                    Text(size).fixedSize()
                    downloadsWhenPicked
                }
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading \(Int((progress * 100).rounded()))%").monospacedDigit()
                    Spacer(minLength: 8)
                    Button("Cancel", action: onCancel)
                        .buttonStyle(CalmPlainFocusStyle(radius: 4))
                        .focusEffectDisabled()
                        .font(CalmFont.sf(12.5, weight: 550))
                        .foregroundStyle(CalmColor.ink)
                }
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.muted)
                CalmProgressBar(value: progress)
            }
        case .loading(let status):
            HStack(spacing: 4) {
                CalmSpinner(size: 13, weight: 2.4)
                Text(status)
            }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.ink2)
        case .failed:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { failedLabel; retryButton }
                VStack(alignment: .leading, spacing: 4) { failedLabel; retryButton }
            }
            .font(CalmFont.note)
        }
    }

    private func footerLine<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.muted)
            .lineLimit(1)
    }

    private var downloadsWhenPicked: some View {
        HStack(spacing: 4) {
            CalmIcon(.download, size: 12, weight: 2)
            Text("Downloads when picked")
        }
        .font(CalmFont.note)
        .foregroundStyle(CalmColor.muted)
    }

    private var failedLabel: some View {
        HStack(spacing: 4) {
            CalmIcon(.warning, size: 12, weight: 2)
            Text("Download failed ·")
        }
        .foregroundStyle(CalmColor.amber)
        .fixedSize()
    }

    private var retryButton: some View {
        Button("Try again", action: onRetry)
            .buttonStyle(CalmPlainFocusStyle(radius: 4))
            .focusEffectDisabled()
            .font(CalmFont.sf(12.5, weight: 550))
            .foregroundStyle(CalmColor.ink)
            .fixedSize()
    }
}

// MARK: - In-use row

/// “You're using Whisper Small · Picked from all models · In use”: shown
/// under the cards when the model in use isn't one of the three.
struct CalmInUseRow: View {
    let name: String
    var detail = "Picked from all models"
    var state = "In use"
    var isLoading = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous)
        HStack(spacing: 12) {
            CalmRowLabel(title: "You’re using \(name)") { CalmRowDescription(text: detail) }
            if isLoading {
                HStack(spacing: 5) {
                    CalmSpinner(size: 13, weight: 2.4)
                    Text(state)
                }
                .font(CalmFont.note)
                .foregroundStyle(CalmColor.ink2)
            } else {
                Text(state).font(CalmFont.sf(12.5, weight: 600)).foregroundStyle(CalmColor.accent)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(CalmColor.content))
        .overlay(
            RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel + 2, style: .continuous)
                .strokeBorder(CalmColor.ink, lineWidth: 2)
                .padding(-2)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Link row

/// A whole-row link inside a panel: “Browse all 18 models ›”. 16 / 22
/// padding, SF 14/560, muted chevron.
struct CalmLinkRow: View {
    let title: String
    let action: () -> Void

    @Environment(\.calmPreviewInteraction) private var forced
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(CalmFont.rowTitle).foregroundStyle(CalmColor.ink)
                Spacer(minLength: 0)
                CalmIcon(.chevRight, size: 15).foregroundStyle(CalmColor.muted)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, CalmMetrics.rowInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((hovered || forced == .hover) ? CalmColor.panel2 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalmPlainFocusStyle(radius: CalmMetrics.Radius.panel))
        .focusEffectDisabled()
        .onHover { hovered = $0 }
    }
}

// MARK: - Family header

/// A family header in the All models list: logo 28, name 13.5/600, blurb 12.5 muted.
struct CalmFamilyHeader: View {
    let logo: CalmLogoName
    let title: String
    let blurb: String

    var body: some View {
        HStack(spacing: 12) {
            CalmLogo(logo, box: 28)
            Text(title).font(CalmFont.sf(13.5, weight: 600)).foregroundStyle(CalmColor.ink)
            Text(blurb).font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
        }
        .padding(EdgeInsets(top: 16, leading: CalmMetrics.rowInset, bottom: 6, trailing: CalmMetrics.rowInset))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A family's block: header and its rows, a 1 pt line above every family
/// but the first, 6 below the last row.
struct CalmFamilyBlock<Rows: View>: View {
    let logo: CalmLogoName
    let title: String
    let blurb: String
    let isFirst: Bool
    let rows: Rows

    init(logo: CalmLogoName, title: String, blurb: String, isFirst: Bool, @ViewBuilder rows: () -> Rows) {
        self.logo = logo
        self.title = title
        self.blurb = blurb
        self.isFirst = isFirst
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CalmFamilyHeader(logo: logo, title: title, blurb: blurb)
            _VariadicView.Tree(CalmModelRowStack()) { rows }
        }
        .padding(.bottom, 6)
        .overlay(alignment: .top) {
            if !isFirst { Rectangle().fill(CalmColor.line).frame(height: 1) }
        }
    }
}

/// Model rows with a 1 pt line between them, inset 22.
private struct CalmModelRowStack: _VariadicView_UnaryViewRoot {
    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let firstID = children.first?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child.overlay(alignment: .top) {
                    if child.id != firstID {
                        Rectangle().fill(CalmColor.line).frame(height: 1).padding(.horizontal, CalmMetrics.rowInset)
                    }
                }
            }
        }
    }
}

// MARK: - Model row

/// The state on the right of a model row.
enum CalmModelRowTrailing: Equatable {
    case inUse(String = "In use")
    case text(String)
    case download(size: String)
    case downloading(Double)
    case loading(String)
    case setUp(String)
    case failed
}

/// One model in a family panel: radio, name + variant (muted), one meta
/// line (or an amber misfit warning), one state on the right. Clicking
/// the row picks it; right-click (or the more button on hover) opens its
/// menu. Rows inset 22, padding 11.
struct CalmModelRow<Menu: View>: View {
    let name: String
    var variant: String?
    let meta: String
    var warning: String?
    var tag: String?
    let isSelected: Bool
    let trailing: CalmModelRowTrailing
    let onPick: () -> Void
    var onCancel: () -> Void = {}
    @ViewBuilder let menu: () -> Menu

    @Environment(\.calmPreviewInteraction) private var forced
    @Environment(\.isEnabled) private var isEnabled
    @State private var hoveredForReal = false
    @FocusState private var hasFocus: Bool

    private var isHovered: Bool { hoveredForReal || forced == .hover }

    var body: some View {
        HStack(spacing: 14) {
            CalmRadio(isOn: isSelected)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    (Text(name).font(CalmFont.rowTitle).foregroundStyle(CalmColor.ink)
                        + Text(variant.map { " \($0)" } ?? "").font(CalmFont.body).foregroundStyle(CalmColor.muted))
                        .lineLimit(1)
                    if let tag { CalmTag(tag, tone: .warning) }
                }
                if let warning {
                    HStack(spacing: 5) {
                        CalmIcon(.warning, size: 12, weight: 2)
                        Text(warning)
                    }
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.amber)
                } else {
                    Text(meta).font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered || hasFocus { moreButton }
            trailingView
        }
        .padding(.vertical, 11)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((isHovered && isEnabled) ? CalmColor.panel2 : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { onPick() } }
        .onHover { hoveredForReal = $0 }
        .contextMenu { menu() }
        .focusable(isEnabled, interactions: .activate)
        .focused($hasFocus)
        .focusEffectDisabled()
        .onKeyPress(.space) { onPick(); return .handled }
        .overlay {
            if (hasFocus || forced == .focus) && isEnabled {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(CalmColor.focus, lineWidth: 3)
                    .padding(.horizontal, 3)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([name, variant].compactMap { $0 }.joined(separator: " "))
        .accessibilityValue(accessibilityState)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onPick() }
    }

    private var moreButton: some View {
        SwiftUI.Menu {
            menu()
        } label: {
            CalmIconMenuLabel("More for \(name)", icon: .more, size: 16, weight: 2.4)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmIconButtonStyle(size: 28))
        .focusEffectDisabled()
        .fixedSize()
        .accessibilityLabel("More for \(name)")
    }

    @ViewBuilder
    private var trailingView: some View {
        switch trailing {
        case .inUse(let text):
            Text(text).font(CalmFont.sf(12.5, weight: 600)).foregroundStyle(CalmColor.accent).fixedSize()
        case .text(let text):
            Text(text).font(CalmFont.note).foregroundStyle(CalmColor.muted).fixedSize()
        case .download(let size):
            HStack(spacing: 5) {
                CalmIcon(.download, size: 13, weight: 2)
                Text(size)
            }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.muted)
            .fixedSize()
        case .downloading(let progress):
            HStack(spacing: 6) {
                CalmRingProgress(value: progress)
                Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.ink2)
                Button(action: onCancel) { CalmIcon(.close, size: 12, weight: 2) }
                    .calmIconButton(size: 28)
                    .accessibilityLabel("Cancel downloading \(name)")
            }
            .fixedSize()
        case .loading(let status):
            HStack(spacing: 5) {
                CalmSpinner(size: 14, weight: 2.4)
                Text(status)
            }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.ink2)
            .fixedSize()
        case .setUp(let text):
            HStack(spacing: 5) {
                Text(text)
                CalmIcon(.chevRight, size: 13)
            }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.muted)
            .fixedSize()
        case .failed:
            HStack(spacing: 5) {
                CalmIcon(.warning, size: 12, weight: 2)
                Text("Download failed")
            }
            .font(CalmFont.note)
            .foregroundStyle(CalmColor.amber)
            .fixedSize()
        }
    }

    private var accessibilityState: String {
        switch trailing {
        case .inUse(let text), .text(let text), .setUp(let text), .loading(let text): return text
        case .download(let size): return "Not downloaded, \(size)"
        case .downloading(let progress): return "Downloading, \(Int((progress * 100).rounded())) percent"
        case .failed: return "Download failed"
        }
    }
}

// MARK: - Notices

/// A dismissable warning in a panel: icon circle, message, close button.
/// The Models pages show download and delete failures this way.
struct CalmErrorNotice: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            CalmIconCircle(tone: .warning)
            Text(message)
                .font(CalmFont.sf(13.5, weight: 560))
                .foregroundStyle(CalmColor.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) { CalmIcon(.close, size: 14) }
                .calmIconButton(size: 28)
                .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, 14)
        .padding(.leading, CalmMetrics.rowInset)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
        .accessibilityElement(children: .combine)
    }
}
