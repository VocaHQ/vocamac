// CompiledModelRecord.swift
// VocaMac
//
// Remembers which speech models have already loaded on this macOS build.

import Foundation

// MARK: - CompiledModelRecord

/// Which models have loaded at least once on the current macOS build.
///
/// The first load of a CoreML model compiles it for the Neural Engine, and
/// for palettized Whisper builds that compile needs far more memory than
/// later loads (Large v3 Turbo Compact: 2.1 GB while compiling, most of it
/// in the Neural Engine compiler). CoreML caches the result and
/// recompiles after a macOS update, so the memory gate asks this record
/// whether the coming load will compile, keyed by OS build.
struct CompiledModelRecord {
    private let defaults: UserDefaults
    private let osBuild: String

    init(
        defaults: UserDefaults = .standard,
        osBuild: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.defaults = defaults
        self.osBuild = osBuild
    }

    /// Whether `size` has loaded before on this macOS build.
    func hasLoaded(_ size: ModelSize) -> Bool {
        builds[size.rawValue] == osBuild
    }

    /// Record a successful load of `size`.
    func recordLoad(_ size: ModelSize) {
        var updated = builds
        updated[size.rawValue] = osBuild
        defaults.set(updated, forKey: PreferenceKey.compiledModelBuilds)
    }

    /// Forget `size`, for when its files are deleted and a fresh copy may
    /// compile again.
    func forget(_ size: ModelSize) {
        var updated = builds
        updated[size.rawValue] = nil
        defaults.set(updated, forKey: PreferenceKey.compiledModelBuilds)
    }

    private var builds: [String: String] {
        defaults.dictionary(forKey: PreferenceKey.compiledModelBuilds) as? [String: String] ?? [:]
    }
}
