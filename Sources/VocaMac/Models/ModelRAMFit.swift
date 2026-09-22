// ModelRAMFit.swift
// VocaMac
//
// Measured lines for a speech model's peak memory against its size on disk.

import Foundation

// MARK: - ModelRAMFit

/// A measured line for a model's peak memory against its size on disk:
/// peak GB ≈ `baseGB` + `gbPerFileGB` × file size in GB.
///
/// Models in one engine share a line, so a new model needs only its real
/// `fileSizeBytes`. Measured with `scripts/measure-model-ram.sh` (headless
/// CLI, 100 s and 10 min of speech) on an M1 Pro, 16 GB, macOS 27, on
/// 2026-09-23; each line sits on or above every measured model. The points
/// are in `ModelRAMEstimateTests`.
///
/// Much of a CoreML model's memory is not in the app's own footprint:
/// - Loaded weights live in wired memory the kernel holds for the Neural
///   Engine: about 1.5 × the file for Small, 1.1 × for Parakeet v2.
/// - A first load compiles out of process, in ANECompilerService. For
///   palettized Whisper builds that compile peaks at about 3.7 × the file
///   (Voca Hinglish: 3.1 GB), because the compiler expands the weights.
///   Other CoreML models peak below their loaded size while compiling.
struct ModelRAMFit: Equatable {
    let baseGB: Double
    let gbPerFileGB: Double

    /// Peak GB for a model of `fileSizeBytes`, plus 25% for other chips and
    /// macOS versions, rounded up to the next 0.5 GB.
    func estimateGB(fileSizeBytes: Int64) -> Double {
        let fileGB = Double(fileSizeBytes) / 1_000_000_000
        let peakGB = baseGB + gbPerFileGB * fileGB
        return max(0.5, (peakGB * 1.25 * 2).rounded(.up) / 2)
    }

    // MARK: - Fits

    /// Every load after the first, from CoreML's compile cache. `nil` for
    /// Apple Speech, which runs in system processes and has no model file.
    static func loaded(for size: ModelSize) -> ModelRAMFit? {
        switch size.engine {
        case .whisperKit:  return size.hasPalettizedWeights ? whisperPalettizedLoaded : whisperLoaded
        case .parakeet:    return parakeetLoaded
        case .sherpaOnnx:  return sherpaOnnx
        case .appleSpeech: return nil
        }
    }

    /// The first load on a macOS build, while CoreML compiles the model for
    /// the Neural Engine, where that needs more than later loads. `nil`
    /// otherwise: the compile of other CoreML models peaks below their loaded
    /// size, and sherpa-onnx runs ONNX Runtime on the CPU.
    static func firstLoad(for size: ModelSize) -> ModelRAMFit? {
        guard size.engine == .whisperKit, size.hasPalettizedWeights else { return nil }
        return whisperPalettizedFirstLoad
    }

    /// App footprint up to 0.2 GB plus the weights in wired memory
    /// (Small: 0.71 GB wired for a 0.49 GB file).
    static let whisperLoaded = ModelRAMFit(baseGB: 0.2, gbPerFileGB: 1.5)

    /// As `whisperLoaded`, but allowing for the weights to sit expanded to
    /// 16-bit in wired memory, twice an 8-bit file. Not measured directly.
    static let whisperPalettizedLoaded = ModelRAMFit(baseGB: 0.2, gbPerFileGB: 2.0)

    /// Compile peak: Voca Hinglish 3.06 GB (0.36 app + 2.70 compiler) for an
    /// 0.82 GB file; Large v3 Turbo Compact 2.10 GB for 0.65 GB.
    static let whisperPalettizedFirstLoad = ModelRAMFit(baseGB: 0, gbPerFileGB: 3.715)

    /// App footprint up to 0.15 GB plus the weights in wired memory
    /// (Parakeet v2: 0.49 GB wired for a 0.46 GB file).
    static let parakeetLoaded = ModelRAMFit(baseGB: 0.15, gbPerFileGB: 1.1)

    /// ONNX Runtime copies the weights into the app's own memory and grows
    /// with clip length: Qwen3 ASR 2.49 GB for a 1.0 GB model over 10 min,
    /// Canary 0.80 GB for 0.21 GB.
    static let sherpaOnnx = ModelRAMFit(baseGB: 0.3, gbPerFileGB: 2.4)
}
