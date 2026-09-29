// LidStateReader.swift
// VocaMac

import Foundation
import IOKit

enum LidStateReader {
    /// Current clamshell state from the power-management root domain. Desktops
    /// and unavailable registry values safely report open.
    static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? Bool else { return false }
        return value
    }
}
