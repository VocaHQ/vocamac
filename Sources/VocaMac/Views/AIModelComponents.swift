// AIModelComponents.swift
// VocaMac
//
// Pieces the Smart Cleanup and Command Mode pages share: the feature row at
// the top of each page, its status line, the model menu, and the list of
// on-device models a feature can run.

import SwiftUI

// MARK: - Feature Row

/// One feature: what it does, the model it runs, and a status line only when
/// there is something to know.
struct AIFeatureRow<Trailing: View, Status: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let status: Status

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                trailing
            }
            status
                .padding(.leading, 42)
        }
    }
}

struct AIStatusLine: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// One download runs at a time, whichever feature asked for it, so both
/// pages show it.
struct AIModelDownloadProgress: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if case .downloading(let kind, let progress) = appState.transcriptCleanup.modelState {
            Divider()
            HStack(spacing: 10) {
                ProgressView(value: progress)
                    .frame(width: 110)
                Text("Downloading \(kind.descriptor.displayName) — \(Int(progress * 100))%")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    appState.cancelCleanupDownload()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Sharing Tip

/// Points out, where the choice is made, that one model can run both
/// features. Shown until the person shares a model or chooses not to.
struct AIModelSharingTip: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        if appState.suggestsSharingAIModel {
            let kind = appState.sharedAIModelCandidate
            HStack(alignment: .top, spacing: 12) {
                HStack(spacing: -6) {
                    tipIcon("sparkles", tint: VocaDesign.accentSolid)
                    tipIcon("wand.and.stars", tint: VocaDesign.command)
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("One model can do both")
                        .font(.headline)
                    Text(detail(for: kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Use \(kind.descriptor.displayName) for Both") {
                            Task { @MainActor in await appState.setSharesAIModel(true) }
                        }
                        .controlSize(.small)
                        Button("Keep Separate") {
                            Task { @MainActor in await appState.setSharesAIModel(false) }
                        }
                        .buttonStyle(.vocaLink)
                        .controlSize(.small)
                    }
                    .padding(.top, 4)
                    .disabled(isDownloading)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VocaDesign.command.opacity(0.07))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(VocaDesign.command.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private var isDownloading: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return false
    }

    /// What sharing saves, and what it costs when the shared model is
    /// slower at cleanup than the one in use.
    private func detail(for kind: CleanupModelKind) -> String {
        var text = "Smart Cleanup and Command Mode can run on the same model: one download and one model in memory."
        // Only a Mac that can't keep both loaded makes edits wait for a swap.
        if case .local(let commandKind) = appState.commandModeEngine,
           !appState.usesSeparateCommandSlot(for: commandKind) {
            text += " Edits also start sooner, without waiting for a second model to load."
        }
        let current = appState.selectedCleanupModelKind
        if kind != current, kind.isSlowForCleanup || kind.descriptor.ramRequiredGB > current.descriptor.ramRequiredGB {
            text += " Cleanup would use \(kind.descriptor.displayName) instead of \(current.descriptor.displayName), which takes a little longer per dictation."
        }
        if !appState.transcriptCleanup.isDownloaded(kind) {
            text += " Downloads \(kind.descriptor.sizeDescription)."
        }
        return text
    }

    private func tipIcon(_ systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(VocaDesign.surface, in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Model Menu

/// Pick the model for one feature. Undownloaded models say so and download
/// when chosen.
struct AIModelMenu: View {
    @EnvironmentObject var appState: AppState
    let role: AIModelRole

    var body: some View {
        Menu {
            ForEach(localChoices) { kind in
                VocaMenuChoice(title: menuTitle(kind), isSelected: isSelected(kind)) {
                    Task { @MainActor in await appState.useAIModel(kind, for: role) }
                }
            }
            if !otherEngines.isEmpty {
                Divider()
                ForEach(otherEngines) { engine in
                    VocaMenuChoice(title: Self.title(for: engine, appState: appState), isSelected: appState.commandModeEngine == engine) {
                        appState.selectCommandModeEngine(engine)
                    }
                }
            }
        } label: {
            // A chevron, so the model name reads as a choice rather than
            // a button that does something.
            HStack(spacing: 6) {
                Text(currentName)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isUnavailable)
        .help(role == .cleanup ? "The model that cleans up dictations" : "What runs Command Mode edits")
    }

    private var localChoices: [CleanupModelKind] {
        role == .cleanup ? CleanupModelKind.cleanupChoices : CleanupModelKind.commandModeChoices
    }

    private var otherEngines: [CommandModeEngine] {
        guard role == .commandMode else { return [] }
        var engines: [CommandModeEngine] = []
        if appState.appleIntelligenceAvailable() || appState.commandModeEngine == .appleIntelligence {
            engines.append(.appleIntelligence)
        }
        if !appState.cleanupEndpoint.isLocal, appState.cleanupEndpoint.validationProblem() == nil {
            engines.append(.endpoint)
        }
        return engines
    }

    private func isSelected(_ kind: CleanupModelKind) -> Bool {
        role == .cleanup
            ? appState.selectedCleanupModelKind == kind
            : appState.commandModeEngine == .local(kind)
    }

    private func menuTitle(_ kind: CleanupModelKind) -> String {
        var title = kind.descriptor.displayName
        if role == .cleanup, appState.sharesAIModel, !kind.supportsCommandMode {
            title += " (cleanup only)"
        }
        if !appState.transcriptCleanup.isDownloaded(kind) {
            title += " — download \(kind.descriptor.sizeDescription)"
        }
        return title
    }

    private var currentName: String {
        switch role {
        case .cleanup:
            return appState.cleanupEndpoint.isLocal
                ? appState.selectedCleanupModelKind.descriptor.displayName
                : appState.cleanupEndpoint.provider.displayName
        case .commandMode, .both:
            return Self.title(for: appState.commandModeEngine, appState: appState)
        }
    }

    /// What the menu calls an engine. The cleanup endpoint goes by its
    /// provider, the name people chose it by on the Smart Cleanup page.
    static func title(for engine: CommandModeEngine, appState: AppState) -> String {
        guard engine == .endpoint, !appState.cleanupEndpoint.isLocal else { return engine.displayName }
        return "\(appState.cleanupEndpoint.provider.displayName) server"
    }

    private var isUnavailable: Bool {
        if case .downloading = appState.transcriptCleanup.modelState { return true }
        return role == .cleanup && !appState.cleanupEndpoint.isLocal
    }
}

// MARK: - Model Library

/// The on-device models one feature can run. Anything downloaded, in use,
/// downloading, or suggested for this Mac stays visible; the rest wait
/// behind one disclosure row.
struct AIModelLibrary: View {
    @EnvironmentObject var appState: AppState
    let role: AIModelRole
    @State private var isMoreExpanded = false

    var body: some View {
        let choices = role == .cleanup ? CleanupModelKind.cleanupChoices : CleanupModelKind.commandModeChoices
        let prominent = choices.filter(isProminent)
        let more = choices.filter { !isProminent($0) }
        VocaSettingsGroup("On-Device Models", subtitle: subtitle) {
            ForEach(prominent) { kind in
                AIModelLibraryRow(kind: kind, role: role)
                if kind != prominent.last || !more.isEmpty {
                    Divider()
                }
            }
            if !more.isEmpty {
                DisclosureGroup(isExpanded: $isMoreExpanded) {
                    ForEach(more) { kind in
                        AIModelLibraryRow(kind: kind, role: role)
                        if kind != more.last {
                            Divider()
                        }
                    }
                } label: {
                    Text("\(more.count) more \(more.count == 1 ? "model" : "models")")
                }
                .disclosureGroupStyle(VocaDisclosureGroupStyle())
            }
        }
    }

    private var subtitle: String {
        role == .cleanup
            ? "Downloaded once, then runs on this Mac without a network."
            : "Downloaded once, then runs on this Mac. Each of these can run Smart Cleanup too, so one download can serve both."
    }

    private func isProminent(_ kind: CleanupModelKind) -> Bool {
        if case .downloading(let active, _) = appState.transcriptCleanup.modelState, active == kind {
            return true
        }
        let suggestion = appState.cleanupModelSuggestion
        switch role {
        case .cleanup:
            return appState.transcriptCleanup.isDownloaded(kind)
                || appState.selectedCleanupModelKind == kind
                || suggestion.cleanup == kind
        case .commandMode, .both:
            return appState.transcriptCleanup.isDownloaded(kind)
                || appState.commandModeEngine == .local(kind)
                || suggestion.commandMode == kind
        }
    }
}

/// One downloadable model as one feature sees it: who made it, its size,
/// and one control to download or use it. A download used by the other
/// feature says so, since deleting it would affect both.
private struct AIModelLibraryRow: View {
    @EnvironmentObject var appState: AppState
    let kind: CleanupModelKind
    let role: AIModelRole
    @State private var showDeleteAlert = false

    private var descriptor: CleanupModelDescriptor { kind.descriptor }
    private var isDownloaded: Bool { appState.transcriptCleanup.isDownloaded(kind) }
    private var usedForCleanup: Bool {
        appState.cleanupEndpoint.isLocal && appState.selectedCleanupModelKind == kind
    }
    private var usedForCommands: Bool { appState.commandModeEngine == .local(kind) }
    private var usedHere: Bool { role == .cleanup ? usedForCleanup : usedForCommands }
    private var usedByOther: Bool { role == .cleanup ? usedForCommands : usedForCleanup }
    private var isSuggested: Bool {
        let suggestion = appState.cleanupModelSuggestion
        return role == .cleanup ? suggestion.cleanup == kind : suggestion.commandMode == kind
    }
    private var downloadProgress: Double? {
        if case .downloading(let active, let progress) = appState.transcriptCleanup.modelState, active == kind {
            return progress
        }
        return nil
    }
    private var isDownloadingAnother: Bool {
        if case .downloading(let active, _) = appState.transcriptCleanup.modelState { return active != kind }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            ModelCreatorMark(creator: kind.creator, isActive: usedHere && isDownloaded)
                .padding(.trailing, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(descriptor.displayName)
                        .font(.callout)
                        .fontWeight(usedHere ? .semibold : .regular)
                    if isSuggested {
                        RecommendedBadge(reason: appState.cleanupModelSuggestion.reason)
                    }
                }
                HStack(spacing: 4) {
                    Text(kind.creator.displayName)
                    Text("•")
                    Text(descriptor.sizeDescription)
                    Text("•")
                    Text("~\(String(format: "%.1f", descriptor.ramRequiredGB)) GB RAM")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Where one download could serve both features, say so in
                // the other feature's colour.
                if usedByOther {
                    otherFeatureTag(role == .cleanup ? "Also runs Command Mode" : "Also runs Smart Cleanup", isInUse: true)
                } else if role == .cleanup && kind.supportsCommandMode {
                    otherFeatureTag("Can run Command Mode too", isInUse: false)
                }
            }
            .help(descriptor.summary)

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
        .alert("Delete \(descriptor.displayName)?", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { appState.deleteCleanupModel(kind) }
        } message: {
            Text("Removes \(descriptor.sizeDescription) from disk. You can download it again later.")
        }
    }

    private func otherFeatureTag(_ title: String, isInUse: Bool) -> some View {
        let color = role == .cleanup ? VocaDesign.command : VocaDesign.accentSolid
        return Label(title, systemImage: isInUse ? "link" : "wand.and.stars")
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(isInUse ? 0.16 : 0.08), in: Capsule())
    }

    @ViewBuilder
    private var trailing: some View {
        if let progress = downloadProgress {
            HStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(width: 60)
                Text("\(Int(progress * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if usedHere && isDownloaded {
            Label("In use", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(role == .cleanup ? VocaDesign.accentSolid : VocaDesign.command)
        } else {
            HStack(spacing: 8) {
                Button(isDownloaded ? "Use" : "Download & Use") {
                    Task { @MainActor in await appState.useAIModel(kind, for: role) }
                }
                .controlSize(.small)
                .disabled(isDownloadingAnother)
                .help(appState.sharesAIModel && kind.supportsCommandMode
                      ? "Smart Cleanup and Command Mode share a model, so both will use it"
                      : "")
                if !isDownloaded {
                    // Getting a model ready for later, say before going
                    // offline, shouldn't switch what either feature runs.
                    Button {
                        Task { @MainActor in await appState.downloadAIModel(kind) }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(isDownloadingAnother)
                    .help("Download only, without using it yet")
                    .accessibilityLabel("Download \(descriptor.displayName) only")
                }
                if isDownloaded && !usedByOther {
                    Button {
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Delete download")
                }
            }
        }
    }
}

private struct RecommendedBadge: View {
    let reason: String

    var body: some View {
        Text("Recommended")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(VocaDesign.accent.opacity(0.12))
            .foregroundStyle(VocaDesign.accent)
            .cornerRadius(4)
            .help("Recommended for your Mac. \(reason)")
    }
}
