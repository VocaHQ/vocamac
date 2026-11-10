// AXCast.swift
// VocaMac
//
// Type-checked casts for values that come back from Accessibility calls.

import ApplicationServices

/// Turns a `CFTypeRef` from an Accessibility call into the CF type the
/// caller expects, or nil.
///
/// Other apps' Accessibility implementations can return nil or an
/// unexpected CF type even when the call reports success, and Swift cannot
/// check a CoreFoundation cast at run time (`as?` always succeeds). Each
/// helper compares the CF type ID first, so the bit cast that follows is
/// only ever applied to a value of that type.
enum AXCast {
    /// The value as an `AXUIElement`, or nil when it is anything else.
    static func element(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    /// The value as an `AXValue`, or nil when it is anything else.
    static func value(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(ref, to: AXValue.self)
    }

    /// The `CGPoint`, `CGSize`, `CFRange` or other payload of an `AXValue`
    /// of the given type, or nil when the value is missing, of another CF
    /// type, or holds a different payload.
    static func payload<T>(_ ref: CFTypeRef?, as type: AXValueType, default initial: T) -> T? {
        guard let value = value(ref) else { return nil }
        var result = initial
        let read = withUnsafeMutablePointer(to: &result) { AXValueGetValue(value, type, $0) }
        return read ? result : nil
    }
}
