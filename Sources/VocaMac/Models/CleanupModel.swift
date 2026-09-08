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
///
/// Only plain-attention (`qwen3`) architectures belong here. LLM.swift reuses
/// the llama.cpp KV cache across calls — `LLMCore.prepareContext` keeps the
/// shared prefix and drops the rest with `llama_memory_seq_rm` — and that path
/// is wrong for the hybrid attention/recurrent models (`qwen35`). In testing,
/// Qwen 3.5 0.8B answered the first utterance and then returned empty output
/// for the next seven, so cleanup silently stopped happening after the first
/// dictation; `LLM.reset()`, the obvious remedy, aborts the process inside
/// `llama_memory_recurrent::find_slot`. See `TranscriptCleanupService`.
enum CleanupModelKind: String, CaseIterable, Identifiable, Codable {
    case qwen25_0_5b_q4_k_m
    case qwen3_0_6b_q4_k_m

    var id: String { rawValue }

    static let defaultKind: CleanupModelKind = .qwen25_0_5b_q4_k_m

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
    /// Measured against Qwen 3 0.6B, five runs per behaviour through the real
    /// service. Both remove fillers and stutters, echo questions instead of
    /// answering them, and leave other languages alone (5/5 each). Only this
    /// one turns dictated "comma" and "period" into marks (5/5 vs 0/5) and
    /// capitalises the first letter (5/5 vs 0/5). Neither acts on "scratch
    /// that" (0/5 both) — the prompt still asks for it in case a future model
    /// obliges, but do not advertise it. Qwen 3 0.6B punctuates long
    /// paragraphs slightly better and is 95 MB smaller, which is why it stays.
    static let recommended = CleanupModelDescriptor(
        kind: .qwen25_0_5b_q4_k_m,
        displayName: "Qwen 2.5 0.5B",
        summary: "Best all-round. Drops fillers and stutters, writes dictated “comma” and “period” as marks, and capitalises sentences. About 0.2 seconds.",
        sizeDescription: "~491 MB",
        fileName: "qwen2.5-0.5b-instruct-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/9217f5db79a29953eb74d5343926648285ec7e67/qwen2.5-0.5b-instruct-q4_k_m.gguf")!,
        expectedSHA256: "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db",
        expectedByteCount: 491_400_032,
        maxTokenCount: 4096,
        ramRequiredGB: 0.9,
        recommendation: .recommended
    )

    static let compact = CleanupModelDescriptor(
        kind: .qwen3_0_6b_q4_k_m,
        displayName: "Qwen 3 0.6B",
        summary: "Smallest download. Drops fillers and stutters, but leaves dictated “comma” and “period” as words and does not capitalise sentences.",
        sizeDescription: "~397 MB",
        fileName: "Qwen3-0.6B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/50968a4468ef4233ed78cd7c3de230dd1d61a56b/Qwen3-0.6B-Q4_K_M.gguf")!,
        expectedSHA256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a",
        expectedByteCount: 396_705_472,
        maxTokenCount: 4096,
        ramRequiredGB: 0.8,
        recommendation: .compact
    )

    static let all: [CleanupModelDescriptor] = [recommended, compact]

    static func descriptor(for kind: CleanupModelKind) -> CleanupModelDescriptor {
        all.first { $0.kind == kind } ?? recommended
    }

    /// File names the catalog owns, so a model dropped from the catalog (or
    /// left behind by an older build) can be cleared off disk.
    static var knownFileNames: Set<String> {
        Set(all.map(\.fileName))
    }
}
