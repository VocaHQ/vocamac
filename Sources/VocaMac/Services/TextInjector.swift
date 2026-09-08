// TextInjector.swift
// VocaMac
//
// Injects transcribed text at the cursor position in any application
// using the clipboard (NSPasteboard) + simulated Cmd+V keystroke approach.

import Foundation
import AppKit
import Carbon.HIToolbox

final class TextInjector {

    // MARK: - Constants

    /// Delay after simulating Cmd+V before restoring the clipboard.
    ///
    /// The posted key event is delivered asynchronously to the target app.
    /// A 50 ms delay occasionally restored the old clipboard before a busy
    /// target application had consumed the paste event, causing Cmd+V to
    /// paste the user's old clipboard instead of the transcription.
    private let clipboardRestoreDelay: Double = 0.15

    /// Delay before simulating the Cmd+V keystroke, giving the
    /// pasteboard a moment to settle after we write to it.
    private let prePasteDelay: Double = 0.05

    /// Default virtual key code for the V key on a US-QWERTY layout.
    /// Used as a fallback when the active layout cannot be inspected.
    private let kVK_ANSI_V_Fallback: CGKeyCode = 9

    // MARK: - Types

    /// Deep copy of a single pasteboard item's data across all its types
    private struct PasteboardItemSnapshot {
        /// Map from pasteboard type to raw data
        let dataByType: [(NSPasteboard.PasteboardType, Data)]
    }

    /// Deep copy of the entire pasteboard state
    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    /// A clipboard-backed injection waiting to be processed.
    private struct ClipboardInjectionRequest {
        let text: String
        let preserveClipboard: Bool
        let targetPID: pid_t?
    }

    /// A process-wide serial queue for the system pasteboard. TextInjector is
    /// normally a singleton, but sharing this coordinator also prevents
    /// separate instances from racing over the same pasteboard.
    private final class ClipboardInjectionCoordinator {
        typealias Operation = (@escaping () -> Void) -> Void

        private var pendingOperations: [Operation] = []
        private var isRunning = false

        func enqueue(_ operation: @escaping Operation) {
            pendingOperations.append(operation)
            processNextIfNeeded()
        }

        private func processNextIfNeeded() {
            guard !isRunning, !pendingOperations.isEmpty else { return }

            isRunning = true
            let operation = pendingOperations.removeFirst()
            operation { [self] in
                isRunning = false
                processNextIfNeeded()
            }
        }
    }

    // MARK: - Dependencies and Queue State

    /// The pasteboard used for clipboard fallback. Production always uses the
    /// system pasteboard; injection lets tests exercise timing logic without
    /// depending on Accessibility permission or a focused text field.
    private let pasteboard: NSPasteboard

    /// Optional test seams. Production leaves these nil and uses the real
    /// Accessibility and CGEvent implementations.
    private let accessibilityTrustedOverride: Bool?
    private let accessibilityInjectionOverride: ((String) -> Bool)?
    private let pasteActionOverride: (() -> Void)?
    private let accessibilityWorkerOverride: (@Sendable (String) -> Bool)?
    private let frontmostPIDProvider: () -> pid_t?
    var onFailure: ((String) -> Void)?

    /// Clipboard fallback injections must run one at a time. Otherwise a
    /// delayed restore from one injection can replace the transcription from
    /// a newer injection immediately before its Cmd+V event is handled.
    private static let clipboardInjectionCoordinator = ClipboardInjectionCoordinator()

    // MARK: - Initialization

    /// Create a text injector.
    ///
    /// The optional parameters are internal test seams. They do not alter
    /// production behavior, where the general pasteboard, Accessibility API,
    /// and CGEvent paste simulation are used.
    init(
        pasteboard: NSPasteboard = .general,
        accessibilityTrustedOverride: Bool? = nil,
        accessibilityInjectionOverride: ((String) -> Bool)? = nil,
        pasteActionOverride: (() -> Void)? = nil,
        accessibilityWorkerOverride: (@Sendable (String) -> Bool)? = nil,
        frontmostPIDProvider: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    ) {
        self.pasteboard = pasteboard
        self.accessibilityTrustedOverride = accessibilityTrustedOverride
        self.accessibilityInjectionOverride = accessibilityInjectionOverride
        self.pasteActionOverride = pasteActionOverride
        self.accessibilityWorkerOverride = accessibilityWorkerOverride
        self.frontmostPIDProvider = frontmostPIDProvider
    }

    // MARK: - Public API

    /// Inject text at the current cursor position in any application.
    ///
    /// Strategy (in order):
    /// 1. **Accessibility API** — sets `kAXSelectedTextAttribute` on the
    ///    focused element. This inserts text directly without going through
    ///    any paste handler, which makes it compatible with apps like Raycast
    ///    whose search bar intercepts Cmd+V before it reaches the text field.
    /// 2. **Clipboard + Cmd+V** — the legacy approach used as a fallback for
    ///    apps whose text fields are not writable via the Accessibility API.
    ///
    /// - Parameters:
    ///   - text: The text to inject
    ///   - preserveClipboard: Whether to save and restore the clipboard contents
    ///                        (only relevant when the clipboard path is taken)
    func inject(text: String, preserveClipboard: Bool = true) {
        guard !text.isEmpty else { return }

        let enqueue = { [self] in
            let targetPID = frontmostPIDProvider()
            let interval = PerformanceTrace.begin("TextDeliveryQueueAndDispatch")
            Self.clipboardInjectionCoordinator.enqueue { [self] finish in
                let complete = {
                    PerformanceTrace.end(interval)
                    finish()
                }
                performInjection(text: text, preserveClipboard: preserveClipboard,
                                 targetPID: targetPID, completion: complete)
            }
        }
        if Thread.isMainThread { enqueue() }
        else { DispatchQueue.main.async(execute: enqueue) }
    }

    private enum AccessibilityInsertion { case inserted, unavailable, uncertain }

    private static let accessibilityQueue = DispatchQueue(label: "com.vocamac.text-accessibility", qos: .userInitiated)

    /// Clipboard operations remain on main; only cross-process AX work runs on the worker.
    private func performInjection(text: String, preserveClipboard: Bool, targetPID: pid_t?, completion: @escaping () -> Void) {
        let trusted = accessibilityTrustedOverride ?? AXIsProcessTrusted()
        guard trusted else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            completion()
            return
        }
        // No destination app: skip AX and never post Cmd+V into nowhere.
        guard targetPID != nil else {
            reportMissingPasteTarget()
            completion()
            return
        }
        let deliverFallback = { [self] (result: AccessibilityInsertion) in
            if result == .inserted {
                PerformanceTrace.event("AccessibilityTextInserted")
                completion()
            } else if result == .uncertain {
                onFailure?("The target app did not confirm text insertion. Check the field before retrying; your transcript is available in VocaMac.")
                completion()
            } else {
                let currentPID = frontmostPIDProvider()
                if samePasteTarget(targetPID, currentPID) {
                    processClipboardInjection(
                        ClipboardInjectionRequest(text: text, preserveClipboard: preserveClipboard, targetPID: targetPID),
                        completion: completion
                    )
                } else {
                    // Focus changed or the destination app disappeared. Do not paste.
                    reportPasteTargetMismatch(queued: targetPID, current: currentPID)
                    completion()
                }
            }
        }
        if let accessibilityInjectionOverride {
            deliverFallback(accessibilityInjectionOverride(text) ? .inserted : .unavailable)
            return
        }
        Self.accessibilityQueue.async { [self] in
            let interval = PerformanceTrace.begin("TextAccessibilityQueryAndWrite")
            let inserted = accessibilityWorkerOverride.map { $0(text) ? AccessibilityInsertion.inserted : .unavailable }
                ?? injectViaAccessibility(text: text, targetPID: targetPID)
            PerformanceTrace.end(interval)
            DispatchQueue.main.async { deliverFallback(inserted) }
        }
    }

    // MARK: - Strategy 1: Accessibility API

    /// Attempt to insert `text` at the cursor position by writing directly to
    /// the `kAXSelectedTextAttribute` of the currently focused UI element.
    ///
    /// This replaces any active selection with `text`, or inserts at the caret
    /// when no text is selected — identical to what the user would experience
    /// when typing.
    ///
    /// **Scope:** This strategy is intentionally limited to single-line input
    /// roles (`AXTextField`, `AXSearchField`, `AXComboBox`). Multi-line
    /// `AXTextArea` elements — which covers terminal emulators (Terminal.app,
    /// Ghostty, iTerm2) and code editors — accept the AX attribute write and
    /// return `.success`, but silently discard or mishandle the text because
    /// those views process input as a stream of key events, not as a direct
    /// value mutation. Limiting scope to single-line fields makes AX injection
    /// reliable for apps like Raycast while letting terminal/editor traffic
    /// fall through to the clipboard+Cmd+V path that has always worked there.
    ///
    /// - Returns: `true` if the text was successfully written via the AX API;
    ///            `false` if the focused element is unreachable, has an
    ///            unsupported role, or the write was rejected.
    @discardableResult
    private func injectViaAccessibility(text: String, targetPID: pid_t?) -> AccessibilityInsertion {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var focusedRef: CFTypeRef?

        let fetchResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard fetchResult == .success, let focusedRef else {
            VocaLogger.debug(.textInjector, "AX: no focused element (\(fetchResult.rawValue))")
            return .unavailable
        }

        // The returned CFTypeRef must be an AXUIElement.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            VocaLogger.debug(.textInjector, "AX: focused element is not an AXUIElement")
            return .unavailable
        }

        // swiftlint:disable force_cast
        let element = focusedRef as! AXUIElement
        var elementPID: pid_t = 0
        guard AXUIElementGetPid(element, &elementPID) == .success,
              elementPID == targetPID else { return .unavailable }
        AXUIElementSetMessagingTimeout(element, 0.1)
        // swiftlint:enable force_cast

        // Gate on element role. Only single-line input fields reliably handle
        // a direct kAXSelectedTextAttribute write as "insert text at cursor".
        // AXTextArea (terminals, editors) must use clipboard+Cmd+V instead.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        let supportedRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]
        guard supportedRoles.contains(role) else {
            VocaLogger.debug(.textInjector, "AX: skipping role '\(role)' — not a single-line input field")
            return .unavailable
        }

        // A timed-out write may still be applied by the target. It must never
        // trigger an automatic second insertion via Cmd+V.
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if setResult == .success {
            VocaLogger.debug(.textInjector, "AX: inserted \(text.count) chars via kAXSelectedTextAttribute (role: \(role))")
            return .inserted
        }

        VocaLogger.debug(.textInjector, "AX: kAXSelectedTextAttribute write failed (\(setResult.rawValue)) — element may be read-only")
        return setResult == .cannotComplete ? .uncertain : .unavailable
    }

    // MARK: - Strategy 2: Clipboard + Cmd+V

    /// Process one clipboard injection. The coordinator starts the next
    /// operation only after `completion` is called.
    private func processClipboardInjection(
        _ request: ClipboardInjectionRequest,
        completion: @escaping () -> Void
    ) {
        Task { @MainActor [self] in
            let interval = PerformanceTrace.begin("TextInjectionToPaste")
            defer { PerformanceTrace.end(interval); completion() }
            do {
                let currentPID = frontmostPIDProvider()
                guard samePasteTarget(request.targetPID, currentPID) else {
                    reportPasteTargetMismatch(queued: request.targetPID, current: currentPID)
                    return
                }
                var snapshot = request.preserveClipboard ? try await captureStableSnapshot(pasteboard) : nil
                guard writeTranscribedText(request.text, to: pasteboard) else { return }
                var expectedChangeCount = pasteboard.changeCount
                try await Task.sleep(nanoseconds: UInt64(prePasteDelay * 1_000_000_000))
                if pasteboard.changeCount != expectedChangeCount {
                    snapshot = request.preserveClipboard ? try await captureStableSnapshot(pasteboard) : nil
                    guard writeTranscribedText(request.text, to: pasteboard) else { return }
                    expectedChangeCount = pasteboard.changeCount
                }
                let pidBeforePaste = frontmostPIDProvider()
                guard samePasteTarget(request.targetPID, pidBeforePaste) else {
                    if request.preserveClipboard, pasteboard.changeCount == expectedChangeCount {
                        if let snapshot { restoreSnapshot(snapshot, to: pasteboard) }
                        else { pasteboard.clearContents() }
                    }
                    reportPasteTargetMismatch(queued: request.targetPID, current: pidBeforePaste)
                    return
                }
                simulatePaste()
                PerformanceTrace.event("PasteEventPosted")
                // Keep the clipboard stable until the target has consumed the event.
                try await Task.sleep(nanoseconds: UInt64(clipboardRestoreDelay * 1_000_000_000))
                if request.preserveClipboard, pasteboard.changeCount == expectedChangeCount {
                    if let snapshot { restoreSnapshot(snapshot, to: pasteboard) }
                    else { pasteboard.clearContents() }
                }
            } catch {
                VocaLogger.warning(.textInjector, "Clipboard changed repeatedly while being preserved; insertion abandoned")
                onFailure?("The clipboard kept changing, so text was not pasted. Your transcript is available in VocaMac.")
            }
        }
    }

    /// Both PIDs must be known and equal. `nil == nil` is not a valid paste target.
    private func samePasteTarget(_ queued: pid_t?, _ current: pid_t?) -> Bool {
        guard let queued, let current else { return false }
        return queued == current
    }

    private func reportPasteTargetMismatch(queued: pid_t?, current: pid_t?) {
        if queued == nil || current == nil {
            reportMissingPasteTarget()
        } else {
            reportFocusChange()
        }
    }

    private func reportMissingPasteTarget() {
        VocaLogger.warning(.textInjector, "No active app to paste into; paste cancelled")
        onFailure?("There was no active app to paste into. Your transcript is available in VocaMac.")
    }

    private func reportFocusChange() {
        VocaLogger.warning(.textInjector, "Focus changed during text insertion; paste cancelled")
        onFailure?("The active app changed before text could be pasted. Your transcript is available in VocaMac.")
    }

    private enum SnapshotError: Error { case changed }

    /// A yield lets other apps or clipboard managers write. Never combine types
    /// from different clipboard generations, or clear an entry we did not preserve.
    @MainActor
    private func captureStableSnapshot(_ pasteboard: NSPasteboard) async throws -> PasteboardSnapshot? {
        for _ in 0..<3 {
            do { return try await captureSnapshot(pasteboard) }
            catch SnapshotError.changed { continue }
        }
        throw SnapshotError.changed
    }

    /// Write one transcription to the pasteboard and report whether the text
    /// write succeeded.
    @discardableResult
    private func writeTranscribedText(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        let didSetText = pasteboard.setString(text, forType: .string)
        VocaLogger.debug(.textInjector, "Set clipboard: '\(String(text.prefix(80)))'")
        return didSetText
    }

    // MARK: - Clipboard Snapshot Management

    /// Deep-copy every item and type from the pasteboard into plain `Data` values.
    /// This must be called *before* `clearContents()` because NSPasteboardItem
    /// objects are invalidated when the pasteboard changes.
    @MainActor
    private func captureSnapshot(_ pasteboard: NSPasteboard) async throws -> PasteboardSnapshot? {
        let interval = PerformanceTrace.begin("ClipboardSnapshot")
        defer { PerformanceTrace.end(interval) }
        var totalBytes = 0
        defer { VocaLogger.debug(.textInjector, "Clipboard snapshot bytes: \(totalBytes)") }
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return nil
        }

        let generation = pasteboard.changeCount
        var itemSnapshots: [PasteboardItemSnapshot] = []
        var sliceStart = ProcessInfo.processInfo.systemUptime
        var representations = 0

        for item in pasteboardItems {
            var dataByType: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard pasteboard.changeCount == generation else { throw SnapshotError.changed }
                if let data = item.data(forType: type) {
                    totalBytes += data.count
                    dataByType.append((type, data))
                }
                representations += 1
                if representations % 8 == 0 || ProcessInfo.processInfo.systemUptime - sliceStart >= 0.004 {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.main.async { continuation.resume() }
                    }
                    guard pasteboard.changeCount == generation else { throw SnapshotError.changed }
                    sliceStart = ProcessInfo.processInfo.systemUptime
                }
            }
            if !dataByType.isEmpty {
                itemSnapshots.append(PasteboardItemSnapshot(dataByType: dataByType))
            }
        }

        guard pasteboard.changeCount == generation else { throw SnapshotError.changed }
        guard !itemSnapshots.isEmpty else { return nil }
        return PasteboardSnapshot(items: itemSnapshots)
    }

    /// Write a previously captured snapshot back to the pasteboard.
    private func restoreSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        var newItems: [NSPasteboardItem] = []
        for itemSnapshot in snapshot.items {
            let newItem = NSPasteboardItem()
            for (type, data) in itemSnapshot.dataByType {
                newItem.setData(data, forType: type)
            }
            newItems.append(newItem)
        }

        pasteboard.writeObjects(newItems)
        VocaLogger.debug(.textInjector, "Restored clipboard with \(newItems.count) items")
    }

    // MARK: - Paste Simulation

    /// Simulate Cmd+V keystroke to paste from clipboard.
    ///
    /// On non-QWERTY layouts (e.g. Dvorak, Colemak, AZERTY), the hardware
    /// virtual keycode for "V" on a US-QWERTY keyboard (9) maps to a
    /// different character. Posting `kVK_ANSI_V` directly therefore triggers
    /// the wrong shortcut — for example, on Dvorak keycode 9 produces ".",
    /// so the system fires Cmd+. (which most apps interpret as "cancel")
    /// instead of Cmd+V (paste). See GitHub issue #123.
    ///
    /// To fix this, we resolve the keycode that produces the character "v"
    /// on the *currently active* keyboard layout and post that keycode
    /// instead. If the active layout cannot be inspected (e.g. in tests
    /// with no input source available) we fall back to the QWERTY keycode.
    private func simulatePaste() {
        if let pasteActionOverride {
            pasteActionOverride()
            return
        }

        let keyCode = TextInjector.keyCode(forCharacter: "v") ?? kVK_ANSI_V_Fallback
        VocaLogger.debug(.textInjector, "Resolved keycode for 'v' on active layout: \(keyCode)")

        let source = CGEventSource(stateID: .combinedSessionState)

        // Cmd+V key down
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create key down event")
            return
        }
        keyDown.flags = [.maskCommand]
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        // Cmd+V key up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create key up event")
            return
        }
        keyUp.flags = [.maskCommand]
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        VocaLogger.info(.textInjector, "Cmd+V posted (keycode \(keyCode))")
    }

    // MARK: - Keyboard Layout Resolution

    /// Find the virtual keycode that produces the given character on the
    /// currently active keyboard layout.
    ///
    /// This walks all keycodes in the standard ANSI range (0...127) and
    /// translates each one through the active Unicode key layout using
    /// `UCKeyTranslate`, returning the first keycode whose unmodified
    /// output matches the requested character.
    ///
    /// - Parameter character: The character to look up (e.g. "v")
    /// - Returns: The virtual keycode that produces the character on the
    ///            active layout, or `nil` if the character is unreachable
    ///            or the input source cannot be inspected.
    static func keyCode(forCharacter character: Character) -> CGKeyCode? {
        // Prefer the active ASCII-capable input source; this skips over
        // non-Latin layouts like Hiragana where "v" is not directly
        // typable, and falls back to the underlying ASCII layout that
        // macOS uses for shortcut interpretation.
        let inputSource: TISInputSource? = {
            if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                return asciiSource
            }
            return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }()

        guard let source = inputSource else { return nil }

        guard let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        let target = String(character)

        return layoutData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let keyboardLayout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)

            var deadKeyState: UInt32 = 0
            let maxStringLength = 4
            var actualStringLength = 0
            var unicodeString = [UniChar](repeating: 0, count: maxStringLength)

            for keyCode in 0..<128 {
                deadKeyState = 0
                let status = UCKeyTranslate(
                    keyboardLayout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0, // no modifiers — match the bare key
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    maxStringLength,
                    &actualStringLength,
                    &unicodeString
                )

                guard status == noErr, actualStringLength > 0 else { continue }

                let produced = String(utf16CodeUnits: unicodeString, count: actualStringLength)
                if produced == target {
                    return CGKeyCode(keyCode)
                }
            }

            return nil
        }
    }
}

// MARK: - TextInjecting Conformance

extension TextInjector: TextInjecting {}
