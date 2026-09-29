// UndoCenterTests.swift
// VocaMac
//
// Tests for the Settings "Undo" offer that follows a list removal.

import XCTest
@testable import VocaMac

@MainActor
final class UndoCenterTests: XCTestCase {

    private struct Item: Identifiable, Equatable {
        let id: Int
        var name: String
    }

    private final class Box {
        var items: [Item] = []
    }

    private func makeBox(_ ids: [Int]) -> Box {
        let box = Box()
        box.items = ids.map { Item(id: $0, name: "item \($0)") }
        return box
    }

    func testRemoveTakesElementOutAndOffersUndo() {
        let center = UndoCenter()
        let box = makeBox([1, 2, 3])

        let removed = center.remove(id: 2, from: \Box.items, of: box, message: "Removed 2")

        XCTAssertTrue(removed)
        XCTAssertEqual(box.items.map(\.id), [1, 3])
        XCTAssertEqual(center.current?.message, "Removed 2")
    }

    func testUndoRestoresAtOriginalPositionAndClearsOffer() {
        let center = UndoCenter()
        let box = makeBox([1, 2, 3])
        center.remove(id: 2, from: \Box.items, of: box, message: "Removed 2")

        center.undo()

        XCTAssertEqual(box.items.map(\.id), [1, 2, 3])
        XCTAssertNil(center.current)
    }

    func testUndoClampsIndexWhenListShrankMeanwhile() {
        let center = UndoCenter()
        let box = makeBox([1, 2, 3])
        center.remove(id: 3, from: \Box.items, of: box, message: "Removed 3")
        box.items.removeAll { $0.id == 2 }

        center.undo()

        XCTAssertEqual(box.items.map(\.id), [1, 3])
    }

    func testUndoDoesNotDuplicateAnElementReAddedMeanwhile() {
        let center = UndoCenter()
        let box = makeBox([1, 2])
        center.remove(id: 2, from: \Box.items, of: box, message: "Removed 2")
        box.items.append(Item(id: 2, name: "added again"))

        center.undo()

        XCTAssertEqual(box.items.filter { $0.id == 2 }.count, 1)
        XCTAssertEqual(box.items.last?.name, "added again")
    }

    func testRemoveUnknownIdChangesNothingAndOffersNothing() {
        let center = UndoCenter()
        let box = makeBox([1])

        let removed = center.remove(id: 9, from: \Box.items, of: box, message: "Removed 9")

        XCTAssertFalse(removed)
        XCTAssertEqual(box.items.count, 1)
        XCTAssertNil(center.current)
    }

    func testNewOfferReplacesTheOldOneWhichBecomesPermanent() {
        let center = UndoCenter()
        let box = makeBox([1, 2, 3])
        center.remove(id: 1, from: \Box.items, of: box, message: "Removed 1")
        center.remove(id: 2, from: \Box.items, of: box, message: "Removed 2")

        center.undo()

        XCTAssertEqual(box.items.map(\.id), [2, 3])
        XCTAssertNil(center.current)
    }

    func testDismissKeepsTheRemoval() {
        let center = UndoCenter()
        let box = makeBox([1, 2])
        center.remove(id: 1, from: \Box.items, of: box, message: "Removed 1")

        center.dismiss()
        center.undo()

        XCTAssertEqual(box.items.map(\.id), [2])
    }

    func testOfferExpiresAfterItsDuration() async throws {
        let center = UndoCenter(duration: .milliseconds(30))
        center.offer("Removed") {}
        XCTAssertNotNil(center.current)

        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(center.current)
    }

    func testEarlierOfferTimerDoesNotExpireALaterOffer() async throws {
        let center = UndoCenter(duration: .milliseconds(150))
        center.offer("first") {}
        try await Task.sleep(for: .milliseconds(90))
        center.offer("second") {}
        try await Task.sleep(for: .milliseconds(90))

        XCTAssertEqual(center.current?.message, "second")
    }
}
