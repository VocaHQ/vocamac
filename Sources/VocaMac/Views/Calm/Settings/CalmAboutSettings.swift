// CalmAboutSettings.swift
// VocaMac
//
// Settings › About, opened from the version in the sheet menu's footer:
// identity and updates, this Mac, what VocaMac is built with and whose
// models it runs, the VocaHQ family, how to reach us, and setup again.

import AppKit
import SwiftUI

/// Settings › About: identity, updates, this Mac, credits, links.
struct CalmAboutSettings: View {
    @EnvironmentObject private var appState: AppState

    @State private var updateInfo: UpdateInfo?
    /// Measured off the main thread when the page opens.
    @State private var modelsOnDisk: String?

    private static let websiteURL = URL(string: "https://vocamac.com")
    private static let sourceURL = URL(string: "https://github.com/VocaHQ/vocamac")

    var body: some View {
        CalmPage(.sheet) {
            identity
                .settingsTarget("about", aliases: ["updates"])

            CalmPanel {
                CalmRow("This Mac", description: thisMacDetail) {
                    Text(thisMac)
                        .font(CalmFont.description)
                        .foregroundStyle(CalmColor.muted)
                        .multilineTextAlignment(.trailing)
                }
                .settingsTarget("system-info")
                CalmRow("Website") { link("vocamac.com", Self.websiteURL) }
                CalmRow("Source code", description: "Open source under AGPL-3.0") { link("GitHub", Self.sourceURL) }
                CalmRow("Built with", description: "WhisperKit · FluidAudio · sherpa-onnx · LLM.swift")
            }

            CalmGroup("On this Mac") {
                CalmPanel {
                    readOnlyRow("Speech model", value: speechModelLabel)
                    if let cleanupModelLabel {
                        readOnlyRow("Smart Cleanup model", value: cleanupModelLabel)
                    }
                    readOnlyRow("Models on disk", value: modelsOnDisk ?? "Measuring…")
                    CalmRow("Set up VocaMac again", description: "Walk through the first-launch setup") {
                        Button("Start setup") {
                            NotificationCenter.default.post(name: .showOnboarding, object: nil)
                        }
                        .calmButton(.secondary)
                    }
                }
            }

            CalmGroup("Model credits") {
                VStack(alignment: .leading, spacing: 10) {
                    CalmAboutCredits()
                    Text("VocaMac runs models made by these teams. Names and logos belong to their owners and are shown for credit only. Logos from Lobe Icons (MIT).")
                        .font(CalmFont.note)
                        .lineSpacing(2.5)
                        .foregroundStyle(CalmColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 2)
                }
            }
            .settingsTarget("model-credits")

            CalmGroup("Part of VocaHQ") {
                CalmAboutFamily()
            }
            .settingsTarget("family")

            CalmGroup("Talk to us") {
                talkPanel
            }
            .settingsTarget("github-issues", aliases: ["discord", "x", "email"])
        }
        .task { modelsOnDisk = await appState.calmModelsDiskUsage() }
        .onChange(of: appState.updateChecker.updateState) { old, new in
            // A check that finds an update (here or from the menu footer) opens it.
            guard old == .checking, let info = Self.availableInfo(new) else { return }
            updateInfo = info
        }
        .calmDialog(item: $updateInfo) { info in
            CalmUpdateDialog(info: info)
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                CalmBrandMark(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("VocaMac").calmType(.title).accessibilityAddTraits(.isHeader)
                    versionLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The App Store build is updated by the App Store, and says
                // nothing about the DMG or Homebrew.
                if AppDistribution.hasSelfUpdate {
                    updateButton
                }
            }
            if AppDistribution.hasSelfUpdate {
                if let problem = CalmAdvancedSummary.updateProblem(appState.updateChecker.updateState) {
                    CalmInlineNotice(problem)
                }
                if case .updateAvailableViaHomebrew(_, let install) = appState.updateChecker.updateState {
                    CalmInlineNotice("Updates come from Homebrew. Run: \(install.upgradeCommand)", tone: .info)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var versionLine: some View {
        let version = CalmSettingsMenu.appVersion
        var line = Text(CalmAdvancedSummary.versionLine(version: version))
        if AppDistribution.hasSelfUpdate, let status = CalmAdvancedSummary.updateStatus(appState.updateChecker.updateState) {
            let color: Color
            switch status.tone {
            case .good: color = CalmColor.accent
            case .quiet: color = CalmColor.muted
            case .problem: color = CalmColor.amber
            }
            line = line + Text(" · ") + Text(status.text).foregroundStyle(color).fontWeight(status.tone == .quiet ? .regular : .semibold)
        }
        return line.calmType(.description)
    }

    @ViewBuilder
    private var updateButton: some View {
        let state = appState.updateChecker.updateState
        if state == .checking {
            Button {} label: {
                HStack(spacing: 8) {
                    CalmSpinner(size: 14)
                    Text("Checking…")
                }
            }
            .calmButton(.secondary)
            .disabled(true)
        } else if let info = Self.pendingInfo(state, last: appState.updateChecker.lastKnownUpdateInfo) {
            Button("See update") { updateInfo = info }.calmButton(.secondary)
        } else {
            Button("Check for updates") {
                Task { await appState.updateChecker.checkForUpdates() }
            }
            .calmButton(.secondary)
        }
    }

    /// The release a state offers right away.
    static func availableInfo(_ state: UpdateState) -> UpdateInfo? {
        switch state {
        case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _): return info
        default: return nil
        }
    }

    /// The release an update in progress belongs to, so the dialog can reopen.
    static func pendingInfo(_ state: UpdateState, last: UpdateInfo?) -> UpdateInfo? {
        if let info = availableInfo(state) { return info }
        switch state {
        case .downloading, .verifying, .readyToInstall, .installing, .installFailed: return last
        case .error: return last
        default: return nil
        }
    }

    // MARK: Rows

    private func link(_ title: String, _ url: URL?) -> some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            Text(title).underline()
        }
        .calmLink(font: CalmFont.sf(13.5, weight: 550))
        .help(url?.absoluteString ?? "")
    }

    private func readOnlyRow(_ title: String, value: String) -> some View {
        CalmRow(title) {
            Text(value)
                .font(CalmFont.description)
                .foregroundStyle(CalmColor.muted)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var talkPanel: some View {
        CalmPanel {
            CalmRow("Report a bug or idea", description: "Opens GitHub issues") {
                Button {
                    NSWorkspace.shared.open(AboutSocialMark.github.url)
                } label: {
                    HStack(spacing: 7) {
                        AboutSocialMarkImage(mark: .github, size: 14)
                        Text("GitHub")
                    }
                }
                .calmButton(.secondary)
                .help("Open GitHub issues")
            }
            CalmRow("Say hello", description: "Discord, X or email") {
                HStack(spacing: 4) {
                    ForEach(AboutSocialMark.talkRowMarks) { mark in
                        Button {
                            NSWorkspace.shared.open(mark.url)
                        } label: {
                            AboutSocialMarkImage(mark: mark, size: mark == .discord ? 18 : 15)
                        }
                        .calmIconButton()
                        .help(mark.visibleLabel)
                        .accessibilityLabel(mark.visibleLabel)
                    }
                }
            }
            CalmRow("Contributors", description: "Made with care by the people who build VocaMac") {
                link("See who", AboutLinks.contributors)
            }
        }
    }

    // MARK: Values

    private var thisMac: String {
        let capabilities = appState.systemCapabilities
        return CalmAdvancedSummary.thisMac(
            processor: capabilities?.processorName, memoryGB: capabilities?.physicalMemoryGB,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    private var thisMacDetail: String? {
        guard let capabilities = appState.systemCapabilities else { return nil }
        return CalmAdvancedSummary.thisMacDetail(
            isAppleSilicon: capabilities.isAppleSilicon, hasNeuralEngine: capabilities.supportsMetalAcceleration
        )
    }

    private var speechModelLabel: String {
        appState.calmLoadedSpeechModelName ?? "Not loaded"
    }

    /// Named only when cleanup is on and its model is on disk.
    private var cleanupModelLabel: String? {
        guard appState.transcriptCleanupEnabled else { return nil }
        let kind = appState.selectedCleanupModelKind
        guard appState.transcriptCleanup.isDownloaded(kind) else { return nil }
        return "\(CalmModelText.name(kind)) · \(kind.descriptor.sizeDescription)"
    }
}

// MARK: - Credits

/// The teams whose models VocaMac runs, two to a line in one panel.
struct CalmAboutCredits: View {
    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            // Credits name the teams whose models VocaMac runs; the user's
            // own server isn't one.
            ForEach(ModelCreator.allCases.filter { $0 != .customEndpoint }) { creator in
                CalmAboutCreditCell(creator: creator)
            }
        }
        .padding(8)
        .calmPanelBackground()
    }
}

private struct CalmAboutCreditCell: View {
    let creator: ModelCreator

    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(creator.url)
        } label: {
            HStack(spacing: 12) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    Text(creator.displayName).font(CalmFont.rowTitle).foregroundStyle(CalmColor.ink)
                    Text(creator.creditedModels).font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CalmIcon(.arrowRight, size: 14)
                    .foregroundStyle(CalmColor.muted)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isHovered ? CalmColor.panel2 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CalmPlainFocusStyle(radius: 10))
        .focusEffectDisabled()
        .onHover { isHovered = $0 }
        .help(creator.url.absoluteString)
        .accessibilityLabel("\(creator.displayName): \(creator.creditedModels). Open their models")
    }

    private var tile: some View {
        ZStack {
            if let image = creator.templateImage() {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Text(creator.monogram)
                    .font(.system(size: creator.monogram.count > 1 ? 10 : 12, weight: .bold))
            }
        }
        .foregroundStyle(CalmColor.ink2)
        .frame(width: 28, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CalmColor.content))
        .accessibilityHidden(true)
    }
}

// MARK: - Family

/// VocaHQ and its apps, as small buttons in one panel.
struct CalmAboutFamily: View {
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            Button {
                NSWorkspace.shared.open(AboutLinks.headquarters)
            } label: {
                HStack(spacing: 8) {
                    CalmBrandMark(size: 18)
                    Text("VocaHQ")
                }
            }
            .calmButton(.secondary, fillsWidth: true)
            .help("vocahq.com")
            // The rest of the family: this page is already about VocaMac.
            ForEach(AboutFamilyProduct.all.filter { $0.title != "VocaMac" }) { product in
                Button {
                    NSWorkspace.shared.open(product.url)
                } label: {
                    HStack(spacing: 6) {
                        ForEach(product.marks) { mark in
                            AboutPlatformMarkImage(mark: mark, size: product.marks.count > 1 ? 13 : 15)
                        }
                        if product.marks.isEmpty {
                            CalmIcon(.system, size: 15)
                        }
                        Text(product.title).padding(.leading, 2)
                    }
                }
                .calmButton(.secondary, fillsWidth: true)
                .help(product.url.absoluteString)
                .accessibilityLabel("\(product.title), \(product.platform)")
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .calmPanelBackground()
    }
}
