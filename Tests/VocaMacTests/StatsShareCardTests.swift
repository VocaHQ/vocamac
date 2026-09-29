// StatsShareCardTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class StatsShareCardTests: XCTestCase {

    func testSnapshotFromUserStats() {
        var stats = UserStats()
        stats.totalWords = 1200
        stats.totalTranscriptions = 40
        stats.totalAudioDurationSeconds = 600 // 20 WPM from 1200 words / 10 minutes
        stats.currentStreak = 3
        stats.bestStreak = 12

        let snapshot = StatsShareSnapshot.from(stats)
        XCTAssertEqual(snapshot.totalWords, 1200)
        XCTAssertEqual(snapshot.totalTranscriptions, 40)
        XCTAssertEqual(snapshot.averageWPM, 120.0, accuracy: 0.01)
        XCTAssertEqual(snapshot.currentStreak, 3)
        XCTAssertEqual(snapshot.bestStreak, 12)
    }

    // MARK: - Share message

    private func makeSnapshot() -> StatsShareSnapshot {
        StatsShareSnapshot(
            totalWords: 12_500,
            totalTranscriptions: 42,
            totalAudioDurationSeconds: 3600,
            averageWPM: 138,
            currentStreak: 7,
            bestStreak: 12
        )
    }

    func testMessageIncludesHeadlineStatsAndHandle() {
        let message = StatsShareComposer.message(for: makeSnapshot(), destination: .x)

        XCTAssertTrue(message.contains("12,500 words"), message)
        XCTAssertTrue(message.contains("42 sessions"), message)
        XCTAssertTrue(message.contains("138 WPM"), message)
        XCTAssertTrue(message.contains("7-day streak"), message)
        XCTAssertTrue(message.contains("@vocahq"), message)
        XCTAssertTrue(message.contains(StatsShareComposer.siteURL), message)
    }

    /// VocaMac has no LinkedIn account, so a LinkedIn post must not sign off
    /// with a handle at all rather than one that 404s.
    func testMessageOmitsHandleWhereThereIsNoAccount() {
        let message = StatsShareComposer.message(for: makeSnapshot(), destination: .linkedIn)

        XCTAssertFalse(message.contains("@vocahq"), message)
        XCTAssertFalse(message.lowercased().contains("linkedin.com"), message)
        XCTAssertTrue(message.hasSuffix(StatsShareComposer.siteURL), message)
    }

    /// The share picker's destination is unknown, so the post has no handle.
    func testSharePickerMessageOmitsHandle() {
        let message = StatsShareComposer.message(for: makeSnapshot())

        XCTAssertFalse(message.contains("@vocahq"), message)
        XCTAssertTrue(message.contains("12,500 words"), message)
        XCTAssertTrue(message.hasSuffix(StatsShareComposer.siteURL), message)
    }

    @MainActor
    func testSharingItemsAreTheCardFileThenThePostText() throws {
        let items = StatsShareExporter.sharingItems(for: makeSnapshot())

        XCTAssertEqual(items.last as? String, StatsShareComposer.message(for: makeSnapshot()))
        let card = try XCTUnwrap(items.first as? URL)
        XCTAssertEqual(card.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: card.path))
    }

    /// A later share must not overwrite a card an earlier share still holds.
    @MainActor
    func testEachShareWritesItsOwnCardFile() throws {
        let first = try XCTUnwrap(StatsShareExporter.sharingItems(for: makeSnapshot()).first as? URL)
        let firstPNG = try Data(contentsOf: first)

        var later = makeSnapshot()
        later.totalWords = 99_999
        let second = try XCTUnwrap(StatsShareExporter.sharingItems(for: later).first as? URL)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "VocaMac Stats.png")
        XCTAssertEqual(try Data(contentsOf: first), firstPNG)
    }

    /// X weighs most emoji as 2 units and normalizes every URL to 23, so
    /// `String.count` is not the metric X enforces.
    private func xPostLength(_ message: String) -> Int {
        let withoutURL = message.replacingOccurrences(of: StatsShareComposer.siteURL, with: "")
        let weighted = withoutURL.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0...4351, 8192...8205, 8208...8223, 8242...8247:
                return total + 1
            default:
                return total + 2
            }
        }
        return weighted + 23
    }

    func testMessageFitsWithinXPostLimit() {
        let snapshot = StatsShareSnapshot(
            totalWords: 987_654_321,
            totalTranscriptions: 123_456,
            totalAudioDurationSeconds: 9_000_000,
            averageWPM: 999,
            currentStreak: 4321,
            bestStreak: 5000
        )

        let message = StatsShareComposer.message(for: snapshot, destination: .x)
        XCTAssertLessThanOrEqual(xPostLength(message), 280, message)
    }

    func testMessageOmitsEmptyStats() {
        let message = StatsShareComposer.message(for: StatsShareSnapshot.from(UserStats()), destination: .x)

        XCTAssertTrue(message.contains("0 words"), message)
        XCTAssertFalse(message.contains("sessions"), message)
        XCTAssertFalse(message.contains("WPM"), message)
        XCTAssertFalse(message.contains("streak"), message)
        // `.dropAll` renders a zero duration as "0 minutes", not "", so the
        // clause has to be filtered out on the value.
        XCTAssertFalse(message.contains("talking"), message)
        XCTAssertFalse(message.contains("\n\n\n"), message)
    }

    func testMessageOmitsDurationUnderOneMinute() {
        var stats = UserStats()
        stats.totalWords = 40
        stats.totalTranscriptions = 1
        stats.totalAudioDurationSeconds = 30

        let message = StatsShareComposer.message(for: StatsShareSnapshot.from(stats), destination: .x)

        XCTAssertFalse(message.contains("talking"), message)
        XCTAssertFalse(message.contains("0 minutes"), message)
        XCTAssertTrue(message.contains("1 session"), message)
        XCTAssertFalse(message.contains("1 sessions"), message)
    }

    func testMessageIncludesDurationFromOneMinute() {
        var stats = UserStats()
        stats.totalWords = 100
        stats.totalAudioDurationSeconds = 60

        let message = StatsShareComposer.message(for: StatsShareSnapshot.from(stats), destination: .x)

        XCTAssertTrue(message.contains("1 minute of talking"), message)
    }

    /// The copy around these numbers is hardcoded English, so the numbers and
    /// units must not follow the user's locale ("12.500", "2.500 Stunden").
    func testMessageNumbersDoNotFollowTheUserLocale() {
        var stats = UserStats()
        stats.totalWords = 12_500
        stats.totalAudioDurationSeconds = 9_000

        let message = StatsShareComposer.message(for: StatsShareSnapshot.from(stats), destination: .x)

        XCTAssertTrue(message.contains("12,500 words"), message)
        XCTAssertTrue(message.contains("2 hours, 30 minutes of talking"), message)
    }

    // MARK: - Composer URLs

    func testComposerURLForX() throws {
        let url = try XCTUnwrap(StatsShareComposer.composerURL(for: makeSnapshot(), destination: .x))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "x.com")
        XCTAssertEqual(components.path, "/intent/post")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "text" })?.value,
            StatsShareComposer.message(for: makeSnapshot(), destination: .x)
        )
    }

    func testComposerURLForLinkedIn() throws {
        let url = try XCTUnwrap(StatsShareComposer.composerURL(for: makeSnapshot(), destination: .linkedIn))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "www.linkedin.com")
        XCTAssertEqual(components.path, "/feed/")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "shareActive" })?.value, "true")
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "text" })?.value,
            StatsShareComposer.message(for: makeSnapshot(), destination: .linkedIn)
        )
    }

    func testComposerURLPercentEncodesSeparatorsInsideValues() throws {
        let snapshot = makeSnapshot()
        let url = try XCTUnwrap(StatsShareComposer.composerURL(for: snapshot, destination: .linkedIn))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try XCTUnwrap(components.percentEncodedQuery)

        // One `&` per param boundary, none from the post text itself.
        XCTAssertEqual(query.filter { $0 == "&" }.count, 1, query)
        XCTAssertFalse(query.contains("+"), query)

        // Text containing separators still round-trips intact.
        XCTAssertEqual(
            components.queryItems?.first(where: { $0.name == "text" })?.value,
            StatsShareComposer.message(for: snapshot, destination: .linkedIn)
        )
    }

    func testEveryDestinationHasLabelAndComposerURL() {
        for destination in StatsShareDestination.allCases {
            XCTAssertFalse(destination.displayName.isEmpty)
            XCTAssertNotEqual(destination.handle, "", "\(destination) has an empty handle; use nil instead")
            XCTAssertNotNil(StatsShareComposer.composerURL(for: makeSnapshot(), destination: destination))
        }
    }

    func testPluralizedCountsUseSingularAndGroupedPluralForms() {
        XCTAssertEqual(StatsShareComposer.pluralized(1, "day"), "1 day")
        XCTAssertEqual(StatsShareComposer.pluralized(12_500, "word"), "12,500 words")
    }

    @MainActor
    func testFailedComposerOpenDoesNotAttemptToReplaceClipboard() {
        var copied = false

        let outcome = StatsShareExporter.share(
            makeSnapshot(),
            to: .x,
            openURL: { _ in false },
            copyCard: { _ in
                copied = true
                return true
            }
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertFalse(copied)
    }

    @MainActor
    func testSuccessfulComposerOpenCopiesCardAfterOpening() {
        var events: [String] = []

        let outcome = StatsShareExporter.share(
            makeSnapshot(),
            to: .linkedIn,
            openURL: { _ in
                events.append("opened")
                return true
            },
            copyCard: { _ in
                events.append("copied")
                return true
            }
        )

        XCTAssertEqual(outcome, .shared)
        XCTAssertEqual(events, ["opened", "copied"])
    }

    @MainActor
    func testOpenComposerReportsWhenCardCopyFails() {
        let outcome = StatsShareExporter.share(
            makeSnapshot(),
            to: .x,
            openURL: { _ in true },
            copyCard: { _ in false }
        )

        XCTAssertEqual(outcome, .sharedWithoutCard)
    }

    /// The encoder's actual guarantee, exercised with separators the generated
    /// post text does not happen to contain.
    func testEncoderEscapesSeparatorsInsideValues() throws {
        let hostile = "a&b+c;d=e?f #g"
        let url = try XCTUnwrap(
            StatsShareComposer.url("https://x.com/intent/post", query: [("text", hostile), ("via", "vocahq")])
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = try XCTUnwrap(components.percentEncodedQuery)

        // One `&` per param boundary, none leaking out of the value.
        XCTAssertEqual(query.filter { $0 == "&" }.count, 1, query)
        XCTAssertFalse(query.contains("+"), query)
        XCTAssertFalse(query.contains(";"), query)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "text" })?.value, hostile)
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "via" })?.value, "vocahq")
    }
}
