// AudioDeviceMatch.swift
// VocaMac
//
// Finds the connected microphone a saved selection refers to when its Core
// Audio UID has changed. A USB mic with no serial number gets a UID built from
// the port it is plugged into (`AppleUSBAudioEngine:<maker>:<product>:<location>:<n>`),
// so moving it to another port, hub or dock gives it a new UID. Matching only
// by UID made VocaMac treat the chosen mic as missing and record from the
// built-in one.

import Foundation

/// Matches a saved microphone selection against the devices connected now.
enum AudioDeviceMatch {
    private static let usbUIDPrefix = "AppleUSBAudioEngine:"

    /// The connected device a saved selection means, or nil when none fits.
    ///
    /// Order: the exact UID; for a USB device, the one connected USB device
    /// whose UID differs only in its port or serial part; for anything else,
    /// the one device with the saved name. A USB mic is never matched by name
    /// alone: cheap ones share generic names ("USB PnP Audio Device") across
    /// makers. When two devices could be meant, nothing is chosen.
    static func device(
        forSavedID savedID: String,
        savedName: String,
        among devices: [AudioDevice]
    ) -> AudioDevice? {
        guard !savedID.isEmpty else { return nil }
        if let exact = devices.first(where: { $0.id == savedID }) {
            return exact
        }

        if let savedKey = portIndependentKey(forUID: savedID) {
            let sameProduct = devices.filter { portIndependentKey(forUID: $0.id) == savedKey }
            return sameProduct.count == 1 ? sameProduct[0] : nil
        }

        let name = savedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let sameName = devices.filter { $0.name == name }
        return sameName.count == 1 ? sameName[0] : nil
    }

    /// A USB audio UID without its port-location (or serial) part, so the same
    /// product keeps one key across ports. Nil for other kinds of device.
    static func portIndependentKey(forUID uid: String) -> String? {
        guard uid.hasPrefix(usbUIDPrefix) else { return nil }
        var parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        // prefix, maker, product, location-or-serial, stream index
        guard parts.count >= 5 else { return nil }
        parts.remove(at: parts.count - 2)
        return parts.joined(separator: ":")
    }
}
