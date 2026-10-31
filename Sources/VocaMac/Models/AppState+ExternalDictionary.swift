// AppState+ExternalDictionary.swift
// VocaMac
//
// Picks up Dictionary changes made by another process — the MCP server
// (`VocaMac --mcp`) adding a term for a coding agent — so Settings and the
// next dictation see them without a relaunch.

import Combine
import Foundation

extension AppState {
    /// Reload the Dictionary whenever another process says it changed it.
    func externalDictionaryChanges() -> AnyCancellable {
        DistributedNotificationCenter.default()
            .publisher(for: DictionaryPreferences.externalChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadDictionaryFromPreferences() }
            }
    }

    /// Read the vocabulary and replacements back from preferences, after
    /// making sure this process sees what the other one wrote.
    func reloadDictionaryFromPreferences(defaults: UserDefaults = .standard) {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let stored = DictionaryPreferences(defaults: defaults).replacements
        if stored != wordReplacements {
            wordReplacements = stored
        }
        // The vocabulary is read from preferences on every access; views
        // only need to be told to read it again.
        objectWillChange.send()
        VocaLogger.info(.appState, "Dictionary reloaded after a change from another process")
    }
}
