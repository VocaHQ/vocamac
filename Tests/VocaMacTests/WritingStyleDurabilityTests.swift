// WritingStyleDurabilityTests.swift
// VocaMac Tests
//
// What happens to a user's rules across upgrades, and how writing styles and
// snippets behave when they meet in one utterance.

import XCTest
@testable import VocaMac

final class WritingStyleRulesCodableTests: XCTestCase {

    /// A rules payload written before a field existed.
    private let payloadMissingFiller = """
    {"capitalization":"off","terminalPunctuation":"leaveAsIs","trailingSpace":"off",\
    "spokenSymbols":3,"pathStitching":true,"caseCommands":true,"emphasisDialect":"none",\
    "listMarkers":false,"newlineCommands":true}
    """

    func testMissingFieldsDecodeToTheirDefaults() throws {
        let data = try XCTUnwrap(payloadMissingFiller.data(using: .utf8))
        let rules = try JSONDecoder().decode(WritingStyleRules.self, from: data)

        XCTAssertEqual(rules.capitalization, .off)
        XCTAssertEqual(rules.pathStitching, true)
        XCTAssertEqual(rules.filler, .keep, "a field added later must default, not throw")
    }

    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {"capitalization":"sentences","somethingFromTheFuture":42}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try JSONDecoder().decode(WritingStyleRules.self, from: data)
        XCTAssertEqual(rules.capitalization, .sentences)
    }

    func testRoundTripStillWorks() throws {
        let original = WritingStyle.notes.defaultRules
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WritingStyleRules.self, from: data), original)
    }
}

final class WritingStyleBindingStoreRecoveryTests: XCTestCase {

    func testOneUnreadableRuleDoesNotTakeTheOthers() {
        // The first binding's overrides predate the `filler` field; the second
        // is fine. Losing the second because of the first is how a user's whole
        // configuration disappears on upgrade.
        let json = """
        {"schemaVersion":1,"bindings":[
          {"id":"com.a","displayName":"A","style":"code","isEnabled":true,
           "ruleOverrides":{"capitalization":"off","spokenSymbols":3}},
          {"id":"com.b","displayName":"B","style":"chat","isEnabled":true}
        ]}
        """
        let store = WritingStyleBindingStore.decode(json: json)
        XCTAssertEqual(store.bindings.count, 2)
        XCTAssertEqual(store.bindings.map(\.id), ["com.a", "com.b"])
        XCTAssertEqual(store.bindings.first?.ruleOverrides?.filler, .keep)
    }

    func testATrulyBrokenRuleIsDroppedAndTheRestSurvive() {
        let json = """
        {"schemaVersion":1,"bindings":[
          {"displayName":"missing an id"},
          {"id":"com.b","displayName":"B","style":"chat","isEnabled":true}
        ]}
        """
        let store = WritingStyleBindingStore.decode(json: json)
        XCTAssertEqual(store.bindings.map(\.id), ["com.b"])
    }

    func testNonJSONStillDegradesToEmpty() {
        XCTAssertTrue(WritingStyleBindingStore.decode(json: "{ this is not json").bindings.isEmpty)
        XCTAssertTrue(WritingStyleBindingStore.decode(json: "").bindings.isEmpty)
    }

    func testFutureSchemaIsStillRejectedWholesale() {
        let json = """
        {"schemaVersion":99,"bindings":[{"id":"com.b","displayName":"B","style":"chat"}]}
        """
        XCTAssertTrue(WritingStyleBindingStore.decode(json: json).bindings.isEmpty)
    }

    func testRoundTripThroughTheEnvelope() {
        let store = WritingStyleBindingStore(bindings: [
            AppStyleBinding(id: "com.a", displayName: "A", bundleIdentifier: "com.a", style: .code)
        ])
        let decoded = WritingStyleBindingStore.decode(json: store.encodedJSON())
        XCTAssertEqual(decoded.bindings, store.bindings)
    }
}

final class SnippetWritingStyleInteractionTests: XCTestCase {

    private let expander = SnippetExpander()

    private let snippets = [
        Snippet(trigger: "sig", expansion: "Jane Doe\nCEO, Example"),
        Snippet(trigger: "so what", expansion: "SO-WHAT"),
        Snippet(trigger: "myemail", expansion: "me@example.com")
    ]

    /// The shipping pipeline: expand into masks, style, restore.
    private func pipeline(_ text: String, style: WritingStyle, space: Bool = false) -> String {
        let masked = expander.expandMasked(in: text, using: snippets)
        let styled = WritingStyleEngine.format(
            masked.text,
            style: style,
            globalAutoCapitalize: true,
            globalTrailingSpace: space
        )
        return masked.restore(in: styled)
    }

    func testMaskingRoundTripsWithoutAStyle() {
        let masked = expander.expandMasked(in: "hello sig", using: snippets)
        XCTAssertFalse(masked.text.contains("Jane"), "the expansion should be masked")
        XCTAssertEqual(masked.restore(in: masked.text), expander.expand(in: "hello sig", using: snippets))
    }

    func testExpansionEndingInWhitespaceKeepsOneFollowingSeparator() {
        let snippets = [Snippet(trigger: "sign", expansion: "Kind regards, ")]
        let masked = expander.expandMasked(in: "sign Jane", using: snippets)
        XCTAssertEqual(masked.restore(in: masked.text), "Kind regards, Jane")
    }

    /// The newline counterpart of the test above, and the case a review flagged
    /// as a lost separator. The expansion's own "\n" ends the line, so the
    /// following word starts the next one at column zero — restoring the user's
    /// space would indent it by a stray column instead.
    func testExpansionEndingInNewlineStartsFollowingTextAtColumnZero() {
        let snippets = [Snippet(trigger: "sig", expansion: "Jane Doe\nCEO\n")]
        let masked = expander.expandMasked(in: "sig thanks for the review", using: snippets)
        let styled = WritingStyleEngine.format(
            masked.text,
            style: .chat,
            globalAutoCapitalize: true,
            globalTrailingSpace: false
        )
        XCTAssertEqual(masked.restore(in: styled), "Jane Doe\nCEO\nthanks for the review")
    }

    /// Back-to-back expansions must not lose the boundary between them.
    func testAdjacentNewlineEndingExpansionsKeepTheirBoundaries() {
        let snippets = [Snippet(trigger: "sig", expansion: "Jane Doe\nCEO\n")]
        let masked = expander.expandMasked(in: "sig sig done", using: snippets)
        XCTAssertEqual(
            masked.restore(in: masked.text),
            "Jane Doe\nCEO\nJane Doe\nCEO\ndone"
        )
    }

    /// The one place Plain / feature-off output legitimately differs from the
    /// previous release, pinned so the difference stays deliberate.
    ///
    /// The old pipeline polished before expanding, so it appended its trailing
    /// space *after* an expansion that already ended in one. Expanding first
    /// and masking the expansion collapses that, which is the wanted result —
    /// but it means "byte-for-byte the old pipeline" holds for everything
    /// except a whitespace-ending snippet.
    func testPassthroughDiffersFromTheOldPipelineOnlyForWhitespaceEndingSnippets() {
        let snippets = [Snippet(trigger: "sign", expansion: "Kind regards, ")]

        func old(_ utterance: String) -> String {
            expander.expand(
                in: DictationOutputFormatter.apply(
                    utterance, autoCapitalize: true, appendTrailingSpace: true),
                using: snippets)
        }
        func new(_ utterance: String) -> String {
            let masked = expander.expandMasked(in: utterance, using: snippets)
            return masked.restore(in: WritingStyleEngine.format(
                masked.text, rules: .passthrough,
                globalAutoCapitalize: true, globalTrailingSpace: true))
        }

        // The exception, wherever the expansion sits: the old pipeline left a
        // double space, because it appended its own after the expansion's.
        XCTAssertEqual(old("hello sign"), "Hello Kind regards,  ")
        XCTAssertEqual(new("hello sign"), "Hello Kind regards, ")
        XCTAssertEqual(old("sign"), "Kind regards,  ")
        XCTAssertEqual(new("sign"), "Kind regards, ")

        // Utterances without a whitespace-ending expansion are unchanged.
        for utterance in ["hello there", "just words", "nothing to expand"] {
            XCTAssertEqual(old(utterance), new(utterance), "parity broke for: \(utterance)")
        }
    }

    func testTriggerSurvivesAStyleThatTrimsLeadingFiller() {
        // Code style trims a leading "so", which used to eat the trigger's own
        // first word before the expander ever saw it.
        XCTAssertEqual(pipeline("so what now", style: .code), "SO-WHAT now")
    }

    func testExpansionIsNotRecasedBySentenceCase() {
        XCTAssertEqual(pipeline("myemail is my address", style: .chat), "me@example.com is my address")
    }

    func testExpansionIsNotReshapedBySymbolRules() {
        // "me@example.com" contains a dot the Code style would otherwise be
        // free to treat as part of an identifier.
        XCTAssertEqual(pipeline("email myemail now", style: .code), "email me@example.com now")
    }

    func testNoPeriodIsBoltedOntoASignatureBlock() {
        XCTAssertEqual(pipeline("regards sig", style: .email), "Regards Jane Doe\nCEO, Example")
    }

    func testEmailStyleStillPunctuatesOrdinarySentences() {
        XCTAssertEqual(pipeline("thanks for the update", style: .email), "Thanks for the update.")
    }

    func testNoTrailingSpaceAfterAnExpansionThatEndsInOne() {
        // The trailing-space rule skips text that already ends in whitespace.
        // The mask is what hid that from it, so restoring has to put it back.
        let snippets = [Snippet(trigger: "sig", expansion: "Jane Doe\nCEO\n")]
        let masked = expander.expandMasked(in: "regards sig", using: snippets)
        let styled = WritingStyleEngine.format(
            masked.text,
            style: .chat,
            globalAutoCapitalize: true,
            globalTrailingSpace: true
        )
        XCTAssertEqual(masked.restore(in: styled), "Regards Jane Doe\nCEO\n")
    }

    func testTrailingSpaceStillFollowsAnInlineExpansion() {
        let snippets = [Snippet(trigger: "brb", expansion: "be right back")]
        let masked = expander.expandMasked(in: "brb", using: snippets)
        let styled = WritingStyleEngine.format(
            masked.text,
            style: .chat,
            globalAutoCapitalize: true,
            globalTrailingSpace: true
        )
        XCTAssertEqual(masked.restore(in: styled), "be right back ")
    }

    func testTextWithoutTriggersIsUnchangedByMasking() {
        let masked = expander.expandMasked(in: "nothing to expand here", using: snippets)
        XCTAssertEqual(masked.text, "nothing to expand here")
        XCTAssertTrue(masked.isEmpty)
    }

    func testSeveralExpansionsKeepTheirOrder() {
        let masked = expander.expandMasked(in: "myemail then sig", using: snippets)
        XCTAssertEqual(masked.replacements, ["me@example.com", "Jane Doe\nCEO, Example"])
        XCTAssertEqual(masked.restore(in: masked.text), "me@example.com then Jane Doe\nCEO, Example")
    }
}
