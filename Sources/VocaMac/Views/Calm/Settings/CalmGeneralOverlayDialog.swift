// CalmGeneralOverlayDialog.swift
// VocaMac
//
// The While you talk picker (Dialogs board): Off / Minimal / Live cards
// with small previews of the real overlay, where it sits, and a Preview
// button that plays the overlay for a few seconds. Applies immediately.

import SwiftUI

/// What shows on screen while dictating, and where.
struct CalmOverlayDialog: View {
    @EnvironmentObject private var appState: AppState

    private struct Choice {
        let style: OverlayStyle
        let title: String
        let detail: String
    }

    private static let styles = [
        Choice(style: .off, title: "Off", detail: "Nothing"),
        Choice(style: .minimal, title: "Minimal", detail: "Small pill"),
        Choice(style: .live, title: "Live", detail: "Words as you speak"),
    ]

    var body: some View {
        CalmDialog("While you talk", description: "What you see on screen while dictating.", width: CalmMetrics.dialogListWidth) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Self.styles, id: \.style) { item in
                    CalmOverlayStyleCard(
                        title: item.title, detail: item.detail, style: item.style,
                        isSelected: appState.overlayStyle == item.style
                    ) {
                        appState.setOverlayStyle(item.style)
                    }
                }
            }
            // Cards share the tallest card's height, not the dialog's.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Overlay style")
            HStack(spacing: 16) {
                Text("Position").calmType(.rowTitle)
                Spacer(minLength: 0)
                CalmDropdown(
                    selection: $appState.overlayPosition,
                    options: OverlayPosition.allCases.map { CalmOption($0, CalmSettingsSummary.overlayPositionTitle($0)) }
                )
            }
            .calmDisabledByParent(appState.overlayStyle == .off)
            if appState.overlayStyle == .off {
                Text("A short message still appears if a dictation fails.")
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                    .padding(.top, -8)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {}, leading: {
                Button {
                    appState.overlayPreview.start(style: appState.overlayStyle, position: appState.overlayPosition)
                } label: {
                    CalmButtonLabel("Preview", icon: .play)
                }
                .calmButton(.quiet)
                .disabled(appState.overlayStyle == .off || appState.appStatus != .idle)
                .help("Shows the overlay for a few seconds with sample words")
            })
        }
        .onDisappear { appState.overlayPreview.stop() }
    }
}

/// One overlay choice: a preview tile over a radio, title and line.
/// The whole card is the button.
struct CalmOverlayStyleCard: View {
    let title: String
    let detail: String
    let style: OverlayStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                CalmOverlayPreviewTile(style: style)
                HStack(alignment: .top, spacing: 8) {
                    CalmRadio(isOn: isSelected)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(CalmColor.ink)
                        Text(detail).font(.system(size: 12)).foregroundStyle(CalmColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding([.horizontal, .bottom], 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .calmCard(selected: isSelected, radius: 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(CalmPlainFocusStyle(radius: 12))
        .focusEffectDisabled()
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The 80-point preview inside an overlay card, drawn like the real
/// overlay: the dark HUD pill with bars, or the panel with words.
struct CalmOverlayPreviewTile: View {
    let style: OverlayStyle

    private static let hud = Color(nsColor: CalmNSColor.rgb(0x141C19, 0.94))
    private static let hudText = Color(nsColor: CalmNSColor.rgb(0xEDF2EE))
    private static let hudBars = Color(nsColor: CalmNSColor.rgb(0x55C2A0))

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(CalmColor.panel)
            .frame(height: 80)
            .overlay(alignment: .bottom) {
                Group {
                    switch style {
                    case .off:
                        Text("Menu bar only")
                            .font(.system(size: 11.5))
                            .foregroundStyle(CalmColor.muted)
                            .padding(.bottom, 22)
                    case .minimal: pill
                    case .live: panel
                    }
                }
                .padding(.bottom, 12)
            }
            .accessibilityHidden(true)
    }

    private var pill: some View {
        HStack(spacing: 2) {
            ForEach(Array([6, 10, 7, 11, 5].enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1).fill(Self.hudBars).frame(width: 2, height: CGFloat(height))
            }
        }
        .frame(width: 60, height: 20)
        .background(Capsule().fill(Self.hud).shadow(color: .black.opacity(0.35), radius: 10, y: 8))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Self.hudText.opacity(0.85)).frame(width: 85, height: 3)
            Capsule().fill(Self.hudText.opacity(0.5)).frame(width: 56, height: 3)
        }
        .padding(8)
        .frame(width: 110, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Self.hud).shadow(color: .black.opacity(0.35), radius: 10, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
    }
}
