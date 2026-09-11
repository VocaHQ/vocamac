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
    /// Deliberate allowlist: user content (history, stats, scratchpad) and the
    /// cleanup endpoint and API key are not settings backups. Neither is the
    /// Command Mode clipboard opt-in: a privacy consent is given in Settings,
    /// never by importing a file.
    static let keys: Set<String> = [
        "vocamac.activationMode", "vocamac.customVocabulary", "vocamac.doubleTapThreshold",
        "vocamac.hotKeyCode", "vocamac.hotKeyModifiers", "vocamac.launchAtLogin",
        "vocamac.logLevel", "vocamac.maxRecordingDuration", "vocamac.overlayPosition",
        "vocamac.overlayStyle", "vocamac.preserveClipboard", "vocamac.selectedAudioChannel",
        "vocamac.selectedAudioChannelCount", "vocamac.selectedAudioChannelDeviceID",
        "vocamac.selectedAudioDeviceID", "vocamac.selectedAudioDeviceName",
        "vocamac.showCursorIndicator", "vocamac.silenceDuration", "vocamac.silenceThreshold",
        "vocamac.soundEffectsEnabled", "vocamac.translationEnabled", "vocamac.snippets",
        PreferenceKey.appendTrailingSpace, PreferenceKey.autoCapitalize, PreferenceKey.autoPauseEnabled,
        PreferenceKey.autoPauseApps, PreferenceKey.autoPausePollInterval,
        PreferenceKey.commandModeShortcut, PreferenceKey.commandModeEngine, PreferenceKey.dictationTone, PreferenceKey.duckOtherAudioEnabled,
        PreferenceKey.escapeCancelsDictation, PreferenceKey.externalMicWhenLidClosed,
        PreferenceKey.handsFreeShortcut, PreferenceKey.historyEnabled, PreferenceKey.historyKeepsAudio,
        PreferenceKey.historyRetention, PreferenceKey.learnCorrectionsMode, PreferenceKey.modelKeepAliveEnabled,
        PreferenceKey.modelKeepAliveIdleTimeout, PreferenceKey.mouseTriggerButton, PreferenceKey.pasteLastShortcut,
        PreferenceKey.selectedLanguage, PreferenceKey.selectedModelSize, PreferenceKey.transcriptCleanupEnabled,
        PreferenceKey.transcriptCleanupLevel, PreferenceKey.transcriptCleanupModel,
        PreferenceKey.transcriptCleanupPrompt, PreferenceKey.useScreenContext, PreferenceKey.websiteStyleBindings,
        PreferenceKey.wordReplacements, PreferenceKey.writingIntent, PreferenceKey.writingRewriteEnabled,
        PreferenceKey.writingStyleBindings, PreferenceKey.writingStyleDefault, PreferenceKey.writingStyleEnabled,
    ]

    static func make(defaults: UserDefaults = .standard) -> SettingsArchive {
        var values: [String: SettingsArchive.Value] = [:]
        for key in keys {
            guard let raw = defaults.object(forKey: key) else { continue }
            // Check the CF type first: an NSNumber holding 0 or 1 bridges to
            // Bool too, which would export a stored Int or Double as a Bool.
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                values[key] = .bool(number.boolValue)
            } else if let number = raw as? NSNumber, !CFNumberIsFloatType(number) {
                values[key] = .integer(number.intValue)
            } else if let value = raw as? Double { values[key] = .double(value) }
            else if let value = raw as? String { values[key] = .string(value) }
            else if let value = raw as? Data { values[key] = .data(value) }
            else if let value = raw as? [String] { values[key] = .strings(value) }
        }
        return SettingsArchive(values: values)
    }

    static func encode(defaults: UserDefaults = .standard) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(make(defaults: defaults))
    }

    static func restore(_ data: Data, defaults: UserDefaults = .standard) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(SettingsArchive.self, from: data)
        guard archive.version <= SettingsArchive.currentVersion else {
            throw ArchiveError.newerVersion(archive.version)
        }
        for (key, value) in archive.values where keys.contains(key) {
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
