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

    /// Approximate reclaimable memory in bytes. Zero means the probe failed.
    ///
    /// The larger of two readings: free + inactive pages, and the kernel's
    /// available-memory level (`kern.memorystatus_level`, the percentage
    /// `memory_pressure` prints) less a reserve. That level counts active,
    /// inactive, free and speculative pages: everything neither wired nor
    /// held by the compressor. Free + inactive alone stays low on a busy Mac,
    /// where clean file cache and idle app memory sit in the active queue: a
    /// 16 GB Mac at 39% read 3.0 GB and refused a 3.4 GB Command Mode model it
    /// had run minutes earlier, every time. The level falls as wired and
    /// compressed memory grow, so the gate still refuses on a full machine.
    static var availableMemoryBytes: UInt64 {
        reclaimableBytes(
            freeAndInactiveBytes: freeAndInactiveBytes,
            memoryStatusLevel: memoryStatusLevel,
            physicalBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    /// Share of RAM the kernel-level reading leaves untouched, so a load that
    /// fits still does not compress the rest of the machine down to nothing.
    static let memoryStatusReservePercent = 10

    /// Combine the two probes. A missing kernel level falls back to free +
    /// inactive alone, so zero still means neither probe worked.
    static func reclaimableBytes(
        freeAndInactiveBytes: UInt64,
        memoryStatusLevel: Int?,
        physicalBytes: UInt64
    ) -> UInt64 {
        guard let level = memoryStatusLevel, (0...100).contains(level) else {
            return freeAndInactiveBytes
        }
        let usablePercent = UInt64(max(0, level - memoryStatusReservePercent))
        let kernelBytes = physicalBytes / 100 * usablePercent
        // At least one byte: a machine the kernel reports as full is a known
        // reading, and zero would read as "unknown" and wave the load through.
        return max(freeAndInactiveBytes, kernelBytes, 1)
    }

    /// Free + inactive pages from host_statistics64, or zero if the probe fails.
    ///
    /// `free_count` already includes speculative pages, purgeable pages often
    /// overlap the inactive queue, and compressor-resident pages still occupy
    /// RAM — so those counters must not be added on top.
    private static var freeAndInactiveBytes: UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return 0 }
        let pages = UInt64(stats.free_count)
            + UInt64(stats.inactive_count)
        return pages * UInt64(pageSize)
    }

    /// The kernel's available-memory percentage, or nil if it cannot be read.
    private static var memoryStatusLevel: Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(level)
    }

    /// Whether loading `size` is likely to fit without thrashing.
    ///
    /// Uses the catalog RAM estimate against installed memory and against
    /// reclaimable free memory from host_statistics64. A zero available
    /// reading is treated as unknown so we do not block loads on a failed probe.
    ///
    /// - Parameter isFirstLoad: Whether this load compiles the model for the
    ///   Neural Engine (see `CompiledModelRecord`), which needs far more
    ///   memory than a load from CoreML's cache.
    /// - Parameter freeingGB: RAM the pending load will release before it
    ///   allocates, because it unloads the model currently resident. Without
    ///   this the outgoing model counts against the incoming one, which
    ///   rejected perfectly possible switches away from a large engine.
    static func canFitModelInMemory(
        _ size: ModelSize,
        isFirstLoad: Bool = false,
        freeingGB: Double = 0,
        physicalMemoryGB: Int = physicalMemoryGB,
        availableBytes: UInt64 = availableMemoryBytes
    ) -> Bool {
        canFitInMemory(
            requiredGB: isFirstLoad ? size.firstLoadRAMRequiredGB : size.ramRequiredGB,
            freeingGB: freeingGB,
            physicalMemoryGB: physicalMemoryGB,
            availableBytes: availableBytes
        )
    }

    /// Same gate against a bare catalog estimate, for models that are not
    /// `ModelSize` values (the GGUF cleanup catalog).
    static func canFitInMemory(
        requiredGB: Double,
        freeingGB: Double = 0,
        physicalMemoryGB: Int = physicalMemoryGB,
        availableBytes: UInt64 = availableMemoryBytes
    ) -> Bool {
        guard Double(physicalMemoryGB) + 0.001 >= requiredGB else {
            return false
        }
        guard availableBytes > 0 else { return true }
        let requiredBytes = UInt64((requiredGB * 1024 * 1024 * 1024).rounded(.up))
        let reclaimedBytes = UInt64(max(0, freeingGB) * 1024 * 1024 * 1024)
        let (sum, overflowed) = availableBytes.addingReportingOverflow(reclaimedBytes)
        return overflowed || sum >= requiredBytes
    }
}
