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

    func testUnrelatedTextDoesNotAlign() {
        XCTAssertNil(newText("Something else entirely was said here.", after: "we ship on friday"))
        XCTAssertNil(newText("", after: "we ship on friday"))
    }

    func testAllContextMeansNothingNew() {
        XCTAssertEqual(newText("We ship on Friday.", after: "we ship on friday"), "")
    }
}
