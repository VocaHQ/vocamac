// LanguageSettingsPage.swift
// VocaMac
//
// The languages the user speaks (the one language setting), the language
// VocaMac listens for, translation, and where vocabulary lives. Picking a
// model is the Speech Model page's job; it reads the same spoken languages.

import SwiftUI

struct LanguageSettingsPage: View {
    @EnvironmentObject var appState: AppState

    private var activeModel: ModelSize? {
        appState.currentModel?.size ?? ModelSize(rawValue: appState.selectedModelSize)
    }

    private var spokenLanguages: Binding<[String]> {
        Binding(
            get: { appState.spokenLanguages },
            set: { appState.setSpokenLanguages($0) }
        )
    }

    private var recognitionChoices: [String] {
        LanguageSync.recognitionChoices(spoken: appState.spokenLanguages, current: appState.selectedLanguage)
    }

    var body: some View {
        VocaSettingsPageContent {
            VocaSettingsGroup(
                "Languages You Speak",
                subtitle: "Recognition and the Speech Model suggestions both follow this list."
            ) {
                SpokenLanguagesField(languages: spokenLanguages)
                Text(spokenLanguagesCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .settingsTarget("spoken-languages")

            VocaSettingsGroup("Recognition Language") {
                Picker("Listen for", selection: $appState.selectedLanguage) {
                    ForEach(recognitionChoices, id: \.self) { code in
                        Text(code == TranscriptionLanguage.auto.code
                             ? TranscriptionLanguage.auto.displayName
                             : SpokenLanguages.displayName(for: code))
                            .tag(code)
                    }
                }

                Text("Auto-detect works well for most cases. Pick one of your languages for better accuracy with it; add a language above to listen for it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

    private var spokenLanguagesCaption: String {
        let spoken = appState.spokenLanguages
        switch spoken.count {
        case 0:
            return "Add the languages you dictate in. Until then, \(AppDistribution.displayName) works out the language each time."
        case 1:
            return "\(AppDistribution.displayName) listens for \(SpokenLanguages.displayName(for: spoken[0])). Add another language if you switch between them."
        default:
            return "\(AppDistribution.displayName) works out which of these you're speaking each time, unless you pick one below."
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
