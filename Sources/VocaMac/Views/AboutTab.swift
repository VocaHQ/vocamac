// AboutTab.swift
// VocaMac
//
// Settings About: this Mac, the Voca family, and how to reach us.

import SwiftUI

struct AboutTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingUpdateSheet = false
    @State private var updateInfoForSheet: UpdateInfo?

    private static let familySites: [(host: String, url: URL)] = [
        ("vocahq.com", URL(string: "https://vocahq.com")!),
        ("vocalinux.com", URL(string: "https://vocalinux.com")!),
        ("vocamac.com", URL(string: "https://vocamac.com")!),
        ("vocaphone.vocahq.com", URL(string: "https://vocaphone.vocahq.com")!),
        ("vocagateway.vocahq.com", URL(string: "https://vocagateway.vocahq.com")!),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                thisAppCard
                familyCard
                talkToUsCard
                creditLine
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .sheet(isPresented: $showingUpdateSheet) {
            if let info = updateInfoForSheet {
                UpdateDetailView(info: info, isPresented: $showingUpdateSheet)
                    .environmentObject(appState)
            }
        }
    }

    private var thisAppCard: some View {
        GroupBox {
            VStack(spacing: 12) {
                Text("This app")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    BrandLogoView(size: 64)

                    Text("VocaMac")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Voice-to-text for macOS, kept on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Link("vocamac.com", destination: URL(string: "https://vocamac.com")!)
                        .font(.callout)

                    Text("Version \(appVersionDisplay) (\(buildChannelLabel))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)

                Button {
                    Task { @MainActor in
                        await appState.updateChecker.checkForUpdates()
                        switch appState.updateChecker.updateState {
                        case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _):
                            updateInfoForSheet = info
                            showingUpdateSheet = true
                        default:
                            break
                        }
                    }
                } label: {
                    if case .checking = appState.updateChecker.updateState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for Updates...")
                        }
                        .font(.caption)
                    } else {
                        Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .frame(maxWidth: .infinity)

                Text(updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        if let capabilities = appState.systemCapabilities {
                            InfoRow2(label: "Device", value: capabilities.processorName)
                            InfoRow2(
                                label: "Architecture",
                                value: capabilities.isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)"
                            )
                            InfoRow2(
                                label: "Neural Engine",
                                value: capabilities.supportsMetalAcceleration ? "Available" : "Not Available"
                            )
                        }
                        InfoRow2(label: "Engine", value: activeEngineLabel)
                        InfoRow2(label: "Model", value: appState.whisperService.loadedModelName ?? "Not loaded")
                        InfoRow2(label: "Storage", value: appState.modelManager.diskUsageDescription())
                    }
                    .font(.caption)
                    .padding(4)
                }

                Button {
                    NotificationCenter.default.post(name: .showOnboarding, object: nil)
                } label: {
                    Label("Show Setup Wizard…", systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help("Re-run the first-launch setup wizard")
                .frame(maxWidth: .infinity)
            }
            .padding(4)
        }
    }

    private var familyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Part of VocaHQ")
                    .font(.headline)

                Text("VocaMac is one of the VocaHQ apps (VocaLinux, VocaMac, VocaPhone, VocaGateway). VocaGateway is optional self-hosted compute, not on-device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    familyLinkRow
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.familySites, id: \.host) { site in
                            Link(site.host, destination: site.url)
                        }
                    }
                }
                .font(.callout)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var familyLinkRow: some View {
        HStack(spacing: 12) {
            ForEach(Self.familySites, id: \.host) { site in
                Link(site.host, destination: site.url)
            }
        }
    }

    private var talkToUsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Talk to us")
                    .font(.headline)

                Text("Bugs and ideas open a GitHub issue. Discord, X, and email are next to that.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Official marks from VocaDesign in VocaHQ/.github
                // brand/vocahq/social @ 61c8eee. fill is currentColor.
                // The button label color tints them. Do not redraw.
                Link(destination: AboutSocialMark.github.url) {
                    HStack(spacing: 8) {
                        AboutSocialMarkImage(mark: .github, size: 16)
                        Text(AboutSocialMark.github.visibleLabel)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(nsColor: BrandAssets.brandGreen))
                .help("Open GitHub issues")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ForEach(AboutSocialMark.talkRowMarks) { mark in
                            talkButton(mark)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(AboutSocialMark.talkRowMarks) { mark in
                            talkButton(mark)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func talkButton(_ mark: AboutSocialMark) -> some View {
        Link(destination: mark.url) {
            HStack(spacing: 6) {
                AboutSocialMarkImage(mark: mark, size: 16)
                Text(mark.visibleLabel)
            }
        }
        .buttonStyle(.bordered)
        .help(mark.url.absoluteString)
        .accessibilityLabel(mark.visibleLabel)
    }

    private var creditLine: some View {
        HStack(spacing: 0) {
            Text("Made with ❤️ by ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Link("Jatin Kumar Malik", destination: URL(string: "https://x.com/intent/user?screen_name=jatinkrmalik")!)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var activeEngineLabel: String {
        if let engine = appState.currentModel?.size.engine {
            return engine.displayName
        }
        if let name = appState.whisperService.loadedModelName,
           let size = appState.modelManager.modelSize(from: name) {
            return size.engine.displayName
        }
        return "-"
    }

    private var appVersionDisplay: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildChannelLabel: String {
        appVersionDisplay.contains("nightly") ? "Nightly" : "Beta"
    }

    private var updateStatusText: String {
        switch appState.updateChecker.updateState {
        case .upToDate:
            return "You are on the latest version."
        case .updateAvailable(let info):
            return "Update available: \(info.tagName)"
        case .updateAvailableViaHomebrew(_, let install):
            return "Update available via Homebrew. Run: \(install.upgradeCommand)"
        case .error(let message):
            return message
        case .downloading(let progress, _, _, _):
            return "Downloading update... \(Int(progress * 100))%"
        case .verifying:
            return "Verifying download integrity..."
        case .readyToInstall:
            return "Update downloaded. Open the DMG to install."
        case .checking:
            return "Checking for updates..."
        case .idle:
            return ""
        }
    }
}

struct InfoRow2: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
    }
}
