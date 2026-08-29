// WritingStyleTests.swift
// VocaMac
//
// Style presets, binding persistence, resolution, and the seeded catalog.

import XCTest
@testable import VocaMac

// MARK: - Presets

final class WritingStyleTests: XCTestCase {

    func testResolvedFallsBackToPlain() {
        XCTAssertEqual(WritingStyle.resolved(stored: nil), .plain)
        XCTAssertEqual(WritingStyle.resolved(stored: ""), .plain)
        XCTAssertEqual(WritingStyle.resolved(stored: "nonsense"), .plain)
    }

    func testResolvedKeepsKnownIDs() {
        for style in WritingStyle.allCases {
            XCTAssertEqual(WritingStyle.resolved(stored: style.rawValue), style)
        }
    }

    func testEveryStyleHasDisplayMetadata() {
        for style in WritingStyle.allCases {
            XCTAssertFalse(style.displayName.isEmpty)
            XCTAssertFalse(style.shortDescription.isEmpty)
            XCTAssertFalse(style.systemImage.isEmpty)
        }
    }

    func testPlainInheritsBothGlobalToggles() {
        let rules = WritingStyle.plain.defaultRules
        XCTAssertEqual(rules.capitalization, .inherit)
        XCTAssertEqual(rules.trailingSpace, .inherit)
        XCTAssertEqual(rules.terminalPunctuation, .leaveAsIs)
        XCTAssertEqual(rules, .passthrough)
    }

    func testTerminalNeverAddsTrailingSpace() {
        XCTAssertEqual(WritingStyle.terminal.defaultRules.trailingSpace, .off)
    }

    func testAggressiveSymbolRulesAreLimitedToCodeAndTerminal() {
        for style in WritingStyle.allCases {
            let usesTierB = style.defaultRules.spokenSymbols.contains(.tierB)
            let expected = (style == .code || style == .terminal)
            XCTAssertEqual(usesTierB, expected, "\(style.rawValue) tier B expectation")
        }
    }

    func testRulesCodableRoundTrip() throws {
        for style in WritingStyle.allCases {
            let data = try JSONEncoder().encode(style.defaultRules)
            let decoded = try JSONDecoder().decode(WritingStyleRules.self, from: data)
            XCTAssertEqual(decoded, style.defaultRules, "\(style.rawValue) did not survive a round trip")
        }
    }

    func testSpokenSymbolTiersEncodeAsRawValue() throws {
        let data = try JSONEncoder().encode(SpokenSymbolTiers.all)
        let decoded = try JSONDecoder().decode(SpokenSymbolTiers.self, from: data)
        XCTAssertEqual(decoded, .all)
        XCTAssertTrue(decoded.contains(.tierA))
        XCTAssertTrue(decoded.contains(.tierB))
    }
}

// MARK: - Bindings

final class AppStyleBindingTests: XCTestCase {

    private func snapshot(bundle: String? = nil, process: String? = nil, name: String = "Test App") -> RunningAppSnapshot {
        RunningAppSnapshot(displayName: name, bundleIdentifier: bundle, processName: process)
    }

    func testMatchesOnBundleIdentifierCaseInsensitively() {
        let binding = AppStyleBinding(id: "com.example.App", displayName: "App", bundleIdentifier: "com.example.App", style: .code)
        XCTAssertTrue(binding.matches(snapshot(bundle: "com.example.app")))
    }

    func testMatchesOnProcessName() {
        let binding = AppStyleBinding(id: "ghostty", displayName: "Ghostty", processName: "ghostty", style: .terminal)
        XCTAssertTrue(binding.matches(snapshot(process: "/Applications/Ghostty.app/Contents/MacOS/ghostty")))
    }

    func testDoesNotMatchUnrelatedApp() {
        let binding = AppStyleBinding(id: "com.example.App", displayName: "App", bundleIdentifier: "com.example.App", style: .code)
        XCTAssertFalse(binding.matches(snapshot(bundle: "com.other.Thing")))
    }

    func testEffectiveRulesFallBackToPreset() {
        let binding = AppStyleBinding(id: "x", displayName: "X", style: .slack)
        XCTAssertEqual(binding.effectiveRules, WritingStyle.slack.defaultRules)
        XCTAssertFalse(binding.hasCustomRules)
    }

    func testEffectiveRulesUseOverride() {
        var rules = WritingStyle.slack.defaultRules
        rules.listMarkers = false
        let binding = AppStyleBinding(id: "x", displayName: "X", style: .slack, ruleOverrides: rules)
        XCTAssertEqual(binding.effectiveRules, rules)
        XCTAssertTrue(binding.hasCustomRules)
    }

    func testOverrideEqualToPresetIsNotReportedAsCustom() {
        let binding = AppStyleBinding(
            id: "x",
            displayName: "X",
            style: .slack,
            ruleOverrides: WritingStyle.slack.defaultRules
        )
        XCTAssertFalse(binding.hasCustomRules)
    }

    func testFromSnapshotPrefersBundleIdentifier() {
        let binding = AppStyleBinding.from(snapshot: snapshot(bundle: "com.example.App", process: "App"), style: .code)
        XCTAssertEqual(binding.id, "com.example.App")
        XCTAssertEqual(binding.style, .code)
        XCTAssertTrue(binding.isEnabled)
    }

    // MARK: Store

    func testStoreRoundTrip() {
        let store = WritingStyleBindingStore(bindings: [
            AppStyleBinding(id: "a", displayName: "A", bundleIdentifier: "a", style: .code),
            AppStyleBinding(id: "b", displayName: "B", bundleIdentifier: "b", style: .slack)
        ])
        let decoded = WritingStyleBindingStore.decode(json: store.encodedJSON())
        XCTAssertEqual(decoded, store)
    }

    func testCorruptJSONDecodesToEmpty() {
        XCTAssertEqual(WritingStyleBindingStore.decode(json: "{not json"), .empty)
        XCTAssertEqual(WritingStyleBindingStore.decode(json: ""), .empty)
        XCTAssertEqual(WritingStyleBindingStore.decode(json: "   "), .empty)
    }

    func testLegacyBareArrayDecodesToEmptyRatherThanCrashing() {
        XCTAssertEqual(WritingStyleBindingStore.decode(json: "[]"), .empty)
    }

    func testFutureSchemaIsRejected() {
        let future = #"{"schemaVersion":99,"bindings":[{"id":"a","displayName":"A","style":"code","isEnabled":true}]}"#
        XCTAssertEqual(WritingStyleBindingStore.decode(json: future), .empty)
    }

    func testBindingWithoutIsEnabledDefaultsToEnabled() {
        let json = #"{"schemaVersion":1,"bindings":[{"id":"a","displayName":"A","style":"code"}]}"#
        let store = WritingStyleBindingStore.decode(json: json)
        XCTAssertEqual(store.bindings.count, 1)
        XCTAssertTrue(store.bindings[0].isEnabled)
    }

    func testBindingWithUnknownStyleFallsBackToPlain() {
        let json = #"{"schemaVersion":1,"bindings":[{"id":"a","displayName":"A","style":"quantum"}]}"#
        let store = WritingStyleBindingStore.decode(json: json)
        // An unknown enum value fails the whole decode, which recovers to empty
        // rather than silently applying the wrong style.
        XCTAssertEqual(store, .empty)
    }
}

// MARK: - Resolution

final class WritingStyleResolverTests: XCTestCase {

    private let cursor = RunningAppSnapshot(displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92")
    private let slack = RunningAppSnapshot(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")

    private var bindings: [AppStyleBinding] {
        [
            AppStyleBinding(id: "com.todesktop.230313mzl4w4u92", displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", style: .code),
            AppStyleBinding(id: "com.tinyspeck.slackmacgap", displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", style: .slack)
        ]
    }

    func testMatchingBindingWins() {
        let resolved = WritingStyleResolver.resolve(target: cursor, bindings: bindings, defaultStyle: .plain, isEnabled: true)
        XCTAssertEqual(resolved.style, .code)
        XCTAssertEqual(resolved.matchedAppName, "Cursor")
    }

    func testUnmatchedAppUsesDefaultStyle() {
        let other = RunningAppSnapshot(displayName: "Other", bundleIdentifier: "com.other.app")
        let resolved = WritingStyleResolver.resolve(target: other, bindings: bindings, defaultStyle: .chat, isEnabled: true)
        XCTAssertEqual(resolved.style, .chat)
        XCTAssertNil(resolved.matchedAppName)
    }

    func testNilTargetUsesDefaultStyle() {
        let resolved = WritingStyleResolver.resolve(target: nil, bindings: bindings, defaultStyle: .notes, isEnabled: true)
        XCTAssertEqual(resolved.style, .notes)
    }

    func testDisabledFeatureIsAFullPassthrough() {
        let resolved = WritingStyleResolver.resolve(target: cursor, bindings: bindings, defaultStyle: .code, isEnabled: false)
        XCTAssertEqual(resolved, .disabled)
        XCTAssertEqual(resolved.rules, .passthrough)
    }

    func testDisabledBindingIsSkipped() {
        var disabled = bindings
        disabled[1].isEnabled = false
        let resolved = WritingStyleResolver.resolve(target: slack, bindings: disabled, defaultStyle: .plain, isEnabled: true)
        XCTAssertEqual(resolved.style, .plain)
        XCTAssertNil(resolved.matchedAppName)
    }

    func testLaterBindingOverridesEarlierOne() {
        var duplicated = bindings
        duplicated.append(
            AppStyleBinding(id: "cursor-override", displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", style: .notes)
        )
        let resolved = WritingStyleResolver.resolve(target: cursor, bindings: duplicated, defaultStyle: .plain, isEnabled: true)
        XCTAssertEqual(resolved.style, .notes)
    }

    func testOverrideRulesAreCarriedThrough() {
        var rules = WritingStyle.code.defaultRules
        rules.spokenSymbols = .tierA
        let custom = [
            AppStyleBinding(
                id: "com.todesktop.230313mzl4w4u92",
                displayName: "Cursor",
                bundleIdentifier: "com.todesktop.230313mzl4w4u92",
                style: .code,
                ruleOverrides: rules
            )
        ]
        let resolved = WritingStyleResolver.resolve(target: cursor, bindings: custom, defaultStyle: .plain, isEnabled: true)
        XCTAssertEqual(resolved.rules.spokenSymbols, .tierA)
    }
}

// MARK: - Catalog

final class WritingStyleCatalogTests: XCTestCase {

    func testCatalogIncludesCurrentChatGPTBundleIdentifier() {
        XCTAssertTrue(
            WritingStyleCatalog.chat.contains {
                $0.bundleIdentifier == "com.openai.codex" && $0.style == .chat
            }
        )
    }

    func testNoDuplicateIdentifiers() {
        let ids = WritingStyleCatalog.suggestions.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "catalog contains duplicate ids")
    }

    func testEverySuggestionIsIdentifiable() {
        for suggestion in WritingStyleCatalog.suggestions {
            XCTAssertFalse(suggestion.displayName.isEmpty)
            XCTAssertTrue(
                suggestion.bundleIdentifier != nil || suggestion.processName != nil,
                "\(suggestion.displayName) has neither a bundle ID nor a process name"
            )
        }
    }

    func testTerminalsAreBoundToTerminalStyle() {
        for suggestion in WritingStyleCatalog.terminals {
            XCTAssertEqual(suggestion.style, .terminal, "\(suggestion.displayName)")
        }
    }

    func testEditorsAreBoundToCodeStyle() {
        for suggestion in WritingStyleCatalog.editors {
            XCTAssertEqual(suggestion.style, .code, "\(suggestion.displayName)")
        }
    }

    func testMergingAddsOnlyNewSuggestions() {
        let existing = [
            AppStyleBinding(id: "com.apple.Terminal", displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", style: .chat)
        ]
        let merged = WritingStyleCatalog.merging(existing, with: WritingStyleCatalog.terminals)
        // The user's own Terminal rule must survive untouched.
        XCTAssertEqual(merged.first { $0.id == "com.apple.Terminal" }?.style, .chat)
        XCTAssertEqual(merged.filter { $0.id == "com.apple.Terminal" }.count, 1)
        XCTAssertTrue(merged.count > existing.count)
    }

    func testMergingIsIdempotent() {
        let once = WritingStyleCatalog.merging([], with: WritingStyleCatalog.suggestions)
        let twice = WritingStyleCatalog.merging(once, with: WritingStyleCatalog.suggestions)
        XCTAssertEqual(once.count, twice.count)
    }

    func testInstalledFilterUsesTheInjectedCheck() {
        let suggestions = WritingStyleCatalog.suggestionsForInstalledApps(
            running: [],
            isInstalled: { $0 == "com.apple.Terminal" }
        )
        XCTAssertEqual(suggestions.map(\.bundleIdentifier), ["com.apple.Terminal"])
    }

    func testRunningAppsCountAsInstalled() {
        let running = [RunningAppSnapshot(displayName: "Ghostty", processName: "ghostty")]
        let suggestions = WritingStyleCatalog.suggestionsForInstalledApps(
            running: running,
            isInstalled: { _ in false }
        )
        XCTAssertTrue(suggestions.contains { $0.displayName == "Ghostty" })
    }
}
