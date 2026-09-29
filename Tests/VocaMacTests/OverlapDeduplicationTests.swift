import XCTest
@testable import VocaMac

final class OverlapDeduplicationTests: XCTestCase {
    private func newText(_ decoded: String, after previous: String, seconds: Double = 8) -> String? {
        OverlapDeduplication.newText(decoded: decoded, previous: previous, contextSeconds: seconds)
    }

    func testRepeatedContextIsRemoved() {
        XCTAssertEqual(
            newText("I missed the train for almost an hour. Crying emoji. Crying emoji.",
                    after: "I missed the train for almost an hour."),
            "Crying emoji. Crying emoji."
        )
    }

    func testSmallWordingChangesInTheContextStillAlign() {
        XCTAssertEqual(
            newText("we reviewed the pull request with the team. Sounds good.",
                    after: "We reviewed the pull-request with our team,"),
            "Sounds good."
        )
    }

    func testAPhraseRepeatedAcrossTheBoundaryIsKept() {
        XCTAssertEqual(newText("thank you for coming, thank you", after: "thank you for coming,"), "thank you")
    }

    func testTwoWordsThatRecurInNewSpeechAreNotContext() {
        XCTAssertNil(newText("the meeting is on Friday and we will discuss it", after: "we ship on Friday", seconds: 2))
    }

    func testUnrelatedTextDoesNotAlign() {
        XCTAssertNil(newText("Something else entirely was said here.", after: "we ship on friday"))
        XCTAssertNil(newText("", after: "we ship on friday"))
    }

    func testAllContextMeansNothingNew() {
        XCTAssertEqual(newText("We ship on Friday.", after: "we ship on friday"), "")
    }

    // MARK: - Partial context

    func testContextCoveringTheEndOfThePreviousPieceAligns() {
        let previous = "we spent the morning on the budget and then we reviewed the design with the team"
        XCTAssertEqual(
            OverlapDeduplication.newText(
                decoded: "reviewed the design with the team. After lunch we shipped it.",
                previous: previous, contextSeconds: 2, contextShare: 0.35
            ),
            "After lunch we shipped it."
        )
    }

    func testPartialContextStillNeedsMostOfItsWords() {
        XCTAssertNil(OverlapDeduplication.newText(
            decoded: "the team is on Friday and we will discuss it",
            previous: "we spent the morning on the budget and then we reviewed the design with the team",
            contextSeconds: 2, contextShare: 0.35
        ))
    }

    func testAlignmentSaysWhereTheContextStarts() {
        let alignment = OverlapDeduplication.align(
            decoded: "ning the design review. Then lunch.",
            previous: "We spent the morning on the design review.",
            contextSeconds: 2, contextShare: 0.5
        )
        // "ning" is half a word cut by the context start.
        XCTAssertEqual(alignment, OverlapDeduplication.Alignment(previousStart: 5, decodedStart: 1, decodedEnd: 4))
    }

    func testEditDistanceCountsWordEdits() {
        XCTAssertEqual(OverlapDeduplication.editDistance(["a", "b", "c"], ["a", "x", "c"]), 1)
        XCTAssertEqual(OverlapDeduplication.editDistance([], ["a", "b"]), 2)
        XCTAssertEqual(OverlapDeduplication.editDistance(["a", "b"], ["a", "b"]), 0)
    }

    func testLookAlikesAreOneWordHeardTwoWays() {
        XCTAssertTrue(OverlapDeduplication.areLookAlikes("flower", "flour"))
        XCTAssertTrue(OverlapDeduplication.areLookAlikes("their", "there"))
        XCTAssertFalse(OverlapDeduplication.areLookAlikes("it", "in"), "too short to tell")
        XCTAssertFalse(OverlapDeduplication.areLookAlikes("friday", "monday"))
        XCTAssertFalse(OverlapDeduplication.areLookAlikes("same", "same"))
    }
}
