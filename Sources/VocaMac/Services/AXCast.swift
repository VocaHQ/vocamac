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

    /// The point an `AXValue` of type `.cgPoint` holds, or nil.
    static func point(_ ref: CFTypeRef?) -> CGPoint? {
        var point = CGPoint.zero
        return read(ref, .cgPoint, into: &point) ? point : nil
    }

    /// The size an `AXValue` of type `.cgSize` holds, or nil.
    static func size(_ ref: CFTypeRef?) -> CGSize? {
        var size = CGSize.zero
        return read(ref, .cgSize, into: &size) ? size : nil
    }

    /// The range an `AXValue` of type `.cfRange` holds, or nil.
    static func range(_ ref: CFTypeRef?) -> CFRange? {
        var range = CFRange()
        return read(ref, .cfRange, into: &range) ? range : nil
    }

    // Private so each AXValueType is only ever read into its own Swift
    // type: AXValueGetValue writes the payload's size into the pointer.
    private static func read(_ ref: CFTypeRef?, _ type: AXValueType, into storage: UnsafeMutableRawPointer) -> Bool {
        guard let value = value(ref) else { return false }
        return AXValueGetValue(value, type, storage)
    }
}
