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

    // MARK: - Newer work wins

    func testUndoDoesNotRestoreAnElementThatConflictsWithANewerOne() {
        let center = UndoCenter()
        let box = makeBox([1])
        center.remove(
            id: 1, from: \Box.items, of: box, message: "Removed",
            conflictsWith: { $0.name == $1.name }
        )
        box.items.append(Item(id: 7, name: "item 1"))

        center.undo()

        XCTAssertEqual(box.items.map(\.id), [7])
    }

    func testRemoveAllThenUndoKeepsElementsAddedMeanwhile() {
        let center = UndoCenter()
        let box = makeBox([1, 2])
        center.removeAll(from: \Box.items, of: box, message: "Removed 2")
        XCTAssertTrue(box.items.isEmpty)
        box.items.append(Item(id: 9, name: "new"))

        center.undo()

        XCTAssertEqual(box.items.map(\.id), [1, 2, 9])
    }

    func testRemoveAllUndoSkipsConflictsAndRunsAfterUndo() {
        let center = UndoCenter()
        let box = makeBox([1, 2])
        box.items[1].name = "same"
        center.removeAll(
            from: \Box.items, of: box, message: "Removed 2",
            conflictsWith: { $0.name == $1.name }
        )
        box.items.append(Item(id: 9, name: "same"))
        var ran = false
        center.removeAll(from: \Box.items, of: box, message: "again", afterUndo: { ran = true })
        box.items = [Item(id: 9, name: "same")]

        center.undo()

        XCTAssertTrue(ran)
        XCTAssertEqual(box.items.map(\.id), [9])
    }

    func testRemoveAllOnAnEmptyListOffersNothing() {
        let center = UndoCenter()
        let box = makeBox([])

        center.removeAll(from: \Box.items, of: box, message: "Removed 0")

        XCTAssertNil(center.current)
    }

    func testSnippetConflictIgnoresCaseAndSpaces() {
        XCTAssertTrue(Snippet.sharesTrigger(
            Snippet(trigger: " My Mail ", expansion: "a"), Snippet(trigger: "my mail", expansion: "b")))
        XCTAssertFalse(Snippet.sharesTrigger(
            Snippet(trigger: "mail", expansion: "a"), Snippet(trigger: "vmac", expansion: "a")))
    }

    func testReplacementConflictOnlyOnASharedSpokenForm() {
        let a = WordReplacement(heard: "get hub, git hub", replacement: "GitHub")
        XCTAssertTrue(WordReplacement.overlaps(a, WordReplacement(heard: "GIT HUB", replacement: "Git Hub")))
        XCTAssertFalse(WordReplacement.overlaps(a, WordReplacement(heard: "jira", replacement: "Jira")))
    }

    func testSameTypedTextWithDifferentSpokenFormsIsNotAConflict() {
        // Two rows can end up with the same "Type" text after an edit; undoing
        // the removal of one must bring its spoken form back.
        let a = WordReplacement(heard: "get hub", replacement: "GitHub")
        let b = WordReplacement(heard: "gh", replacement: "GitHub")
        XCTAssertFalse(WordReplacement.overlaps(a, b))
    }

    func testAppRuleConflictUsesAppIdentityNotRuleID() {
        let original = AppStyleBinding(id: "com.apple.Terminal", displayName: "Terminal",
                                       bundleIdentifier: "com.apple.Terminal", style: .plain)
        let imported = AppStyleBinding(id: "imported-1", displayName: "Terminal",
                                       bundleIdentifier: "com.apple.Terminal", style: .plain)
        let other = AppStyleBinding(id: "com.apple.mail", displayName: "Mail",
                                    bundleIdentifier: "com.apple.mail", style: .plain)
        XCTAssertTrue(AppStyleBinding.sharesApp(original, imported))
        XCTAssertFalse(AppStyleBinding.sharesApp(original, other))
    }

    func testABundledAppAndAnUnbundledToolWithTheSameExecutableAreDifferentApps() {
        let bundled = AppStyleBinding(id: "com.example.Foo", displayName: "Foo",
                                      bundleIdentifier: "com.example.Foo", processName: "foo", style: .plain)
        let cliTool = AppStyleBinding(id: "foo", displayName: "foo", processName: "foo", style: .code)
        XCTAssertFalse(AppStyleBinding.sharesApp(bundled, cliTool))
        XCTAssertFalse(AppStyleBinding.sharesApp(cliTool, bundled))
    }

    func testTerminalByBundleAndByProcessNameAreTheSameApp() {
        let bundled = AppStyleBinding(id: "com.apple.Terminal", displayName: "Terminal",
                                      bundleIdentifier: "com.apple.Terminal", style: .plain)
        let typed = AppStyleBinding(id: "Terminal", displayName: "Terminal", processName: "Terminal", style: .plain)
        XCTAssertTrue(AppStyleBinding.sharesApp(bundled, typed))
    }

    func testTwoDifferentBundleIDsAreDifferentAppsEvenWithTheSameExecutable() {
        let a = AppStyleBinding(id: "com.example.Code", displayName: "Code",
                                bundleIdentifier: "com.example.Code", processName: "Electron", style: .code)
        let b = AppStyleBinding(id: "com.example.Fork", displayName: "Fork",
                                bundleIdentifier: "com.example.Fork", processName: "Electron", style: .code)
        XCTAssertFalse(AppStyleBinding.sharesApp(a, b))
    }

    func testRemoveAllUndoSkipsAnAppRuleImportedUnderAnotherID() {
        final class Holder { var rules: [AppStyleBinding] = [] }
        let holder = Holder()
        holder.rules = [AppStyleBinding(id: "com.apple.Terminal", displayName: "Terminal",
                                        bundleIdentifier: "com.apple.Terminal", style: .plain)]
        let center = UndoCenter()
        center.removeAll(from: \Holder.rules, of: holder, message: "Removed 1",
                         conflictsWith: AppStyleBinding.sharesApp)
        holder.rules = [AppStyleBinding(id: "imported-1", displayName: "Terminal",
                                        bundleIdentifier: "com.apple.Terminal", style: .code)]

        center.undo()

        XCTAssertEqual(holder.rules.map(\.id), ["imported-1"])
    }

    func testWebsiteConflictIgnoresCase() {
        let a = WebsiteStyleBinding(hostPattern: "Example.com", displayName: "A", style: .plain)
        let b = WebsiteStyleBinding(hostPattern: " example.COM", displayName: "B", style: .plain)
        let c = WebsiteStyleBinding(hostPattern: "other.com", displayName: "C", style: .plain)
        XCTAssertTrue(WebsiteStyleBinding.sharesHost(a, b))
        XCTAssertFalse(WebsiteStyleBinding.sharesHost(a, c))
    }
}
