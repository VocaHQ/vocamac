// AboutTab.swift
// VocaMac
//
// Settings About: this app, the Voca family, and how to reach us.

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
        Form {
            identitySection
            thisMacSection
            familySection
            talkToUsSection
            creditSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingUpdateSheet) {
            if let info = updateInfoForSheet {
                UpdateDetailView(info: info, isPresented: $showingUpdateSheet)
                    .environmentObject(appState)
            }
        }
    }

    private var identitySection: some View {
        Section {
            VStack(spacing: 8) {
                BrandLogoView(size: 64)

                Text("VocaMac")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Voice-to-text for macOS, kept on this Mac.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Link("vocamac.com", destination: URL(string: "https://vocamac.com")!)

                Text("Version \(appVersionDisplay) · \(buildChannelLabel)")
                    .foregroundStyle(.secondary)

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
                    } else {
                        Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                if !updateStatusText.isEmpty {
                    Text(updateStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var thisMacSection: some View {
        Section("This Mac") {
            if let capabilities = appState.systemCapabilities {
                LabeledContent("Device", value: capabilities.processorName)
                LabeledContent(
                    "Architecture",
                    value: capabilities.isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)"
                )
                LabeledContent(
                    "Neural Engine",
                    value: capabilities.supportsMetalAcceleration ? "Available" : "Not Available"
                )
            }
            LabeledContent("Engine", value: activeEngineLabel)
            LabeledContent("Model", value: appState.whisperService.loadedModelName ?? "Not loaded")
            LabeledContent("Storage", value: appState.modelManager.diskUsageDescription())

            Button {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            } label: {
                Label("Show Setup Wizard…", systemImage: "wand.and.stars")
            }
            .help("Re-run the first-launch setup wizard")
        }
    }

    private var familySection: some View {
        Section("Part of VocaHQ") {
            Text("VocaMac is one of the VocaHQ apps (VocaLinux, VocaMac, VocaPhone, VocaGateway). VocaGateway is optional self-hosted compute, not on-device.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(Self.familySites, id: \.host) { site in
                Link(site.host, destination: site.url)
            }
        }
    }

    private var talkToUsSection: some View {
        Section("Talk to us") {
            Text("Bugs and ideas open a GitHub issue. Discord, X, and email are next to that.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Official marks from VocaDesign in VocaHQ/.github
            // brand/vocahq/social @ 61c8eee. github.svg is for Report a bug
            // only. Discord / X / Email hug their labels. Do not stretch.
            Link(destination: AboutSocialMark.github.url) {
                HStack(spacing: 6) {
                    AboutSocialMarkImage(mark: .github, size: 16, tint: nil)
                    Text(AboutSocialMark.github.visibleLabel)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(BrandAssets.settingsTeal)
            .help("Open GitHub issues")

            HStack(spacing: 8) {
                ForEach(AboutSocialMark.talkRowMarks) { mark in
                    talkButton(mark)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func talkButton(_ mark: AboutSocialMark) -> some View {
        Link(destination: mark.url) {
            HStack(spacing: 6) {
                AboutSocialMarkImage(mark: mark, size: 16)
                Text(mark.visibleLabel)
            }
            .foregroundStyle(BrandAssets.settingsTeal)
        }
        .buttonStyle(.bordered)
        .tint(BrandAssets.settingsTeal)
        .help(mark.url.absoluteString)
        .accessibilityLabel(mark.visibleLabel)
    }

    private var creditSection: some View {
        Section {
            HStack(spacing: 0) {
                Text("Made with ❤️ by ")
                    .foregroundStyle(.tertiary)
                Link(
                    "Jatin Kumar Malik",
                    destination: URL(string: "https://x.com/intent/user?screen_name=jatinkrmalik")!
                )
            }
            .font(.caption2)
        }
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
