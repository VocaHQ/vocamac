// CalmStylesTests.swift
// VocaMac
//
// The Styles page's grouping of app and website rules into Messages,
// Email, Code and Everything else, and what picking a group's card or
// adding an app does to the real rules.

import XCTest
@testable import VocaMac

@MainActor
final class CalmStylesTests: XCTestCase {

    private let slack = RunningAppSnapshot(displayName: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
    private let messages = RunningAppSnapshot(displayName: "Messages", bundleIdentifier: "com.apple.MobileSMS")
    private let mail = RunningAppSnapshot(displayName: "Mail", bundleIdentifier: "com.apple.mail")
    private let xcode = RunningAppSnapshot(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode")
    private let unknownEditor = RunningAppSnapshot(displayName: "MyEditor", bundleIdentifier: "com.example.editor")

    private func clearPreferences() {
        for key in [
            PreferenceKey.writingStyleEnabled, PreferenceKey.writingStyleDefault,
            PreferenceKey.writingStyleBindings, PreferenceKey.websiteStyleBindings,
            PreferenceKey.autoCapitalize, PreferenceKey.appendTrailingSpace,
            CalmStyleGroupStore.defaultsKey,
        ] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        clearPreferences()
    }

    override func tearDown() {
        clearPreferences()
        super.tearDown()
    }

    private func makeState() -> AppState {
        let state = AppState.makeTestState().appState
        state.writingStyleBindings = []
        state.websiteStyleBindings = []
        state.calmStyleGroupStore = CalmStyleGroupStore()
        return state
    }

    // MARK: Groups

    func testEveryStyleBelongsToAGroup() {
        let expected: [WritingStyle: CalmStyleGroup] = [
            .plain: .everythingElse, .notes: .everythingElse, .chat: .messages, .slack: .messages,
            .email: .email, .code: .code, .terminal: .code,
        ]
        for style in WritingStyle.allCases {
            XCTAssertEqual(CalmStyleGroup.family(of: style), expected[style], "\(style)")
        }
    }

    func testEachGroupOffersThreeDistinctStylesIncludingItsDefault() {
        for group in CalmStyleGroup.allCases {
            XCTAssertEqual(group.cardStyles.count, 3)
            XCTAssertEqual(Set(group.cardStyles).count, 3)
            XCTAssertTrue(group.cardStyles.contains(group.defaultStyle), "\(group)")
        }
    }

    func testCardSamplesDifferWithinEachGroup() {
        let state = makeState()
        for group in CalmStyleGroup.allCases {
            let samples = group.cardStyles.map { state.writingStylePreview(group.sampleSpeech(for: $0), style: $0) }
            XCTAssertEqual(Set(samples).count, 3, "\(group): \(samples)")
        }
    }

    /// Cards in a group must look different at a glance once rendered, not
    /// only differ by a character the wrapping hides: line count, the last
    /// character, a capital at the start, bold, code or bullets.
    func testCardSamplesDifferAtAGlance() {
        let state = makeState()
        struct Glance: Hashable {
            let lines: Int
            let last: Character?
            let startsUppercase: Bool
            let hasBold: Bool
            let hasCode: Bool
            let hasBullets: Bool
        }
        for group in CalmStyleGroup.allCases {
            let glances = group.cardStyles.map { style -> Glance in
                let typed = state.writingStylePreview(group.sampleSpeech(for: style), style: style)
                let sample = CalmStyleSample(typed, dialect: style.defaultRules.emphasisDialect)
                let runs = sample.lines.flatMap(\.runs)
                return Glance(
                    lines: sample.lines.count,
                    last: sample.plainText.last,
                    startsUppercase: sample.plainText.first?.isUppercase ?? false,
                    hasBold: runs.contains { $0.look == .bold },
                    hasCode: runs.contains { $0.look == .code },
                    hasBullets: sample.lines.contains(where: \.isBullet)
                )
            }
            XCTAssertEqual(Set(glances).count, 3, "\(group): \(glances)")
        }
        let slack = CalmStyleSample(
            state.writingStylePreview(CalmStyleGroup.messages.sampleSpeech(for: .slack), style: .slack),
            dialect: .slackMrkdwn
        )
        XCTAssertFalse(slack.plainText.contains("*"), "Slack's bold markers must render, not show: \(slack.plainText)")
    }

    func testStyleSampleRendersMarkupTheWayTheTargetAppShowsIt() {
        let slack = CalmStyleSample("*Thursday plan*\n- Slides\n- `demo.key` ", dialect: .slackMrkdwn)
        XCTAssertEqual(slack.lines, [
            .init(isBullet: false, runs: [.init(text: "Thursday plan", look: .bold)]),
            .init(isBullet: true, runs: [.init(text: "Slides")]),
            .init(isBullet: true, runs: [.init(text: "demo.key", look: .code)]),
        ])
        XCTAssertEqual(slack.plainText, "Thursday plan\n• Slides\n• demo.key")

        let markdown = CalmStyleSample("**Groceries** and *more*", dialect: .markdown)
        XCTAssertEqual(markdown.lines.first?.runs, [
            .init(text: "Groceries", look: .bold), .init(text: " and "), .init(text: "more", look: .italic),
        ])

        // Plain text keeps its asterisks, and a lone or spaced one is never markup.
        XCTAssertEqual(CalmStyleSample("*not bold*", dialect: .none).plainText, "*not bold*")
        XCTAssertEqual(CalmStyleSample("2 * 3 * 4", dialect: .slackMrkdwn).plainText, "2 * 3 * 4")
        XCTAssertEqual(CalmStyleSample("a *b", dialect: .slackMrkdwn).plainText, "a *b")
    }

    func testCardSamplesNeverShowSpokenCommands() {
        let state = makeState()
        let commands = ["new line", "new paragraph", "bullet", "bold", "italic"]
        for group in CalmStyleGroup.allCases {
            for style in group.cardStyles {
                let sample = state.writingStylePreview(group.sampleSpeech(for: style), style: style).lowercased()
                XCTAssertFalse(sample.isEmpty, "\(group) \(style)")
                for command in commands {
                    XCTAssertFalse(sample.contains(command), "\(group) \(style): \(sample)")
                }
            }
        }
    }

    func testCardSamplesShowWhatEachStyleDoes() {
        let state = makeState()
        func sample(_ group: CalmStyleGroup, _ style: WritingStyle) -> String {
            state.writingStylePreview(group.sampleSpeech(for: style), style: style)
                .trimmingCharacters(in: .whitespaces)
        }
        XCTAssertEqual(sample(.messages, .plain), "Sure, I can bring the slides on Thursday.")
        XCTAssertEqual(sample(.messages, .chat), "Sounds good\nSee you Thursday")
        XCTAssertEqual(sample(.messages, .slack), "*Thursday plan*\n- Slides\n- Demo")
        XCTAssertEqual(sample(.email, .email), "Hi Sam,\nThanks for the notes. I'll send the draft on Friday.")
        XCTAssertEqual(sample(.code, .code), "the fix is in main.swift. can you review it?")
        XCTAssertEqual(sample(.code, .plain), "The fix is in main dot swift. Can you review it?")
        XCTAssertEqual(sample(.everythingElse, .notes), "- Oat milk\n- Lemons\n- Basil")
    }

    func testCatalogPlacesKnownApps() {
        XCTAssertEqual(CalmStyleGroup.catalogGroup(bundleIdentifier: slack.bundleIdentifier, processName: nil, id: "x"), .messages)
        XCTAssertEqual(CalmStyleGroup.catalogGroup(bundleIdentifier: mail.bundleIdentifier, processName: nil, id: "x"), .email)
        XCTAssertEqual(CalmStyleGroup.catalogGroup(bundleIdentifier: xcode.bundleIdentifier, processName: nil, id: "x"), .code)
        XCTAssertEqual(CalmStyleGroup.catalogGroup(bundleIdentifier: "com.apple.Terminal", processName: nil, id: "x"), .code)
        XCTAssertEqual(CalmStyleGroup.catalogGroup(bundleIdentifier: "md.obsidian", processName: nil, id: "x"), .everythingElse)
        XCTAssertNil(CalmStyleGroup.catalogGroup(bundleIdentifier: unknownEditor.bundleIdentifier, processName: nil, id: "x"))
    }

    func testGroupOfARulePrefersAssignmentThenCatalogThenStyle() {
        let state = makeState()
        let known = AppStyleBinding.from(snapshot: slack, style: .plain)
        let unknown = AppStyleBinding.from(snapshot: unknownEditor, style: .code)
        state.writingStyleBindings = [known, unknown]
        XCTAssertEqual(state.calmStyleGroup(of: known), .messages, "catalog wins over the style")
        XCTAssertEqual(state.calmStyleGroup(of: unknown), .code, "style family for unknown apps")

        var store = CalmStyleGroupStore()
        store.assign(.email, toKey: CalmStyleGroupStore.appKey(known.id))
        state.calmStyleGroupStore = store
        XCTAssertEqual(state.calmStyleGroup(of: known), .email, "an explicit choice wins")

        let site = WebsiteStyleBinding(hostPattern: "github.com", displayName: "github.com", style: .code)
        XCTAssertEqual(state.calmStyleGroup(of: site), .code)
    }

    // MARK: Chosen style

    func testGroupStyleDefaultsThenFollowsMostAppsThenThePick() {
        let state = makeState()
        XCTAssertEqual(state.calmStyle(for: .messages), .chat)

        state.writingStyleBindings = [
            AppStyleBinding.from(snapshot: slack, style: .slack),
            AppStyleBinding.from(snapshot: messages, style: .plain),
            AppStyleBinding(id: "net.whatsapp.WhatsApp", displayName: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", style: .plain),
        ]
        XCTAssertEqual(state.calmStyle(for: .messages), .plain, "most apps use Plain")

        var store = state.calmStyleGroupStore
        store.setStyle(.slack, for: .messages)
        state.calmStyleGroupStore = store
        XCTAssertEqual(state.calmStyle(for: .messages), .slack, "a picked card wins")
    }

    func testPausedAppsDoNotDecideTheGroupStyle() {
        let state = makeState()
        var paused = AppStyleBinding.from(snapshot: messages, style: .plain)
        paused.isEnabled = false
        state.writingStyleBindings = [AppStyleBinding.from(snapshot: slack, style: .slack), paused]
        XCTAssertEqual(state.calmStyle(for: .messages), .slack)
    }

    func testEverythingElseIsTheDefaultStyle() {
        let state = makeState()
        state.writingStyleDefault = .notes
        XCTAssertEqual(state.calmStyle(for: .everythingElse), .notes)
    }

    func testMostCommonStyleBreaksTiesByCardOrder() {
        XCTAssertNil(AppState.mostCommonStyle([], preferring: [.plain]))
        XCTAssertEqual(AppState.mostCommonStyle([.slack, .chat], preferring: [.plain, .chat, .slack]), .chat)
        XCTAssertEqual(AppState.mostCommonStyle([.slack, .slack, .chat], preferring: [.plain, .chat, .slack]), .slack)
        XCTAssertEqual(AppState.mostCommonStyle([.email, .code], preferring: [.plain]), .code, "then allCases order")
    }

    // MARK: Picking a card

    /// A card applies to the group and to the apps on its previous style;
    /// an app with a style of its own keeps it.
    func testApplyingAStyleUpdatesAppsOnThePreviousStyleAndKeepsTone() {
        let state = makeState()
        var customized = AppStyleBinding.from(snapshot: slack, style: .chat)
        var rules = WritingStyle.chat.defaultRules
        rules.listMarkers.toggle()
        customized.ruleOverrides = rules
        customized.intent = .casual
        customized.cleanup = .off
        let follower = AppStyleBinding.from(snapshot: messages, style: .chat)
        let ownStyle = AppStyleBinding(
            id: "net.whatsapp.WhatsApp", displayName: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", style: .slack
        )
        let editor = AppStyleBinding.from(snapshot: xcode, style: .code)
        state.writingStyleBindings = [customized, follower, ownStyle, editor]
        XCTAssertEqual(state.calmStyle(for: .messages), .chat)

        XCTAssertEqual(state.calmCustomizedApps(in: .messages, switchingTo: .plain).map(\.id), [customized.id])
        XCTAssertTrue(state.calmCustomizedApps(in: .messages, switchingTo: .chat).isEmpty)
        let others = state.calmOtherStyleMembers(in: .messages, besides: .plain)
        XCTAssertEqual(others.apps.map(\.id), [ownStyle.id])

        state.calmApplyStyle(.plain, to: .messages)

        let byID = Dictionary(uniqueKeysWithValues: state.writingStyleBindings.map { ($0.id, $0) })
        XCTAssertEqual(byID[customized.id]?.style, .plain)
        XCTAssertNil(byID[customized.id]?.ruleOverrides, "formatting resets to the new style")
        XCTAssertEqual(byID[customized.id]?.intent, .casual, "tone is kept")
        XCTAssertEqual(byID[customized.id]?.cleanup, .off, "AI cleanup is kept")
        XCTAssertEqual(byID[follower.id]?.style, .plain)
        XCTAssertEqual(byID[ownStyle.id]?.style, .slack, "an app with its own style keeps it")
        XCTAssertEqual(byID[editor.id]?.style, .code, "other groups are untouched")
        XCTAssertEqual(state.calmStyle(for: .messages), .plain)
        XCTAssertEqual(state.calmApps(in: .messages).count, 3, "nobody leaves the tab")
        XCTAssertEqual(state.writingStyleDefault, .plain)
        XCTAssertNil(state.undoCenter.current, "a plain pick changes nothing it would need to undo")
    }

    /// “Apply to all” changes the apps with their own style too, and Undo
    /// puts them (and the card) back.
    func testApplyingAStyleToAllCanBeUndone() {
        let state = makeState()
        var ownStyle = AppStyleBinding.from(snapshot: slack, style: .slack)
        var rules = WritingStyle.slack.defaultRules
        rules.listMarkers = false
        ownStyle.ruleOverrides = rules
        let follower = AppStyleBinding.from(snapshot: messages, style: .chat)
        let site = WebsiteStyleBinding(hostPattern: "discord.com", displayName: "Discord", style: .plain)
        state.writingStyleBindings = [ownStyle, follower]
        state.websiteStyleBindings = [site]
        state.calmApplyStyle(.chat, to: .messages)
        XCTAssertEqual(state.calmWebsites(in: .messages).count, 0, "Plain websites live in Everything else")
        state.calmAddWebsite("discord.com", to: .messages)
        XCTAssertEqual(state.websiteStyleBindings.first?.style, .chat)
        state.calmUpdateWebsite(site.id) { $0.style = .plain }
        XCTAssertEqual(state.calmWebsites(in: .messages).count, 1, "a style change keeps it in its tab")

        XCTAssertEqual(state.calmCustomizedApps(in: .messages, switchingTo: .chat, includingOtherStyles: true).map(\.id), [ownStyle.id])
        state.calmApplyStyle(.chat, to: .messages, includingOtherStyles: true)
        XCTAssertEqual(Set(state.writingStyleBindings.map(\.style)), [.chat])
        XCTAssertNil(state.writingStyleBindings.first { $0.id == ownStyle.id }?.ruleOverrides)
        XCTAssertEqual(state.websiteStyleBindings.first?.style, .chat)

        state.undoCenter.undo()
        let restored = state.writingStyleBindings.first { $0.id == ownStyle.id }
        XCTAssertEqual(restored?.style, .slack)
        XCTAssertEqual(restored?.ruleOverrides, rules)
        XCTAssertEqual(state.websiteStyleBindings.first?.style, .plain)
        XCTAssertEqual(state.calmStyle(for: .messages), .chat)
        XCTAssertEqual(state.calmWebsites(in: .messages).count, 1)
    }

    /// Changing one rule's style (chip menu, editor, website chip) keeps it
    /// in the tab it was in, even when the new style's family is elsewhere.
    func testChangingARulesStyleKeepsItInItsTab() {
        let state = makeState()
        let unknownChat = AppStyleBinding(id: "com.example.chat", displayName: "MyChat", bundleIdentifier: "com.example.chat", style: .chat)
        let site = WebsiteStyleBinding(hostPattern: "github.com", displayName: "github.com", style: .code)
        state.writingStyleBindings = [unknownChat]
        state.websiteStyleBindings = [site]
        XCTAssertEqual(state.calmApps(in: .messages).map(\.id), [unknownChat.id])

        state.calmSetStyle(.code, forApp: unknownChat.id)
        XCTAssertEqual(state.calmApps(in: .messages).map(\.id), [unknownChat.id])
        XCTAssertTrue(state.calmApps(in: .code).isEmpty)

        state.calmUpdateApp(unknownChat.id) { $0.style = .email }
        XCTAssertEqual(state.calmApps(in: .messages).map(\.id), [unknownChat.id])

        state.calmUpdateWebsite(site.id) { $0.style = .plain }
        XCTAssertEqual(state.calmWebsites(in: .code).map(\.id), [site.id])
    }

    func testApplyingAStylePinsUnknownAppsToTheirTab() {
        let state = makeState()
        state.writingStyleBindings = [AppStyleBinding.from(snapshot: unknownEditor, style: .code)]
        XCTAssertEqual(state.calmApps(in: .code).count, 1)

        state.calmApplyStyle(.plain, to: .code)

        XCTAssertEqual(state.writingStyleBindings.first?.style, .plain)
        XCTAssertEqual(state.calmApps(in: .code).count, 1, "Plain would otherwise move it to Everything else")
        XCTAssertTrue(state.calmApps(in: .everythingElse).isEmpty)
    }

    func testApplyingAStyleToEverythingElseSetsTheDefaultAndWebsites() {
        let state = makeState()
        let notesSite = WebsiteStyleBinding(hostPattern: "notion.so", displayName: "Notion", style: .plain)
        state.websiteStyleBindings = [notesSite]

        state.calmApplyStyle(.notes, to: .everythingElse)

        XCTAssertEqual(state.writingStyleDefault, .notes)
        XCTAssertEqual(state.websiteStyleBindings.first?.style, .notes)
        XCTAssertEqual(state.calmWebsites(in: .everythingElse).map(\.id), [notesSite.id])
    }

    func testApplyingAStyleToAnEmptyGroupIsRememberedForNewApps() {
        let state = makeState()
        state.calmApplyStyle(.slack, to: .messages)
        XCTAssertEqual(state.calmStyle(for: .messages), .slack)

        let added = state.calmAddApp(messages, to: .messages)
        XCTAssertEqual(added.style, .slack)
    }

    func testSettingOneAppsStyleResetsItsFormatting() {
        let state = makeState()
        var binding = AppStyleBinding.from(snapshot: xcode, style: .code)
        var rules = WritingStyle.code.defaultRules
        rules.caseCommands = false
        binding.ruleOverrides = rules
        state.writingStyleBindings = [binding]

        state.calmSetStyle(.terminal, forApp: binding.id)
        XCTAssertEqual(state.writingStyleBindings.first?.style, .terminal)
        XCTAssertNil(state.writingStyleBindings.first?.ruleOverrides)
    }

    // MARK: Adding

    func testAddingAKnownAppUsesTheGroupStyleAndKeepsSuggestedTone() {
        let state = makeState()
        state.calmApplyStyle(.plain, to: .email)
        let binding = state.calmAddApp(mail, to: .email)
        XCTAssertEqual(binding.style, .plain)
        XCTAssertEqual(binding.intent, .professional)
        XCTAssertEqual(state.calmApps(in: .email).map(\.id), [binding.id])
    }

    /// Adding an app another tab has moves its rule: only the style changes.
    func testAddingAnAppFromAnotherTabMovesItsRule() {
        let state = makeState()
        var existing = AppStyleBinding.from(snapshot: unknownEditor, style: .code)
        var rules = WritingStyle.code.defaultRules
        rules.caseCommands = false
        existing.ruleOverrides = rules
        existing.intent = .casual
        existing.cleanup = .off
        existing.cleanupPrompt = "Keep my jargon."
        existing.isEnabled = false
        state.writingStyleBindings = [existing]
        XCTAssertEqual(state.calmExistingGroup(for: unknownEditor), .code)

        let moved = state.calmAddApp(unknownEditor, to: .messages)

        XCTAssertEqual(state.writingStyleBindings.count, 1)
        XCTAssertEqual(moved.id, existing.id)
        let binding = state.writingStyleBindings.first
        XCTAssertEqual(binding?.style, .chat)
        XCTAssertEqual(binding?.ruleOverrides, rules)
        XCTAssertEqual(binding?.intent, .casual)
        XCTAssertEqual(binding?.cleanup, .off)
        XCTAssertEqual(binding?.cleanupPrompt, "Keep my jargon.")
        XCTAssertEqual(binding?.isEnabled, false)
        XCTAssertEqual(state.calmExistingGroup(for: unknownEditor), .messages)
    }

    func testAddingAWebsiteNormalizesAndReplacesTheSameHost() {
        let state = makeState()
        XCTAssertNil(state.calmAddWebsite("   ", to: .code))

        let first = state.calmAddWebsite("https://GitHub.com/VocaHQ/", to: .code)
        XCTAssertEqual(first?.hostPattern, "github.com")
        XCTAssertEqual(first?.style, .code)
        if let id = first?.id { state.calmUpdateWebsite(id) { $0.isEnabled = false } }
        let second = state.calmAddWebsite("github.com", to: .messages)

        XCTAssertEqual(state.websiteStyleBindings.count, 1)
        XCTAssertEqual(state.websiteStyleBindings.first?.id, second?.id)
        XCTAssertEqual(second?.id, first?.id, "the rule moves rather than being recreated")
        XCTAssertEqual(second?.isEnabled, false)
        XCTAssertEqual(second?.style, .chat)
        XCTAssertEqual(state.calmWebsites(in: .messages).count, 1)
        XCTAssertTrue(state.calmWebsites(in: .code).isEmpty)
    }

    func testSuggestionsSkipAppsAlreadySetUp() {
        let state = makeState()
        let installed = [slack, messages, xcode]
        XCTAssertEqual(
            state.calmSuggestedApps(for: .messages, installed: installed).compactMap(\.bundleIdentifier),
            ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS"]
        )
        state.writingStyleBindings = [AppStyleBinding.from(snapshot: slack, style: .slack)]
        XCTAssertEqual(
            state.calmSuggestedApps(for: .messages, installed: installed).compactMap(\.bundleIdentifier),
            ["com.apple.MobileSMS"]
        )
        XCTAssertEqual(state.calmSuggestedApps(for: .code, installed: installed).compactMap(\.bundleIdentifier), ["com.apple.dt.Xcode"])
    }

    // MARK: Websites and candidates

    func testWebsiteHostNormalization() {
        XCTAssertEqual(CalmWebsiteHost.normalized("https://Mail.Google.com/mail/u/0"), "mail.google.com")
        XCTAssertEqual(CalmWebsiteHost.normalized("github.com/foo"), "github.com")
        XCTAssertEqual(CalmWebsiteHost.normalized(" *.example.com. "), "*.example.com")
        XCTAssertTrue(CalmWebsiteHost.looksLikeWebsite("github.com"))
        XCTAssertTrue(CalmWebsiteHost.looksLikeWebsite("https://docs.google.com/document"))
        XCTAssertTrue(CalmWebsiteHost.looksLikeWebsite("*.example.co"))
        XCTAssertFalse(CalmWebsiteHost.looksLikeWebsite("notion"))
        XCTAssertFalse(CalmWebsiteHost.looksLikeWebsite("Visual Studio Code"))
        XCTAssertFalse(CalmWebsiteHost.looksLikeWebsite("v1.2"))
        XCTAssertFalse(CalmWebsiteHost.looksLikeWebsite(""))
    }

    func testCandidatesMergeAndFilter() {
        let installed = [
            RunningAppSnapshot(displayName: "Signal", bundleIdentifier: "org.signal"),
            RunningAppSnapshot(displayName: "Notion", bundleIdentifier: "notion.id"),
        ]
        let running = [RunningAppSnapshot(displayName: "Notion", bundleIdentifier: "NOTION.id")]
        let merged = CalmAppCandidates.merged([installed, running], excludingBundleIdentifier: nil)
        XCTAssertEqual(merged.map(\.displayName), ["Notion", "Signal"])
        XCTAssertEqual(CalmAppCandidates.filter(merged, query: "n").map(\.displayName), ["Notion", "Signal"])
        XCTAssertEqual(CalmAppCandidates.filter(merged, query: "sig").map(\.displayName), ["Signal"])
        XCTAssertEqual(CalmAppCandidates.filter(merged, query: " ").count, 2)
        XCTAssertTrue(CalmAppCandidates.merged([installed], excludingBundleIdentifier: "org.signal").allSatisfy { $0.displayName != "Signal" })
    }

    // MARK: Store

    func testGroupChoicesForRemovedRulesArePrunedUnlessUndoIsPending() {
        let state = makeState()
        let app = AppStyleBinding.from(snapshot: unknownEditor, style: .code)
        state.writingStyleBindings = [app]
        var store = CalmStyleGroupStore()
        store.assign(.messages, toKey: CalmStyleGroupStore.appKey(app.id))
        store.assign(.email, toKey: CalmStyleGroupStore.appKey("gone"))
        store.assign(.email, toKey: CalmStyleGroupStore.websiteKey(UUID()))
        state.calmStyleGroupStore = store
        XCTAssertEqual(state.calmStyleGroupStore.assignments.keys.sorted(), [CalmStyleGroupStore.appKey(app.id)])

        // Removing it can be undone, so its tab is remembered until then.
        state.removeAppStyleBinding(app)
        XCTAssertNotNil(state.undoCenter.current)
        state.calmPruneStyleGroups()
        state.calmApplyStyle(.terminal, to: .code)
        XCTAssertEqual(state.calmStyleGroupStore.group(forKey: CalmStyleGroupStore.appKey(app.id)), .messages)
        state.undoCenter.undo()
        XCTAssertEqual(state.calmExistingGroup(for: unknownEditor), .messages)

        state.undoCenter.dismiss()
        state.writingStyleBindings = []
        state.calmPruneStyleGroups()
        XCTAssertTrue(state.calmStyleGroupStore.assignments.isEmpty)
    }

    /// Set Up My Apps and imports put a re-added app where the catalog says,
    /// not in the tab it was pinned to before it was removed.
    func testReAddedAppsForgetTheirOldTab() {
        let state = makeState()
        guard let suggestion = WritingStyleCatalog.suggestion(matching: slack) else { return XCTFail("Slack is in the catalog") }
        var store = CalmStyleGroupStore()
        store.assign(.code, toKey: CalmStyleGroupStore.appKey(suggestion.binding.id))
        state.writingStyleBindings = [suggestion.binding]
        state.calmStyleGroupStore = store
        state.writingStyleBindings = []
        // A stale pin (the store wasn't saved since the removal).
        UserDefaults.standard.set(store.encodedJSON(), forKey: CalmStyleGroupStore.defaultsKey)

        XCTAssertEqual(state.applySuggestedWritingStyles([suggestion], bindingsAtStart: []), 1)
        XCTAssertEqual(state.calmExistingGroup(for: slack), .messages)

        state.writingStyleBindings = [suggestion.binding]
        UserDefaults.standard.set(store.encodedJSON(), forKey: CalmStyleGroupStore.defaultsKey)
        state.calmResetStyleGroups(forApps: [suggestion.binding.id])
        XCTAssertEqual(state.calmExistingGroup(for: slack), .messages)
    }

    func testSettingsBackupIncludesTheStyleGroups() {
        XCTAssertEqual(SettingsArchiveService.kinds[CalmStyleGroupStore.defaultsKey], .string)
    }

    func testStoreRoundTripsAndSurvivesBadData() {
        var store = CalmStyleGroupStore()
        store.assign(.code, toKey: CalmStyleGroupStore.appKey("a"))
        store.setStyle(.terminal, for: .code)
        let decoded = CalmStyleGroupStore.decode(store.encodedJSON())
        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.group(forKey: "app:a"), .code)
        XCTAssertEqual(decoded.style(for: .code), .terminal)

        XCTAssertEqual(CalmStyleGroupStore.decode("not json"), CalmStyleGroupStore())
        XCTAssertEqual(CalmStyleGroupStore.decode(nil), CalmStyleGroupStore())
        let future = CalmStyleGroupStore.decode(#"{"assignments":{"app:a":"later"},"styles":{"code":"fancy"}}"#)
        XCTAssertNil(future.group(forKey: "app:a"), "an unknown group is ignored")
        XCTAssertNil(future.style(for: .code), "an unknown style is ignored")
    }
}
