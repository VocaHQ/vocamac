// LipCommandMatcherTests.swift
// VocaMacTests
//
// Mouthed commands: the same word mouthed faster or slower matches its
// takes, two different words are told apart, anything else is "not sure",
// and the self-test says whether the takes separate at all.

import XCTest
@testable import VocaMac

final class LipCommandMatcherTests: XCTestCase {

    // Two mouth movements that look different: a double opening ("send it")
    // and a widening with the lips nearly closed ("eee").
    private func doubleOpen(stretch: Double = 1, amplitude: Double = 0.3) -> [[Double]] {
        LipSequence.features(LipFrameFactory.frames(from: 0, seconds: 0.8 * stretch, openness: { elapsed in
            0.02 + amplitude * (1 - cos(2 * Double.pi * 2.5 * elapsed / stretch)) / 2
        }))
    }

    private func widen(stretch: Double = 1, amount: Double = 0.15) -> [[Double]] {
        LipSequence.features(LipFrameFactory.frames(
            from: 0, seconds: 0.8 * stretch,
            openness: { _ in 0.04 },
            width: { elapsed in 0.4 + amount * sin(Double.pi * elapsed / (0.8 * stretch)) },
            roundness: { elapsed in 0.35 - 0.12 * sin(Double.pi * elapsed / (0.8 * stretch)) }
        ))
    }

    private func command(_ action: SilentCommandAction, _ takes: [[[Double]]]) -> SilentCommand {
        SilentCommand(action: action, word: action.suggestedWord, takes: takes.map { LipTake(frames: $0) })
    }

    private var send: SilentCommand {
        command(.pressReturn, [doubleOpen(), doubleOpen(stretch: 0.9, amplitude: 0.28), doubleOpen(stretch: 1.1, amplitude: 0.32)])
    }

    private var undo: SilentCommand {
        command(.undo, [widen(), widen(stretch: 0.9, amount: 0.14), widen(stretch: 1.1, amount: 0.16)])
    }

    // MARK: Distance

    func testDistanceIsZeroForIdenticalTakesAndSmallForATempoChange() {
        let take = doubleOpen()
        XCTAssertEqual(DynamicTimeWarping.distance(take, take), 0, accuracy: 1e-12)
        let slower = DynamicTimeWarping.distance(take, doubleOpen(stretch: 1.25))
        let different = DynamicTimeWarping.distance(take, widen())
        XCTAssertLessThan(slower, different)
    }

    func testAnEmptySequenceIsInfinitelyFar() {
        XCTAssertEqual(DynamicTimeWarping.distance([], doubleOpen()), .infinity)
    }

    // MARK: Matching

    func testEachWordMatchesItsOwnCommand() throws {
        // `send` and `undo` build new commands (new ids) on every read.
        let commands = [send, undo]
        let matcher = try XCTUnwrap(LipCommandMatcher(commands: commands))

        let sendMatch = matcher.match(doubleOpen(stretch: 1.05, amplitude: 0.29))
        XCTAssertEqual(sendMatch.best?.commandID, commands[0].id)
        XCTAssertTrue(sendMatch.isAccepted)

        let undoMatch = matcher.match(widen(stretch: 1.05))
        XCTAssertEqual(undoMatch.best?.commandID, commands[1].id)
        XCTAssertTrue(undoMatch.isAccepted)
    }

    func testStillLipsMatchNothing() throws {
        let matcher = try XCTUnwrap(LipCommandMatcher(commands: [send, undo]))
        let still = LipSequence.features(LipFrameFactory.still(from: 0, seconds: 0.8))
        XCTAssertFalse(matcher.match(still).isAccepted)
    }

    func testWithOneCommandTheDistanceAloneDecides() throws {
        let matcher = try XCTUnwrap(LipCommandMatcher(commands: [send]))
        XCTAssertTrue(matcher.match(doubleOpen(stretch: 1.02)).isAccepted)
        XCTAssertFalse(matcher.match(widen()).isAccepted)
    }

    func testNoTakesNoMatcher() {
        XCTAssertNil(LipCommandMatcher(commands: [SilentCommand(action: .undo, word: "undo")]))
        XCTAssertNil(LipCommandMatcher(commands: []))
    }

    func testTheMarginComparesBestWithRunnerUp() {
        XCTAssertEqual(LipCommandMatcher.margin([0.2, 0.4]), 0.5, accuracy: 1e-9)
        XCTAssertEqual(LipCommandMatcher.margin([0.3]), 0)
        XCTAssertEqual(LipCommandMatcher.margin([0.3, 0.3]), 0, accuracy: 1e-9)
    }

    // MARK: Self-test

    func testDistinctCommandsAreReliable() throws {
        var generator = LipTestGenerator(seed: 7)
        let evaluation = try XCTUnwrap(LipCommandEvaluation.run(commands: [send, undo], permutations: 200, using: &generator))
        XCTAssertEqual(evaluation.commandCount, 2)
        XCTAssertEqual(evaluation.takeCount, 6)
        XCTAssertEqual(evaluation.accuracy, 1, accuracy: 1e-9)
        XCTAssertEqual(evaluation.chance, 0.5, accuracy: 1e-9)
        XCTAssertTrue(evaluation.isReliable)
    }

    func testLookalikeCommandsAreNotReliable() throws {
        var generator = LipTestGenerator(seed: 7)
        let lookalike = command(.undo, [doubleOpen(stretch: 1.02), doubleOpen(stretch: 0.97), doubleOpen(stretch: 1.06)])
        let evaluation = try XCTUnwrap(LipCommandEvaluation.run(commands: [send, lookalike], permutations: 200, using: &generator))
        XCTAssertFalse(evaluation.isReliable)
    }

    func testTheSelfTestNeedsTwoCommandsWithTwoTakes() {
        XCTAssertNil(LipCommandEvaluation.run(commands: [send]))
        XCTAssertNil(LipCommandEvaluation.run(commands: [send, command(.undo, [widen()])]))
    }
}

/// A deterministic generator, so permutation tests give the same answer every run.
private struct LipTestGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
