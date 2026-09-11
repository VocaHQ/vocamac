import AppKit
import XCTest
@testable import VocaMac

@MainActor
final class ClipboardPreservationTests: XCTestCase {

    /// Return once the injection queued by this test has finished.
    ///
    /// A paste is only the middle of an injection: the clipboard restore lands
    /// after a deliberate delay, and the queue slot is released later still.
    /// Sleeping for a guessed duration instead makes the assertions fail
    /// whenever a loaded machine takes longer, and leaves a half-finished
    /// injection to overlap the next test through the process-wide
    /// coordinator. Drain via a no-op on that coordinator so we never touch
    /// a pasteboard just to wait.
    private func drainInjectionQueue() async {
        await TextInjector.waitForInjectionQueueIdleForTesting()
    }

    func testManyRepresentationsArePreservedAcrossCooperativeCapture() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        let types = (0..<24).map { NSPasteboard.PasteboardType("com.vocamac.test.\($0)") }
        for (index, type) in types.enumerated() { item.setData(Data(repeating: UInt8(index), count: 2048), forType: type) }
        board.writeObjects([item])
        let pasted = expectation(description: "paste")
        let injector = TextInjector(pasteboard: board, accessibilityTrustedOverride: true,
                                    accessibilityInjectionOverride: { _ in false }, pasteActionOverride: {
            XCTAssertEqual(board.string(forType: .string), "dictation")
            pasted.fulfill()
        }, frontmostPIDProvider: { 123 })
        injector.inject(text: "dictation", preserveClipboard: true)
        await fulfillment(of: [pasted], timeout: 2)
        await drainInjectionQueue()
        for (index, type) in types.enumerated() {
            XCTAssertEqual(board.data(forType: type), Data(repeating: UInt8(index), count: 2048))
        }
    }

    func testChangingClipboardDuringSnapshotDoesNotRestoreMixedGenerations() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let types = (0..<24).map { NSPasteboard.PasteboardType("com.vocamac.test.\($0)") }
        let provider = ChangingClipboardProvider(board: board)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: types)
        board.writeObjects([item])
        let pasted = expectation(description: "paste after snapshot restart")
        let injector = TextInjector(pasteboard: board, accessibilityTrustedOverride: true,
                                    accessibilityInjectionOverride: { _ in false }, pasteActionOverride: {
            XCTAssertEqual(board.string(forType: .string), "dictation")
            pasted.fulfill()
        }, frontmostPIDProvider: { 123 })
        injector.inject(text: "dictation", preserveClipboard: true)
        await fulfillment(of: [pasted], timeout: 2)
        await drainInjectionQueue()
        XCTAssertEqual(board.string(forType: .string), "new clipboard")
        XCTAssertNil(board.data(forType: types[0]))
        withExtendedLifetime(provider) { }
    }
}

private final class ChangingClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    let board: NSPasteboard
    var scheduled = false
    init(board: NSPasteboard) { self.board = board }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(Data([1, 2, 3]), forType: type)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [board] in
            board.clearContents()
            board.setString("new clipboard", forType: .string)
        }
    }
}

extension ClipboardPreservationTests {
    func testInProcessAccessibilityWriteStaysOnMainQueue() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let inserted = expectation(description: "in-process accessibility insertion")
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true,
            accessibilityWorkerOverride: { _ in
                XCTAssertTrue(Thread.isMainThread)
                inserted.fulfill()
                return true
            }, frontmostPIDProvider: { ProcessInfo.processInfo.processIdentifier }
        )

        injector.inject(text: "result", preserveClipboard: false)

        await fulfillment(of: [inserted], timeout: 1)
        await drainInjectionQueue()
    }

    func testSlowAccessibilityWorkerDoesNotBlockMainQueue() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        let started = expectation(description: "worker started")
        let finished = expectation(description: "fallback pasted")
        let gate = DispatchSemaphore(value: 0)
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true,
            pasteActionOverride: { finished.fulfill() },
            accessibilityWorkerOverride: { _ in
                XCTAssertFalse(Thread.isMainThread)
                started.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                return false
            }, frontmostPIDProvider: { 123 }
        )
        injector.inject(text: "result", preserveClipboard: false)
        await fulfillment(of: [started], timeout: 1)
        // This main-actor continuation executes while the worker is blocked.
        gate.signal()
        await fulfillment(of: [finished], timeout: 1)
        await drainInjectionQueue()
    }

    func testFocusChangeBeforePasteRestoresClipboardAndReportsFailure() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        var pid: pid_t = 123
        let cancelled = expectation(description: "focus change reported")
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true,
            accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: { XCTFail("Must not paste into another app") },
            frontmostPIDProvider: { pid }
        )
        injector.onFailure = { _ in cancelled.fulfill() }
        injector.inject(text: "result", preserveClipboard: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { pid = 456 }
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(board.string(forType: .string), "original")
    }

    func testMissingPasteTargetDoesNotPasteAndReportsFailure() async {
        let board = NSPasteboard(name: .init("com.vocamac.tests.\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let cancelled = expectation(description: "missing target reported")
        let injector = TextInjector(
            pasteboard: board, accessibilityTrustedOverride: true,
            accessibilityInjectionOverride: { _ in false },
            pasteActionOverride: { XCTFail("Must not paste without a destination") },
            frontmostPIDProvider: { nil }
        )
        injector.onFailure = { _ in cancelled.fulfill() }
        injector.inject(text: "result", preserveClipboard: true)
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(board.string(forType: .string), "original")
    }
}
