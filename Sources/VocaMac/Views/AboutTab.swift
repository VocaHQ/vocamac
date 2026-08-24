// AboutTab.swift
// VocaMac
//
// Settings About: this app, the Voca family, and how to reach us.

import SwiftUI

struct AboutTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingUpdateSheet = false
    @State private var updateInfoForSheet: UpdateInfo?

    var body: some View {
        Form {
            identitySection
            thisMacSection
            familySection
            talkToUsSection
            contributorsSection
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
            HStack(spacing: 8) {
                Link(destination: AboutLinks.headquarters) {
                    BrandMarkView(size: 23)
                        .frame(minWidth: 36, minHeight: 30)
                }
                .buttonStyle(.bordered)
                .help("vocahq.com")
                .accessibilityLabel("VocaHQ")

                ForEach(AboutFamilyProduct.all) { product in
                    familyProductLink(product)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func familyProductLink(_ product: AboutFamilyProduct) -> some View {
        Link(destination: product.url) {
            HStack(spacing: 4) {
                ForEach(product.marks) { mark in
                    AboutPlatformMarkImage(
                        mark: mark,
                        size: product.marks.count > 1 ? 19 : 23
                    )
                }
                if let systemImage = product.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 21))
                        .accessibilityHidden(true)
                }
            }
            .frame(
                minWidth: product.marks.count > 1 ? 50 : 36,
                minHeight: 30
            )
        }
        .buttonStyle(.bordered)
        .help(product.url.absoluteString)
        .accessibilityLabel("\(product.title), \(product.platform)")
    }

    private var talkToUsSection: some View {
        Section("Talk to us") {
            HStack(spacing: 8) {
                Link(destination: AboutSocialMark.github.url) {
                    HStack(spacing: 6) {
                        AboutSocialMarkImage(mark: .github, size: 16)
                        Text(AboutSocialMark.github.visibleLabel)
                    }
                }
                .buttonStyle(.bordered)
                .help("Open GitHub issues")

                ForEach(AboutSocialMark.talkRowMarks) { mark in
                    talkButton(mark)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func talkButton(_ mark: AboutSocialMark) -> some View {
        Link(destination: mark.url) {
            AboutSocialMarkImage(mark: mark, size: mark == .discord ? 19 : 16)
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.bordered)
        .help(mark.visibleLabel)
        .accessibilityLabel(mark.visibleLabel)
    }

    private var contributorsSection: some View {
        Section {
            HStack(spacing: 0) {
                Text("Made with ❤️ by ")
                    .foregroundStyle(.tertiary)
                Link("Our contributors", destination: AboutLinks.contributors)
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
