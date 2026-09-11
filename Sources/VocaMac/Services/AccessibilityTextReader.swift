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
}

extension ScreenContextReading {
    func captureFrontmostDocumentURL() async -> URL? { nil }
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
