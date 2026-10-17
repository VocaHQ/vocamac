// CalmLanguagesSettings.swift
// VocaMac
//
// Settings › General › Languages (sub-page): the languages you speak (the
// one language setting), whether the speech model understands them, what
// VocaMac listens for, translation, and where vocabulary lives.

import SwiftUI

/// Settings › General › Languages.
struct CalmLanguagesSettings: View {
    @EnvironmentObject private var appState: AppState
    @Environment(CalmNavigator.self) private var navigator: CalmNavigator?

    @State private var isAddingLanguage = false
    /// “Switch model” picks through the same flow as Models, so its cards
    /// show the download and any failure.
    @State private var flow = CalmSpeechPickFlow()

    var body: some View {
        CalmPage(.sheet) {
            CalmSubPageHeader("Languages")
            youSpeakPanel
                .settingsTarget("spoken-languages")
            CalmPanel {
                listenForRow
                    .settingsTarget("language")
                translateRow
                    .settingsTarget("translation")
                vocabularyRow
            }
        }
        .onChange(of: appState.selectedLanguage) {
            Task { @MainActor in await appState.languageDidChange() }
        }
        .calmSpeechPickDialogs(flow)
    }

    // MARK: You speak

    private var spokenLanguages: [String] { appState.spokenLanguages }

    private var youSpeakPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You speak").calmType(.rowTitle)
            FlowLayout(spacing: 8) {
                ForEach(spokenLanguages, id: \.self) { code in
                    CalmLanguageChip(name: SpokenLanguages.displayName(for: code)) {
                        appState.setSpokenLanguages(spokenLanguages.filter { $0 != code })
                    }
                }
                ForEach(CalmSettingsSummary.suggestedLanguages(chosen: spokenLanguages), id: \.self) { code in
                    Button { add(code) } label: {
                        CalmAddChipLabel(title: SpokenLanguages.displayName(for: code))
                    }
                    .buttonStyle(CalmPlainFocusStyle(radius: 9))
                    .focusEffectDisabled()
                    .accessibilityLabel("Add \(SpokenLanguages.displayName(for: code))")
                }
                Button { isAddingLanguage = true } label: {
                    CalmAddChipLabel(title: "Other…")
                }
                .buttonStyle(CalmPlainFocusStyle(radius: 9))
                .focusEffectDisabled()
                .accessibilityLabel("Add another language")
                .popover(isPresented: $isAddingLanguage, arrowEdge: .bottom) {
                    SpokenLanguagePicker(chosen: spokenLanguages) { add($0) }
                }
            }
            Rectangle().fill(CalmColor.line).frame(height: 1)
            CalmLanguageFitNotice(fit: appState.calmLanguageFit) { suggestion in
                switchModel(to: suggestion)
            }
        }
        .padding(.vertical, 20)
        .padding(.horizontal, CalmMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
    }

    private func add(_ code: String) {
        guard !spokenLanguages.contains(code) else { return }
        appState.setSpokenLanguages(spokenLanguages + [code])
    }

    /// “Switch model” picks the suggestion and opens Models, where the
    /// download and switch show. A pick that needs a question first (an
    /// experimental model, stopping another download) asks it here.
    private func switchModel(to suggestion: ModelSize?) {
        if let suggestion {
            flow.pick(suggestion, appState: appState)
            guard flow.prompt == nil, !flow.showsServer else { return }
        }
        navigator?.modelsTab = .speech
        navigator?.select(.models)
    }

    // MARK: Listen for

    private var recognitionChoices: [String] {
        LanguageSync.recognitionChoices(spoken: spokenLanguages, current: appState.selectedLanguage)
    }

    private var recognitionOptions: [CalmOption<String>] {
        recognitionChoices.map {
            CalmOption($0, CalmSettingsSummary.recognitionTitle(code: $0, spokenCount: spokenLanguages.count))
        }
    }

    private var listenForRow: some View {
        CalmRow("Listen for") {
            VStack(alignment: .leading, spacing: 3) {
                CalmRowDescription(
                    text: CalmSettingsSummary.recognitionDetail(selected: appState.selectedLanguage, spoken: spokenLanguages)
                )
                if let model = appState.currentModel?.size, model.bindsLanguageAtLoadTime {
                    CalmRowDescription(text: "\(CalmModelText.name(model)) reloads when this changes.")
                }
            }
        } trailing: {
            if recognitionOptions.count <= 3 {
                CalmSegmentedControl(
                    selection: $appState.selectedLanguage, options: recognitionOptions, accessibilityLabel: "Listen for"
                )
            } else {
                CalmDropdown(selection: $appState.selectedLanguage, options: recognitionOptions)
            }
        }
    }

    // MARK: Translate

    private var activeModel: ModelSize? { appState.calmActiveSpeechModel }

    private var canTranslate: Bool { activeModel?.translatesToEnglish == true }

    private var translationDetail: String {
        guard let activeModel, !canTranslate else {
            return "Type English whatever language you speak. Whisper models only."
        }
        return appState.translationEnabled
            ? "\(CalmModelText.name(activeModel)) wasn’t trained to translate, so speech is typed as spoken."
            : "\(CalmModelText.name(activeModel)) can’t translate. Most Whisper models can."
    }

    private var translateRow: some View {
        CalmRow("Translate into English") {
            VStack(alignment: .leading, spacing: 6) {
                CalmRowDescription(text: translationDetail)
                if !canTranslate {
                    Button("Choose a model that translates") { appState.showModelsThatTranslate() }
                        .calmLink(chevron: true)
                }
            }
        } trailing: {
            CalmSwitch(isOn: $appState.translationEnabled)
                .accessibilityLabel("Translate into English")
                // Never disabled while on, so a model that can't translate
                // can't trap the switch in the on position.
                .disabled(!canTranslate && !appState.translationEnabled)
        }
    }

    // MARK: Vocabulary

    private var vocabularyRow: some View {
        CalmRow(
            "Names and jargon",
            description: activeModel?.engine.supportsCustomVocabulary == true
                ? "Your dictionary spells them your way. This model also listens for them."
                : "Your dictionary spells them your way with every model."
        ) {
            Button("Open Dictionary") { navigator?.show(.dictionary) }
                .calmLink(chevron: true)
        }
    }
}

// MARK: - Fit notice

/// Whether the speech model understands your languages: a teal tick when
/// it does; an amber warning, the model that would, and Switch model when
/// it doesn't (Model parts board, “Language fit”).
struct CalmLanguageFitNotice: View {
    let fit: CalmLanguageFit
    let onSwitch: (ModelSize?) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if fit.spoken.isEmpty || fit.modelName == nil {
                CalmIconCircle(tone: .info)
                Text(fit.modelName == nil ? CalmSettingsSummary.fitTitle(fit)
                     : "Add the languages you dictate in. Until then, VocaMac works out the language each time.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(CalmColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if fit.fits {
                CalmIconCircle(tone: .success)
                Text(CalmSettingsSummary.fitTitle(fit))
                    .font(.system(size: 13.5))
                    .foregroundStyle(CalmColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                CalmIconCircle(tone: .warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CalmSettingsSummary.fitTitle(fit))
                        .font(CalmFont.sf(13.5, weight: 560))
                        .foregroundStyle(CalmColor.ink)
                    if let detail = CalmSettingsSummary.fitDetail(fit) {
                        Text(detail).font(CalmFont.description).foregroundStyle(CalmColor.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(fit.suggestion == nil ? "See models" : "Switch model") { onSwitch(fit.suggestion) }
                    .calmButton(.primary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chips

/// A spoken language: content fill, 1 pt line2, r9, h34, with a remove button.
struct CalmLanguageChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
        HStack(spacing: 6) {
            Text(name).font(CalmFont.button).foregroundStyle(CalmColor.ink)
            Button(action: onRemove) {
                CalmIcon(.close, size: 12, weight: 2)
            }
            .calmIconButton(size: 24)
            .accessibilityLabel("Remove \(name)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: CalmMetrics.buttonHeight)
        .background(shape.fill(CalmColor.content))
        .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1))
    }
}

/// An add chip: no fill, 1.5 pt line2 outline, ink2 text after a plus.
struct CalmAddChipLabel: View {
    let title: String

    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.button, style: .continuous)
        HStack(spacing: 6) {
            CalmIcon(.plus, size: 12, weight: 2)
            Text(title).font(CalmFont.control)
        }
        .foregroundStyle(isHovered ? CalmColor.ink : CalmColor.ink2)
        .padding(.horizontal, 12)
        .frame(height: CalmMetrics.buttonHeight)
        .background(shape.fill(isHovered ? CalmColor.panel2 : .clear))
        .overlay(shape.strokeBorder(CalmColor.line2, lineWidth: 1.5))
        .contentShape(shape)
        .onHover { isHovered = $0 }
    }
}
