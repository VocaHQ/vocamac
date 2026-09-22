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
///
/// Each model has its own key, so the app and the headless CLI can record
/// different models at the same time without one write discarding the other.
///
/// The record only knows what loaded, not what CoreML still has cached. When
/// the compile cache is gone (macOS purges Caches when the disk fills, and
/// cleanup apps delete it), every model counts as a first load again.
struct CompiledModelRecord {
    private let defaults: UserDefaults
    private let osBuild: String
    private let compileCacheExists: () -> Bool

    init(
        defaults: UserDefaults = .standard,
        osBuild: String = CompiledModelRecord.currentOSBuild,
        compileCacheExists: @escaping () -> Bool = CompiledModelRecord.appCompileCacheExists
    ) {
        self.defaults = defaults
        self.osBuild = osBuild
        self.compileCacheExists = compileCacheExists
    }

    /// Whether `size` has loaded before on this macOS build and CoreML's
    /// compile cache is still there.
    func hasLoaded(_ size: ModelSize) -> Bool {
        defaults.string(forKey: key(for: size)) == osBuild && compileCacheExists()
    }

    /// Record a successful load of `size`.
    func recordLoad(_ size: ModelSize) {
        defaults.set(osBuild, forKey: key(for: size))
    }

    /// Forget `size`, for when its files are deleted and a fresh copy may
    /// compile again.
    func forget(_ size: ModelSize) {
        defaults.removeObject(forKey: key(for: size))
    }

    private func key(for size: ModelSize) -> String {
        PreferenceKey.compiledModelBuildPrefix + size.rawValue
    }

    // MARK: - System

    /// The macOS build, such as "26A428", which changes with every update,
    /// including security updates. Falls back to the display version string.
    static var currentOSBuild: String {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        var buffer = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &buffer, &length, nil, 0) == 0 else {
            return ProcessInfo.processInfo.operatingSystemVersionString
        }
        return String(cString: buffer)
    }

    /// Whether this app's CoreML compile cache holds anything. CoreML keeps
    /// it under the app's own Caches folder, keyed by bundle identifier.
    static func appCompileCacheExists() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else {
            return false
        }
        let cache = caches
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("com.apple.e5rt.e5bundlecache", isDirectory: true)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: cache.path)
        return !(contents ?? []).isEmpty
    }
}
