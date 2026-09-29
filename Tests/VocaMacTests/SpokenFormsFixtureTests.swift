// SpokenFormsFixtureTests.swift
// VocaMac Tests
//
// Runs the shared case files in Fixtures/: spoken-numbers.tsv and
// spoken-emoji.tsv. The same files are the contract for VocaPhone, so a case
// belongs there rather than in a Swift test whenever it is a plain input and
// an expected output.

import XCTest
@testable import VocaMac

final class SpokenFormsFixtureTests: XCTestCase {
    /// One row of a case file.
    struct Case {
        let mode: String
        let input: String
        let expected: String
        let note: String
        let line: Int
    }

    /// Reads a tab-separated case file: `input`, `expected`, `note`, with
    /// `## <mode>` lines switching the mode for the rows after them.
    static func cases(_ name: String) throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let text = try String(contentsOf: url, encoding: .utf8)
        var mode = ""
        var cases: [Case] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.hasPrefix("## ") {
                mode = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map {
                $0.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
            }
            guard columns.count >= 2 else {
                XCTFail("\(name):\(offset + 1) needs an input and an expected column")
                continue
            }
            cases.append(Case(
                mode: mode, input: columns[0], expected: columns[1],
                note: columns.count > 2 ? columns[2] : "", line: offset + 1
            ))
        }
        return cases
    }

    func testSpokenNumberCases() throws {
        let cases = try Self.cases("spoken-numbers.tsv")
        XCTAssertGreaterThan(cases.count, 200)
        for testCase in cases {
            XCTAssert(["digits", "symbols"].contains(testCase.mode), "line \(testCase.line): unknown mode")
            let output = SpokenNumbers.digits(in: testCase.input, symbols: testCase.mode == "symbols")
            XCTAssertEqual(
                output, testCase.expected,
                "spoken-numbers.tsv:\(testCase.line) [\(testCase.mode)] \(testCase.note)"
            )
        }
    }

    func testSpokenEmojiCases() throws {
        let cases = try Self.cases("spoken-emoji.tsv")
        XCTAssertGreaterThan(cases.count, 100)
        for testCase in cases {
            XCTAssertEqual(
                SpokenEmoji.glyphs(in: testCase.input), testCase.expected,
                "spoken-emoji.tsv:\(testCase.line) \(testCase.note)"
            )
        }
    }

    /// Converting what was already converted changes nothing, in either mode.
    func testConvertingTwiceChangesNothing() throws {
        for testCase in try Self.cases("spoken-numbers.tsv") {
            let symbols = testCase.mode == "symbols"
            let once = SpokenNumbers.digits(in: testCase.input, symbols: symbols)
            XCTAssertEqual(SpokenNumbers.digits(in: once, symbols: symbols), once, "line \(testCase.line)")
        }
        for testCase in try Self.cases("spoken-emoji.tsv") {
            let once = SpokenEmoji.glyphs(in: testCase.input)
            XCTAssertEqual(SpokenEmoji.glyphs(in: once), once, "line \(testCase.line)")
        }
    }
}
