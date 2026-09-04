// SystemInfo.swift
// VocaMac
//
// Detects system hardware capabilities and recommends optimal whisper model size.

import Darwin
import Foundation

// MARK: - SystemCapabilities

/// Detected system hardware information
struct SystemCapabilities {
    let isAppleSilicon: Bool
    let physicalMemoryGB: Int
    let processorName: String
    let coreCount: Int
    let supportsMetalAcceleration: Bool
    let recommendedModel: ModelSize

    /// Human-readable summary for display in settings
    var summaryDescription: String {
        """
        Processor: \(processorName)
        Architecture: \(isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)")
        Memory: \(physicalMemoryGB) GB
        Cores: \(coreCount)
        Metal: \(supportsMetalAcceleration ? "Supported" : "Not Available")
        Recommended Model: \(recommendedModel.displayName)
        """
    }
}

// MARK: - SystemInfo

/// Utility class for detecting system hardware capabilities
enum SystemInfo {

    /// Detect all system capabilities and return a summary
    static func detect() -> SystemCapabilities {
        let appleSilicon = isAppleSilicon
        let memoryGB = physicalMemoryGB
        let processor = processorName
        let cores = coreCount
        let metal = appleSilicon // Metal acceleration is available on Apple Silicon

        let recommended = recommendModel(
            isAppleSilicon: appleSilicon,
            memoryGB: memoryGB
        )

        return SystemCapabilities(
            isAppleSilicon: appleSilicon,
            physicalMemoryGB: memoryGB,
            processorName: processor,
            coreCount: cores,
            supportsMetalAcceleration: metal,
            recommendedModel: recommended
        )
    }

    // MARK: - Hardware Detection

    /// Whether the system is running on Apple Silicon (ARM64)
    static var isAppleSilicon: Bool {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { ptr in
            ptr.compactMap { byte -> Character? in
                guard byte > 0 else { return nil }
                return Character(UnicodeScalar(byte))
            }
            .map(String.init)
            .joined()
        }
        return machine.contains("arm64")
    }

    /// Physical memory in gigabytes
    static var physicalMemoryGB: Int {
        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        return Int(memoryBytes / (1024 * 1024 * 1024))
    }

    /// Processor brand string (e.g., "Apple M1 Pro", "Intel Core i9-9880H")
    static var processorName: String {
        var size: Int = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)

        guard size > 0 else { return "Unknown" }

        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)

        return String(cString: brand)
    }

    /// Number of active processor cores
    static var coreCount: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    /// Mac model identifier (e.g., "MacBookPro18,1")
    static var modelIdentifier: String {
        var size: Int = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)

        guard size > 0 else { return "Unknown" }

        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)

        return String(cString: model)
    }

    // MARK: - Model Recommendation

    /// Recommend a default model family based on system capabilities.
    ///
    /// WhisperKit's runtime recommendation remains the source of truth for
    /// actual model loading. This fallback is used for static system summaries.
    static func recommendModel(isAppleSilicon: Bool, memoryGB: Int) -> ModelSize {
        if isAppleSilicon {
            switch memoryGB {
            case ...7:   return .tiny
            case 8...15: return .base
            case 16...23: return .small
            case 24...31: return .largeV3LatestTurboCompact
            case 32...:  return .largeV3Latest
            default:     return .tiny
            }
        } else {
            // Intel Macs: no Metal acceleration, less memory-efficient
            switch memoryGB {
            case ...7:   return .tiny
            case 8...15: return .tiny
            case 16...23: return .base
            case 24...31: return .small
            case 32...:  return .small
            default:     return .tiny
            }
        }
    }

    /// Number of threads to use for whisper.cpp inference
    /// Uses a reasonable fraction of available cores to avoid monopolizing the CPU
    static var recommendedThreadCount: Int {
        let cores = coreCount
        // Use at most half the cores, minimum 2, maximum 8
        return max(2, min(cores / 2, 8))
    }

    /// Bytes this process can still allocate. Zero means the value is unknown.
    static var availableMemoryBytes: UInt64 {
        os_proc_available_memory()
    }

    /// Whether loading `size` is likely to fit without thrashing.
    ///
    /// Uses the catalog RAM estimate against installed memory and against
    /// `os_proc_available_memory()`. A zero available reading is treated as
    /// unknown so we do not block loads on a failed probe.
    static func canFitModelInMemory(
        _ size: ModelSize,
        physicalMemoryGB: Int = physicalMemoryGB,
        availableBytes: UInt64 = availableMemoryBytes
    ) -> Bool {
        let requiredGB = size.ramRequiredGB
        guard Double(physicalMemoryGB) + 0.001 >= requiredGB else {
            return false
        }
        guard availableBytes > 0 else { return true }
        let requiredBytes = UInt64((requiredGB * 1024 * 1024 * 1024).rounded(.up))
        return availableBytes >= requiredBytes
    }
}
