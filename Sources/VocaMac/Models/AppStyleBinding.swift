// AppStyleBinding.swift
// VocaMac
//
// Persisted "this app uses this writing style" rules, plus the versioned
// envelope they are stored in.

import Foundation

/// One user-configured app → writing style rule.
struct AppStyleBinding: Codable, Identifiable, Hashable {
    /// Stable identity: prefers bundle ID, falls back to process name.
    var id: String
    /// User-facing name shown in Settings and the menu bar.
    var displayName: String
    /// Bundle identifier when known (GUI apps).
    var bundleIdentifier: String?
    /// Executable / process basename (CLI tools, fallback).
    var processName: String?
    /// The preset this binding uses.
    var style: WritingStyle
    /// Per-app tweaks. `nil` means "use the preset's rules unchanged", which
    /// lets a binding pick up future preset improvements automatically.
    var ruleOverrides: WritingStyleRules?
    /// Lets a user park a rule without losing its configuration.
    var isEnabled: Bool

    init(
        id: String,
        displayName: String,
        bundleIdentifier: String? = nil,
        processName: String? = nil,
        style: WritingStyle,
        ruleOverrides: WritingStyleRules? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processName = processName
        self.style = style
        self.ruleOverrides = ruleOverrides
        self.isEnabled = isEnabled
    }

    /// The rules this binding actually applies.
    var effectiveRules: WritingStyleRules {
        ruleOverrides ?? style.defaultRules
    }

    /// Whether the user has customized this binding away from its preset.
    var hasCustomRules: Bool {
        guard let ruleOverrides else { return false }
        return ruleOverrides != style.defaultRules
    }

    /// Build a binding for a running application.
    static func from(snapshot: RunningAppSnapshot, style: WritingStyle) -> AppStyleBinding {
        let bundleID = snapshot.bundleIdentifier
        let process = snapshot.processName
        return AppStyleBinding(
            id: bundleID ?? process ?? snapshot.displayName,
            displayName: snapshot.displayName,
            bundleIdentifier: bundleID,
            processName: process,
            style: style
        )
    }

    /// Whether this binding identifies the given running app.
    func matches(_ snapshot: RunningAppSnapshot) -> Bool {
        AppIdentityMatching.matches(
            configuredBundleIdentifier: bundleIdentifier,
            configuredProcessName: processName,
            configuredID: id,
            snapshot: snapshot
        )
    }

    // Older builds wrote bindings without `isEnabled`; treat those as enabled.
    private enum CodingKeys: String, CodingKey {
        case id, displayName, bundleIdentifier, processName, style, ruleOverrides, isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        processName = try container.decodeIfPresent(String.self, forKey: .processName)
        style = try container.decodeIfPresent(WritingStyle.self, forKey: .style) ?? .plain
        ruleOverrides = try container.decodeIfPresent(WritingStyleRules.self, forKey: .ruleOverrides)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// Versioned envelope for the persisted binding list.
///
/// Stored as a dictionary rather than a bare array so the shape can change
/// without a lossy migration: an unreadable payload degrades to "no bindings",
/// which falls back to the global default style rather than mis-formatting.
struct WritingStyleBindingStore: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var bindings: [AppStyleBinding]

    init(schemaVersion: Int = WritingStyleBindingStore.currentSchemaVersion, bindings: [AppStyleBinding] = []) {
        self.schemaVersion = schemaVersion
        self.bindings = bindings
    }

    static let empty = WritingStyleBindingStore()

    /// Decode a stored JSON payload, recovering to `empty` on any failure.
    static func decode(json: String) -> WritingStyleBindingStore {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return .empty }
        guard let decoded = try? JSONDecoder().decode(WritingStyleBindingStore.self, from: data) else {
            VocaLogger.warning(.appState, "Writing style bindings could not be decoded — falling back to none")
            return .empty
        }
        guard decoded.schemaVersion <= currentSchemaVersion else {
            // Written by a newer VocaMac. Do not guess at the shape.
            VocaLogger.warning(
                .appState,
                "Writing style bindings use schema \(decoded.schemaVersion); this build understands \(currentSchemaVersion)"
            )
            return .empty
        }
        return decoded
    }

    /// Encode for persistence. Returns the empty payload if encoding fails.
    func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"schemaVersion\":\(Self.currentSchemaVersion),\"bindings\":[]}"
        }
        return json
    }
}
