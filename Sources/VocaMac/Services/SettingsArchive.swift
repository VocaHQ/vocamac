// SettingsArchive.swift
// VocaMac

import Foundation

struct SettingsArchive: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var exportedAt: Date = Date()
    var values: [String: Value]

    enum Value: Codable, Equatable {
        case bool(Bool), integer(Int), double(Double), string(String), data(Data), strings([String])

        private enum CodingKeys: String, CodingKey { case type, bool, integer, double, string, data, strings }
        private enum Kind: String, Codable { case bool, integer, double, string, data, strings }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            switch try box.decode(Kind.self, forKey: .type) {
            case .bool: self = .bool(try box.decode(Bool.self, forKey: .bool))
            case .integer: self = .integer(try box.decode(Int.self, forKey: .integer))
            case .double: self = .double(try box.decode(Double.self, forKey: .double))
            case .string: self = .string(try box.decode(String.self, forKey: .string))
            case .data: self = .data(try box.decode(Data.self, forKey: .data))
            case .strings: self = .strings(try box.decode([String].self, forKey: .strings))
            }
        }

        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .bool(let value): try box.encode(Kind.bool, forKey: .type); try box.encode(value, forKey: .bool)
            case .integer(let value): try box.encode(Kind.integer, forKey: .type); try box.encode(value, forKey: .integer)
            case .double(let value): try box.encode(Kind.double, forKey: .type); try box.encode(value, forKey: .double)
            case .string(let value): try box.encode(Kind.string, forKey: .type); try box.encode(value, forKey: .string)
            case .data(let value): try box.encode(Kind.data, forKey: .type); try box.encode(value, forKey: .data)
            case .strings(let value): try box.encode(Kind.strings, forKey: .type); try box.encode(value, forKey: .strings)
            }
        }
    }
}

enum SettingsArchiveService {
    /// The kind of value each exported setting holds, matching how the app
    /// stores it (`@AppStorage` raw values, or JSON as a string or data).
    enum Kind { case bool, integer, double, string, data }

    /// Deliberate allowlist, with the kind each value must have: user content
    /// (history, stats, scratchpad) and the cleanup endpoint and API key are
    /// not settings backups. Neither is the Command Mode clipboard opt-in: a
    /// privacy consent is given in Settings, never by importing a file.
    static let kinds: [String: Kind] = [
        // Switches
        "vocamac.launchAtLogin": .bool, "vocamac.preserveClipboard": .bool,
        "vocamac.showCursorIndicator": .bool, "vocamac.soundEffectsEnabled": .bool,
        "vocamac.translationEnabled": .bool, PreferenceKey.appendTrailingSpace: .bool,
        PreferenceKey.autoCapitalize: .bool, PreferenceKey.autoPauseEnabled: .bool,
        PreferenceKey.duckOtherAudioEnabled: .bool, PreferenceKey.escapeCancelsDictation: .bool,
        PreferenceKey.externalMicWhenLidClosed: .bool, PreferenceKey.historyEnabled: .bool,
        PreferenceKey.historyKeepsAudio: .bool, PreferenceKey.modelKeepAliveEnabled: .bool,
        PreferenceKey.numbersAsDigits: .bool, PreferenceKey.spokenEmoji: .bool,
        PreferenceKey.transcriptCleanupEnabled: .bool, PreferenceKey.useScreenContext: .bool,
        PreferenceKey.aiModelsKeptSeparate: .bool,
        PreferenceKey.writingRewriteEnabled: .bool, PreferenceKey.writingStyleEnabled: .bool,
        // Whole numbers
        "vocamac.hotKeyCode": .integer, "vocamac.hotKeyModifiers": .integer,
        "vocamac.maxRecordingDuration": .integer, "vocamac.selectedAudioChannel": .integer,
        "vocamac.selectedAudioChannelCount": .integer, PreferenceKey.mouseTriggerButton: .integer,
        // Decimals
        "vocamac.doubleTapThreshold": .double, "vocamac.silenceDuration": .double,
        "vocamac.silenceThreshold": .double, PreferenceKey.autoPausePollInterval: .double,
        PreferenceKey.modelKeepAliveIdleTimeout: .double,
        // Text, enum raw values, and JSON stored as text
        "vocamac.activationMode": .string, "vocamac.customVocabulary": .string,
        "vocamac.logLevel": .string, "vocamac.overlayPosition": .string,
        "vocamac.overlayStyle": .string, "vocamac.selectedAudioChannelDeviceID": .string,
        "vocamac.selectedAudioDeviceID": .string, "vocamac.selectedAudioDeviceName": .string,
        PreferenceKey.autoPauseApps: .string, PreferenceKey.commandModeShortcut: .string,
        PreferenceKey.commandModeEngine: .string, PreferenceKey.dictationTone: .string,
        PreferenceKey.handsFreeShortcut: .string, PreferenceKey.historyRetention: .string,
        PreferenceKey.learnCorrectionsMode: .string, PreferenceKey.pasteLastShortcut: .string,
        PreferenceKey.selectedLanguage: .string, PreferenceKey.selectedModelSize: .string,
        PreferenceKey.transcriptCleanupLevel: .string, PreferenceKey.transcriptCleanupModel: .string,
        PreferenceKey.transcriptCleanupPrompt: .string, PreferenceKey.websiteStyleBindings: .string,
        PreferenceKey.writingIntent: .string, PreferenceKey.writingStyleBindings: .string,
        PreferenceKey.writingStyleDefault: .string,
        // JSON stored as data
        "vocamac.snippets": .data, PreferenceKey.wordReplacements: .data,
    ]

    static var keys: Set<String> { Set(kinds.keys) }

    /// The microphone choice names a device on the Mac that exported it.
    /// These keys are restored together, and only when that device is here.
    static let inputDeviceKeys: Set<String> = [
        "vocamac.selectedAudioDeviceID", "vocamac.selectedAudioDeviceName",
        "vocamac.selectedAudioChannel", "vocamac.selectedAudioChannelCount",
        "vocamac.selectedAudioChannelDeviceID",
    ]

    static func make(defaults: UserDefaults = .standard) -> SettingsArchive {
        var values: [String: SettingsArchive.Value] = [:]
        for key in keys {
            guard let raw = defaults.object(forKey: key), let value = value(of: raw) else { continue }
            values[key] = value
        }
        return SettingsArchive(values: values)
    }

    private static func value(of raw: Any) -> SettingsArchive.Value? {
        // Check the CF type first: an NSNumber holding 0 or 1 bridges to
        // Bool too, which would export a stored Int or Double as a Bool.
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        } else if let number = raw as? NSNumber, !CFNumberIsFloatType(number) {
            return .integer(number.intValue)
        } else if let value = raw as? Double { return .double(value) }
        else if let value = raw as? String { return .string(value) }
        else if let value = raw as? Data { return .data(value) }
        else if let value = raw as? [String] { return .strings(value) }
        return nil
    }

    /// Whether an imported value has the kind the app reads for its key, so
    /// an edited backup can't put a string where the app reads an integer —
    /// whether or not the setting was ever saved on this Mac. A whole number
    /// may stand in for a decimal one.
    static func isCompatible(_ value: SettingsArchive.Value, with kind: Kind) -> Bool {
        switch (value, kind) {
        case (.bool, .bool), (.integer, .integer), (.double, .double), (.integer, .double),
             (.string, .string), (.data, .data):
            return true
        default:
            return false
        }
    }

    static func encode(defaults: UserDefaults = .standard) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(make(defaults: defaults))
    }

    static func restore(
        _ data: Data,
        defaults: UserDefaults = .standard,
        isAvailableInputDevice: (String) -> Bool = { _ in true }
    ) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(SettingsArchive.self, from: data)
        guard archive.version <= SettingsArchive.currentVersion else {
            throw ArchiveError.newerVersion(archive.version)
        }
        let deviceIsHere = ["vocamac.selectedAudioDeviceID", "vocamac.selectedAudioChannelDeviceID"].allSatisfy { key in
            guard case .string(let id)? = archive.values[key], !id.isEmpty else { return true }
            return isAvailableInputDevice(id)
        }
        for (key, value) in archive.values {
            guard let kind = kinds[key] else { continue }
            if inputDeviceKeys.contains(key), !deviceIsHere { continue }
            guard isCompatible(value, with: kind) else {
                VocaLogger.warning(.general, "Skipped imported setting \(key): unexpected value type")
                continue
            }
            switch value {
            case .bool(let value): defaults.set(value, forKey: key)
            case .integer(let value): defaults.set(value, forKey: key)
            case .double(let value): defaults.set(value, forKey: key)
            case .string(let value): defaults.set(value, forKey: key)
            case .data(let value): defaults.set(value, forKey: key)
            case .strings(let value): defaults.set(value, forKey: key)
            }
        }
    }

    enum ArchiveError: LocalizedError {
        case newerVersion(Int)
        var errorDescription: String? {
            switch self {
            case .newerVersion(let version): return "This backup uses settings format \(version), which this VocaMac does not understand."
            }
        }
    }
}
