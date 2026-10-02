// AccessibilityTextReader.swift
// VocaMac
//
// Reads text from another app's focused field through the Accessibility API,
// for on-screen spelling context and for learning from corrections. Every
// call has a short timeout and runs off the main thread, and nothing read
// here is stored or sent anywhere.

import AppKit
import ApplicationServices
import Foundation
import os

/// An `AXUIElement` handed between the main actor and the AX worker queue.
/// AX elements are thread-safe CF objects; the box only tells Swift so.
struct AXElementBox: @unchecked Sendable {
    let element: AXUIElement
}

/// The focused text field of an app and what it contained.
struct FocusedTextSnapshot: @unchecked Sendable {
    let element: AXElementBox
    let processID: pid_t
    let value: String
    /// Caret position (UTF-16 offset) when the snapshot was taken.
    let caretLocation: Int?
}

/// What marks the field some text was in, apart from the text itself: where
/// the field is on screen, and what was written just before and after.
///
/// The same words at the same offset can sit in two fields of one app (two
/// drafts of a reply, the same line in two documents). Before text an edit
/// left behind is selected again, to edit it further or to take the edit
/// back, the field has to be shown to be the one the edit was made in.
struct FieldAnchor: Equatable, Sendable {
    /// Characters of surrounding text kept on each side (UTF-16 units).
    static let contextLength = 64

    /// The field's frame on screen; nil when the app doesn't report one.
    let frame: CGRect?
    /// The text just before and just after the selection; nil when the
    /// field's text couldn't be read.
    let before: String?
    let after: String?

    init(frame: CGRect?, before: String?, after: String?) {
        self.frame = frame
        self.before = before
        self.after = after
    }

    /// - Parameters:
    ///   - value: The field's whole text, when it can be read.
    ///   - range: The selection, or the caret as an empty range.
    init(frame: CGRect?, value: String?, range: CFRange?) {
        self.frame = frame
        guard let value, let range else {
            before = nil
            after = nil
            return
        }
        let text = value as NSString
        let start = min(max(range.location, 0), text.length)
        let end = min(max(range.location + range.length, start), text.length)
        let lead = min(Self.contextLength, start)
        before = text.substring(with: NSRange(location: start - lead, length: lead))
        after = text.substring(with: NSRange(location: end, length: min(Self.contextLength, text.length - end)))
    }

    /// Whether a field with this `frame` and `value` is the anchored one,
    /// holding at `location` a run of `length` with the same text on either
    /// side. A field with no known frame can't be told from another, so it
    /// never matches.
    ///
    /// The field may have changed height since: a message box grows and
    /// shrinks with its text, and the edit changed the text. It keeps its
    /// left edge and width, and either its top edge or its bottom one,
    /// depending on which way it grows.
    func matches(frame current: CGRect?, value: String?, location: Int, length: Int) -> Bool {
        guard let frame, let current,
              abs(frame.minX - current.minX) <= 1, abs(frame.width - current.width) <= 1,
              abs(frame.minY - current.minY) <= 1 || abs(frame.maxY - current.maxY) <= 1 else {
            return false
        }
        // Nothing was known about the surroundings; the frame is all there is.
        guard let before, let after else { return true }
        guard let value, location >= 0, length >= 0 else { return false }
        let text = value as NSString
        guard location + length <= text.length else { return false }
        return text.substring(to: location).hasSuffix(before)
            && text.substring(from: location + length).hasPrefix(after)
    }
}

/// Where the cursor sat in a text field, with enough about the field to tell
/// later whether that is still where text would go.
///
/// Elements can't be compared for this: SwiftUI and web views hand out a
/// fresh one for the same field on every query. The field's place on screen,
/// its text, and the caret position can.
struct InsertionPoint: Equatable, Sendable {
    let processID: pid_t
    /// Caret position as a UTF-16 offset into the field.
    let caret: Int
    /// The field's text; nil when it has none or is too long to read.
    let fieldValue: String?
    /// The field's frame on screen; nil when the app doesn't report one.
    let fieldFrame: CGRect?

    /// Whether `current` is the same place: the same app and field, with the
    /// cursor where it was and nothing typed since. A focus change to another
    /// field, a click elsewhere in this one, or any edit makes it a
    /// different place.
    func matches(_ current: InsertionPoint?) -> Bool {
        guard let current, current.processID == processID, current.caret == caret,
              current.fieldValue == fieldValue else { return false }
        switch (fieldFrame, current.fieldFrame) {
        case let (old?, new?):
            return abs(old.minX - new.minX) <= 1 && abs(old.minY - new.minY) <= 1
                && abs(old.width - new.width) <= 1 && abs(old.height - new.height) <= 1
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    /// The empty selection at this point, for selecting text typed here again.
    var snapshot: SelectedTextSnapshot {
        let range = CFRange(location: caret, length: 0)
        return SelectedTextSnapshot(
            element: nil, processID: processID, text: "", range: range,
            anchor: FieldAnchor(frame: fieldFrame, value: fieldValue, range: range)
        )
    }
}

enum AccessibilityTextReader {

    /// Longest field value read in full. Beyond this only the text around
    /// the caret is used for context, and corrections aren't tracked.
    static let maximumValueLength = 50_000

    static let queue = DispatchQueue(label: "com.vocamac.accessibility-text", qos: .userInitiated)

    private static let timeout: Float = 0.15

    /// The focused element of the app with `processID`, if it is a readable,
    /// non-secure text element.
    static func focusedTextElement(processID: pid_t) -> AXUIElement? {
        guard AXIsProcessTrusted(), processID != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let focused = copyElement(app, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(focused, timeout)

        let role = copyString(focused, kAXRoleAttribute) ?? ""
        let subrole = copyString(focused, kAXSubroleAttribute) ?? ""
        // Never read a password field, even to look at it.
        if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        return focused
    }

    /// The element's full text value, or `nil` when it has none or it is
    /// longer than `maximumValueLength`.
    static func value(of element: AXUIElement) -> String? {
        guard let value = copyString(element, kAXValueAttribute),
              value.utf16.count <= maximumValueLength else { return nil }
        return value
    }

    static func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(ref as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func caretLocation(of element: AXUIElement) -> Int? {
        guard let range = selectedTextRange(of: element) else { return nil }
        return range.location + range.length
    }

    static func selectedText(of element: AXUIElement) -> String? {
        copyString(element, kAXSelectedTextAttribute)
    }

    /// The cursor in the focused text field of `processID`, or nil when the
    /// app doesn't expose one.
    static func insertionPoint(processID: pid_t) -> InsertionPoint? {
        guard let element = focusedTextElement(processID: processID),
              let caret = caretLocation(of: element) else { return nil }
        return InsertionPoint(
            processID: processID, caret: caret, fieldValue: value(of: element), fieldFrame: frame(of: element)
        )
    }

    /// What marks the field `element` is, around a selection at `range`.
    static func fieldAnchor(of element: AXUIElement, range: CFRange?) -> FieldAnchor {
        FieldAnchor(frame: frame(of: element), value: value(of: element), range: range)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef,
              CFGetTypeID(positionRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        // swiftlint:enable force_cast
        return CGRect(origin: position, size: size)
    }

    // MARK: - Selection (Command Mode)

    /// What Accessibility can say about the current selection.
    enum SelectionProbe: @unchecked Sendable {
        case selected(element: AXElementBox, processID: pid_t, text: String, range: CFRange?)
        /// A text element is focused and reports that nothing is selected.
        case empty
        case secure
        /// Selected text in content that can't be edited, such as a web page.
        case readOnly(element: AXElementBox, processID: pid_t, text: String, range: CFRange?)
        /// No focused text element, or one that doesn't expose its selection.
        case unavailable
    }

    /// Command Mode waits on this read, so a slow Electron app gets longer
    /// than the background context reads do.
    private static let selectionTimeout: Float = 0.5

    /// Read the selection of whatever has keyboard focus. The system-wide
    /// focused element comes first: it finds fields in out-of-process panels
    /// (Open/Save, Spotlight-style UI) that the frontmost app's own
    /// `AXFocusedUIElement` doesn't report.
    static func probeSelection(frontmostPID: pid_t) -> SelectionProbe {
        guard AXIsProcessTrusted() else { return .unavailable }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var candidates: [(AXUIElement, pid_t)] = []
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, selectionTimeout)
        if let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) {
            var owner: pid_t = 0
            if AXUIElementGetPid(focused, &owner) == .success, owner != ownPID {
                candidates.append((focused, owner))
            }
        }
        if frontmostPID != ownPID {
            let app = AXUIElementCreateApplication(frontmostPID)
            AXUIElementSetMessagingTimeout(app, selectionTimeout)
            if let focused = copyElement(app, kAXFocusedUIElementAttribute),
               !candidates.contains(where: { CFEqual($0.0, focused) }) {
                candidates.append((focused, frontmostPID))
            }
        }

        var sawEmptySelection = false
        for (element, owner) in candidates {
            AXUIElementSetMessagingTimeout(element, selectionTimeout)
            let role = copyString(element, kAXRoleAttribute) ?? ""
            let subrole = copyString(element, kAXSubroleAttribute) ?? ""
            if role == "AXSecureTextField" || subrole == (kAXSecureTextFieldSubrole as String) {
                return .secure
            }
            let text = copyString(element, kAXSelectedTextAttribute)
            let range = selectedTextRange(of: element)
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard isEditable(element, role: role) else {
                    return .readOnly(element: AXElementBox(element: element), processID: owner, text: text, range: range)
                }
                return .selected(element: AXElementBox(element: element), processID: owner, text: text, range: range)
            }
            // The element answered and has no selection. Keep looking — the
            // other candidate may be the real field — but never fall back to
            // a Cmd+C, which some editors turn into "copy the whole line".
            if text != nil || range?.length == 0 { sawEmptySelection = true }
        }
        return sawEmptySelection ? .empty : .unavailable
    }

    /// Select `expected` where it sits at `location` in the focused text
    /// element, so an edit just made can be edited again. Does nothing unless
    /// the field holds exactly that text there, and is the field `anchor`
    /// marks: a range alone could select whatever has been typed since, and
    /// the text alone could be the same words in another field.
    static func selectText(_ expected: String, at location: Int, in anchor: FieldAnchor, frontmostPID: pid_t) -> Bool {
        guard AXIsProcessTrusted(), location >= 0, !expected.isEmpty else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var candidates: [AXUIElement] = []
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, selectionTimeout)
        if let focused = copyElement(systemWide, kAXFocusedUIElementAttribute) {
            var owner: pid_t = 0
            if AXUIElementGetPid(focused, &owner) == .success, owner != ownPID { candidates.append(focused) }
        }
        if frontmostPID != ownPID, let focused = focusedTextElement(processID: frontmostPID),
           !candidates.contains(where: { CFEqual($0, focused) }) {
            candidates.append(focused)
        }
        let length = expected.utf16.count
        for element in candidates {
            AXUIElementSetMessagingTimeout(element, selectionTimeout)
            let role = copyString(element, kAXRoleAttribute) ?? ""
            let subrole = copyString(element, kAXSubroleAttribute) ?? ""
            guard role != "AXSecureTextField", subrole != (kAXSecureTextFieldSubrole as String),
                  let value = value(of: element) else { continue }
            let text = value as NSString
            guard location + length <= text.length,
                  text.substring(with: NSRange(location: location, length: length)) == expected,
                  anchor.matches(frame: frame(of: element), value: value, location: location, length: length) else {
                continue
            }
            var range = CFRange(location: location, length: length)
            guard let axRange = AXValueCreate(.cfRange, &range),
                  AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
                continue
            }
            return true
        }
        return false
    }

    /// Text roles are editable when focused; other roles (web areas, static
    /// text) only when they say their value can be written.
    private static func isEditable(_ element: AXUIElement, role: String) -> Bool {
        let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if editableRoles.contains(role) { return true }
        for attribute in [kAXSelectedTextAttribute, kAXValueAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
               settable.boolValue {
                return true
            }
        }
        return false
    }

    // MARK: - Electron

    private static let manualAccessibilityPIDs = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    /// Code editors built on Electron switch into a screen-reader mode when an
    /// assistive client turns their tree on, which changes how they render
    /// and behave. They copy selections reliably, so leave them alone.
    private static let manualAccessibilityExclusions: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss",
        "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
    ]

    /// Whether `app` is an Electron app whose Accessibility tree can be turned
    /// on with `AXManualAccessibility`.
    @MainActor
    static func shouldRequestManualAccessibility(for app: NSRunningApplication) -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        if let identifier = app.bundleIdentifier, manualAccessibilityExclusions.contains(identifier) {
            return false
        }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    /// Ask an Electron app to build its Accessibility tree, the switch
    /// Electron documents for assistive tools. Returns true the first time it
    /// is turned on for this process, when the caller should wait and re-read.
    static func requestManualAccessibility(processID: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let isNew = manualAccessibilityPIDs.withLock { $0.insert(processID).inserted }
        guard isNew else { return false }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, selectionTimeout)
        let status = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        VocaLogger.debug(.textInjector, "AXManualAccessibility for pid \(processID): \(status.rawValue)")
        return status == .success
    }

    /// URL exposed by Safari and Chromium focused web areas through AXURL or
    /// AXDocument. Walk a bounded parent chain because the focused text box is
    /// usually nested below the web area that owns the document attribute.
    static func documentURL(processID: pid_t) -> URL? {
        guard var element = focusedTextElement(processID: processID) else { return nil }
        for _ in 0..<8 {
            if let value = copyURLString(element, kAXURLAttribute)
                ?? copyURLString(element, kAXDocumentAttribute),
               let url = URL(string: value), url.scheme != nil {
                return url
            }
            guard let parent = copyElement(element, kAXParentAttribute) else { break }
            element = parent
        }
        return nil
    }

    /// The text visible in the element, falling back to the text around the
    /// caret, plus the window title. Used only to find names and identifiers.
    static func visibleContext(processID: pid_t) -> String? {
        guard AXIsProcessTrusted(), processID != ProcessInfo.processInfo.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, timeout)

        var parts: [String] = []
        if let window = copyElement(app, kAXFocusedWindowAttribute),
           let title = copyString(window, kAXTitleAttribute), !title.isEmpty {
            parts.append(title)
        }

        if let element = focusedTextElement(processID: processID) {
            if let visible = visibleText(of: element) {
                parts.append(visible)
            } else if let full = copyString(element, kAXValueAttribute) {
                parts.append(textAroundCaret(full, caret: caretLocation(of: element)))
            }
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    // MARK: - Private

    private static func visibleText(of element: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        var textRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, rangeRef, &textRef
        ) == .success, let text = textRef as? String, !text.isEmpty else { return nil }
        return String(text.prefix(20_000))
    }

    private static func textAroundCaret(_ text: String, caret: Int?) -> String {
        let limit = 20_000
        let utf16 = text.utf16
        guard utf16.count > limit else { return text }
        let center = min(max(caret ?? utf16.count, 0), utf16.count)
        let lower = max(0, center - limit / 2)
        let upper = min(utf16.count, lower + limit)
        let start = utf16.index(utf16.startIndex, offsetBy: lower)
        let end = utf16.index(utf16.startIndex, offsetBy: upper)
        return String(text[start..<end])
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        // swiftlint:disable:next force_cast
        return (ref as! AXUIElement)
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func copyURLString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        if let value = ref as? String { return value }
        if let value = ref as? URL { return value.absoluteString }
        return nil
    }
}

// MARK: - Screen Context

/// Reads spelling context from the app the user is dictating into.
@MainActor
protocol ScreenContextReading: AnyObject {
    /// Visible text of the frontmost app's focused field and window title.
    func captureFrontmostContext() async -> String?
    func captureFrontmostDocumentURL() async -> URL?
    /// The page address in `app`'s focused field, whether or not it is in front.
    func captureDocumentURL(of app: RunningAppSnapshot) async -> URL?
}

extension ScreenContextReading {
    func captureFrontmostDocumentURL() async -> URL? { nil }
    func captureDocumentURL(of app: RunningAppSnapshot) async -> URL? { nil }
}

@MainActor
final class ScreenContextReader: ScreenContextReading {
    func captureFrontmostContext() async -> String? {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.visibleContext(processID: processID))
            }
        }
    }

    func captureFrontmostDocumentURL() async -> URL? {
        guard let processID = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.documentURL(processID: processID))
            }
        }
    }

    func captureDocumentURL(of app: RunningAppSnapshot) async -> URL? {
        guard let bundleIdentifier = app.bundleIdentifier,
              let processID = NSRunningApplication
                .runningApplications(withBundleIdentifier: bundleIdentifier).first?.processIdentifier
        else { return nil }
        return await withCheckedContinuation { continuation in
            AccessibilityTextReader.queue.async {
                continuation.resume(returning: AccessibilityTextReader.documentURL(processID: processID))
            }
        }
    }
}

// MARK: - Spelling

/// Whether a word is ordinary vocabulary, using the system spell checker.
/// Results are cached: the same few hundred words come up again and again.
@MainActor
final class SpellingOracle {
    static let shared = SpellingOracle()

    private var cache: [String: Bool] = [:]

    /// `language` is an ISO code such as "en". Outside English every word is
    /// treated as known, which turns off single-word fuzzy corrections rather
    /// than trusting a checker for the wrong language.
    func isKnownWord(_ word: String, language: String?) -> Bool {
        if let language, !language.lowercased().hasPrefix("en") { return true }
        let key = word.lowercased()
        if let cached = cache[key] { return cached }
        let checker = NSSpellChecker.shared
        let misspelled = checker.checkSpelling(
            of: key, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        let known = misspelled.location == NSNotFound
        if cache.count > 5_000 { cache.removeAll() }
        cache[key] = known
        return known
    }
}
