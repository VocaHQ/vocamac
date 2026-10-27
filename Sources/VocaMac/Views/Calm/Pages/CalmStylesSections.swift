// CalmStylesSections.swift
// VocaMac
//
// The lower half of the Styles page: the switches for per-app styles and
// tone, and the Try it preview. The typed-text rules for every app live in
// Settings › General (`CalmTypedTextGroup`).

import SwiftUI

/// Styles and tone · Try it.
struct CalmStylesSettingsSections: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            CalmStylesToneGroup()
            CalmStylesTryItGroup()
        }
    }
}

// MARK: - Styles and tone

private struct CalmStylesToneGroup: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?

    var body: some View {
        CalmGroup("Styles and tone") {
            CalmPanel {
                CalmToggleRow(
                    "Format text for each app",
                    description: "When off, every app gets the same text.",
                    isOn: $appState.writingStyleEnabled
                )
                CalmToggleRow(
                    "Reword to sound Formal or Casual",
                    description: "Uses the Smart Cleanup model. Names, facts and code stay the same.",
                    isOn: $appState.writingRewriteEnabled
                )
                .calmDisabledByParent(!appState.writingStyleEnabled)
                .settingsTarget("writing-wording")
                if appState.writingRewriteEnabled {
                    CalmRow("Tone everywhere else", description: appState.writingIntent.description) {
                        CalmDropdown(
                            selection: $appState.writingIntent,
                            options: WritingIntent.allCases.map { CalmOption($0, $0.displayName) }
                        )
                    }
                    .calmDisabledByParent(!appState.writingStyleEnabled)
                    if let problem = rewriteProblem {
                        CalmStatusRow(problem.title, description: problem.detail, tone: .warning) {
                            Button("Set up") { navigator?.openSettings(.cleanup) }
                                .calmButton(.primary, size: .small)
                        }
                        .calmDisabledByParent(!appState.writingStyleEnabled)
                    }
                }
            }
        }
    }

    /// Why Formal and Casual can't run yet, if they can't.
    private var rewriteProblem: (title: String, detail: String)? {
        if !appState.transcriptCleanupEnabled {
            return ("Smart Cleanup is off", "Turn it on to use Formal or Casual.")
        }
        if !appState.transcriptCleanup.isDownloaded(appState.selectedCleanupModelKind) {
            return ("Smart Cleanup model isn’t ready", "Finish setting it up to use Formal or Casual.")
        }
        return nil
    }
}

// MARK: - Try it

/// Type what you'd say and see what each style, or one app's rule, types.
private struct CalmStylesTryItGroup: View {
    @EnvironmentObject private var appState: AppState
    @State private var sample = CalmStylesTryItGroup.sampleChips[0].text
    @State private var result: DictationOutputResult?
    @State private var isRunning = false

    /// Ready-made phrases that show what each style does in one click.
    static let sampleChips: [(label: String, text: String)] = [
        ("Filename", "open my file dot md and check the config dot json"),
        ("Path", "edit src slash components slash button dot tsx"),
        ("Identifier", "rename it to camel case handle user input"),
        ("Emphasis", "bold ship this today"),
        ("Sentence", "um so this is a normal sentence"),
    ]

    var body: some View {
        CalmGroup("Try it") {
            VStack(alignment: .leading, spacing: 0) {
                CalmRow("Style", description: "Type what you’d say and see what gets typed.") {
                    targetMenu
                }
                Rectangle().fill(CalmColor.line).frame(height: 1).padding(.horizontal, CalmMetrics.rowInset)
                VStack(alignment: .leading, spacing: 14) {
                    CalmTextField("You say", text: $sample, prompt: "Say something…")
                    HStack(spacing: 6) {
                        ForEach(Self.sampleChips, id: \.label) { chip in
                            Button(chip.label) { sample = chip.text; result = nil }
                                .calmButton(.secondary, size: .small)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("VocaMac types").font(CalmFont.fieldLabel).foregroundStyle(CalmColor.ink)
                        // The field's own font: in monospace the result
                        // read as code next to the “You say” field.
                        Text(styledSample.isEmpty ? "—" : styledSample)
                            .font(CalmFont.field)
                            .foregroundStyle(CalmColor.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: CalmMetrics.Radius.field, style: .continuous).fill(CalmColor.content))
                            .overlay(RoundedRectangle(cornerRadius: CalmMetrics.Radius.field, style: .continuous).strokeBorder(CalmColor.line2, lineWidth: 1))
                    }
                    fullPreview
                }
                .padding(.horizontal, CalmMetrics.rowInset)
                .padding(.vertical, CalmMetrics.rowVerticalPadding)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .calmPanelBackground()
        }
        .settingsTarget("writing-style-preview")
        // The full result belongs to the target it ran for, whichever way
        // the target changed (the menu or opening another Styles tab).
        .onChange(of: previewTarget) { result = nil }
    }

    /// The preview runs the formatting engine only; no model.
    private var styledSample: String {
        appState.writingStylePreview(sample, rules: appState.settingsPreviewRules)
    }

    /// Everything else ("all my settings"): cleanup, tone, numbers, emoji.
    /// It can run the cleanup model, so it stays behind a button.
    @ViewBuilder
    private var fullPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.outputSummary(for: appState.settingsPreviewProfile).description)
                .calmType(.description)
                .fixedSize(horizontal: false, vertical: true)
            if appState.cleanupIsRemote(for: appState.settingsPreviewProfile) {
                CalmInlineNotice("The text is sent to your cleanup endpoint", tone: .info)
            }
            HStack(spacing: 10) {
                Button(isRunning ? "Trying…" : "Try with all my settings") { runFullPreview() }
                    .calmButton(.secondary)
                    .disabled(isRunning || sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isRunning { CalmSpinner() }
            }
            if let result {
                Text(result.summary).calmType(.description).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    comparisonColumn("You said", text: result.original)
                    comparisonColumn("VocaMac typed", text: result.text)
                }
            }
        }
    }

    private func comparisonColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CalmCaption(title)
            Text(text)
                .calmType(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runFullPreview() {
        isRunning = true
        let target = previewTarget
        Task { @MainActor in
            let preview = await appState.previewWritingProfile(sample)
            // A run for a style the person has since moved off is stale.
            if previewTarget == target { result = preview }
            isRunning = false
        }
    }

    /// What Try it previews: a style, or one app's binding.
    private var previewTarget: String {
        appState.settingsPreviewBindingID.map { "binding-\($0)" } ?? "style-\(appState.settingsPreviewStyle.rawValue)"
    }

    // MARK: Target

    private var targetTitle: String {
        if let id = appState.settingsPreviewBindingID,
           let binding = appState.writingStyleBindings.first(where: { $0.id == id }) {
            return "\(binding.displayName) · \(binding.style.displayName)"
        }
        return appState.settingsPreviewStyle.displayName
    }

    private var targetMenu: some View {
        CalmDropdown(title: targetTitle) {
            Section("Styles") {
                ForEach(WritingStyle.allCases) { style in
                    Button {
                        appState.settingsPreviewBindingID = nil
                        appState.settingsPreviewStyle = style
                        result = nil
                    } label: {
                        if appState.settingsPreviewBindingID == nil, appState.settingsPreviewStyle == style {
                            Label(style.displayName, systemImage: "checkmark")
                        } else {
                            Text(style.displayName)
                        }
                    }
                }
            }
            if !appState.writingStyleBindings.isEmpty {
                Section("Your apps") {
                    ForEach(appState.writingStyleBindings) { binding in
                        Button {
                            appState.settingsPreviewBindingID = binding.id
                            appState.settingsPreviewStyle = binding.style
                            result = nil
                        } label: {
                            if appState.settingsPreviewBindingID == binding.id {
                                Label("\(binding.displayName) · \(binding.style.displayName)", systemImage: "checkmark")
                            } else {
                                Text("\(binding.displayName) · \(binding.style.displayName)")
                            }
                        }
                    }
                }
            }
        }
    }
}
