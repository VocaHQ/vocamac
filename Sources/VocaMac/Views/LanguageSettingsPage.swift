// LanguageSettingsPage.swift
// VocaMac
//
// The language VocaMac listens for, translation, and where vocabulary lives.
// Picking a model is the Speech Model page's job.

import SwiftUI

struct LanguageSettingsPage: View {
    @EnvironmentObject var appState: AppState
    @State private var languageSearch = ""

    private var filteredLanguages: [TranscriptionLanguage] {
        TranscriptionLanguage.filtered(search: languageSearch)
    }

    private var activeModel: ModelSize? {
        appState.currentModel?.size ?? ModelSize(rawValue: appState.selectedModelSize)
    }

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup("Recognition Language") {
                TextField("Search languages", text: $languageSearch)
                    .textFieldStyle(.voca)

                Picker("Language", selection: $appState.selectedLanguage) {
                    ForEach(filteredLanguages) { language in
                        Text(language.code == "auto"
                             ? language.displayName
                             : "\(language.displayName) (\(language.code))")
                            .tag(language.code)
                    }
                }

                if !filteredLanguages.contains(where: { $0.code == appState.selectedLanguage }),
                   let current = TranscriptionLanguage.catalog.first(where: { $0.code == appState.selectedLanguage }) {
                    Text("Current: \(current.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Auto-detect works well for most cases. Set a specific language for better accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let model = appState.currentModel?.size, model.bindsLanguageAtLoadTime {
                    Text("\(model.displayName) applies the language when it loads, so changing it reloads the model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .settingsTarget("language")

            VocaSettingsGroup("Translation") {
                SettingsToggleRow(
                    title: "Translate what you say",
                    detail: translationCaption,
                    isOn: $appState.translationEnabled
                )
                // Never disabled while on, so a model that can't translate
                // can't trap the switch in the on position.
                .disabled(activeModel?.translatesToEnglish != true && !appState.translationEnabled)

                if activeModel?.translatesToEnglish != true {
                    Button("Choose a Model That Translates") {
                        appState.showModelsThatTranslate()
                    }
                    .controlSize(.small)
                }
            }
            .settingsTarget("translation")

            VocaSettingsGroup("Vocabulary") {
                HStack {
                    Text(activeModel?.engine.supportsCustomVocabulary == true
                         ? "Your dictionary spells names your way with every model; this model also uses it as a recognition hint."
                         : "Your dictionary spells names your way with every model.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 16)
                    Button("Open Dictionary") { appState.requestSettingsPage(.dictionary) }
                }
            }
        }
        .onChange(of: appState.selectedLanguage) {
            Task { @MainActor in
                await appState.languageDidChange()
            }
        }
    }

    private var translationCaption: String {
        if let activeModel, !activeModel.translatesToEnglish {
            return appState.translationEnabled
                ? "\(activeModel.displayName) wasn't trained to translate, so speech is typed as spoken."
                : "\(activeModel.displayName) can't translate. Choose a model that can."
        }
        return appState.translationEnabled
            ? "Speech is translated to the language above, or English when it's set to Auto-detect."
            : "Speech is typed in the language you speak."
    }
}
