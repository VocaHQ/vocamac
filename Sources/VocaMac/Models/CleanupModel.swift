// CleanupModel.swift
// VocaMac
//
// Catalog of on-device GGUF models used for optional transcript cleanup.

import Foundation

/// Runtime status of the selected cleanup model.
enum CleanupModelState: Equatable {
    case idle
    case downloading(kind: CleanupModelKind, progress: Double)
    case loading(kind: CleanupModelKind)
    case ready
    case error(String)
}

/// How a cleanup model is positioned in the picker.
enum CleanupModelRecommendation: Equatable {
    case compact
    case recommended
    case quality

    var badge: String {
        switch self {
        case .compact: return "Compact"
        case .recommended: return "Recommended"
        case .quality: return "Higher quality"
        }
    }
}

/// Identifiers persisted in `PreferenceKey.transcriptCleanupModel`.
enum CleanupModelKind: String, CaseIterable, Identifiable, Codable {
    case qwen3_0_6b_q4_k_m
    case qwen35_0_8b_q4_k_m
    case qwen35_2b_q4_k_m

    var id: String { rawValue }

    static let defaultKind: CleanupModelKind = .qwen35_0_8b_q4_k_m

    static func resolved(stored: String?) -> CleanupModelKind {
        guard let stored, !stored.isEmpty else { return .defaultKind }
        return CleanupModelKind(rawValue: stored) ?? .defaultKind
    }

    var descriptor: CleanupModelDescriptor {
        CleanupModelCatalog.descriptor(for: self)
    }
}

/// One downloadable GGUF used for post-transcription cleanup.
struct CleanupModelDescriptor: Equatable {
    let kind: CleanupModelKind
    let displayName: String
    let summary: String
    let sizeDescription: String
    let fileName: String
    let url: URL
    let expectedSHA256: String
    let expectedByteCount: Int64
    let maxTokenCount: Int32
    let ramRequiredGB: Double
    let recommendation: CleanupModelRecommendation
}

/// Sizes are decimal MB/GB to match `expectedByteCount` and what Finder shows
/// for the downloaded file.
enum CleanupModelCatalog {
    static let compact = CleanupModelDescriptor(
        kind: .qwen3_0_6b_q4_k_m,
        displayName: "Qwen 3 0.6B",
        summary: "Smallest download. Good for 8 GB Macs; slightly weaker at self-corrections.",
        sizeDescription: "~397 MB",
        fileName: "Qwen3-0.6B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/50968a4468ef4233ed78cd7c3de230dd1d61a56b/Qwen3-0.6B-Q4_K_M.gguf")!,
        expectedSHA256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a",
        expectedByteCount: 396_705_472,
        maxTokenCount: 4096,
        ramRequiredGB: 0.8,
        recommendation: .compact
    )

    static let recommended = CleanupModelDescriptor(
        kind: .qwen35_0_8b_q4_k_m,
        displayName: "Qwen 3.5 0.8B",
        summary: "Best speed/quality for dictation. Typically 1–2 seconds per utterance.",
        sizeDescription: "~533 MB",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf")!,
        expectedSHA256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        expectedByteCount: 532_517_120,
        maxTokenCount: 4096,
        ramRequiredGB: 1.0,
        recommendation: .recommended
    )

    static let quality = CleanupModelDescriptor(
        kind: .qwen35_2b_q4_k_m,
        displayName: "Qwen 3.5 2B",
        summary: "Stronger instruction following. Slower (about 4–5 seconds) and uses more RAM.",
        sizeDescription: "~1.28 GB",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf")!,
        expectedSHA256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        expectedByteCount: 1_280_835_840,
        maxTokenCount: 4096,
        ramRequiredGB: 1.8,
        recommendation: .quality
    )

    static let all: [CleanupModelDescriptor] = [compact, recommended, quality]

    static func descriptor(for kind: CleanupModelKind) -> CleanupModelDescriptor {
        all.first { $0.kind == kind } ?? recommended
    }
}
