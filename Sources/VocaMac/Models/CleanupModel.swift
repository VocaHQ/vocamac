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

/// What one cleanup pass actually did, for the Settings "try it" panel.
///
/// `clean` deliberately returns the input unchanged whenever anything goes
/// wrong, which is right for dictation and useless for diagnosis — "nothing
/// happened" and "the model answered and the answer was thrown away" look
/// identical. This says which.
struct CleanupAttempt: Equatable {
    enum Outcome: Equatable {
        /// The model rewrote the text and the rewrite was accepted.
        case cleaned
        /// The model answered, and its answer was the input.
        case unchanged
        /// The model answered and the answer failed the safety gate.
        case rejected(String)
        /// Cleanup never ran.
        case skipped(String)
    }

    let output: String
    let outcome: Outcome
    let duration: TimeInterval
    /// The model's answer when the whole-answer check threw it out. Its safe
    /// edits can still be applied one by one (`EditMerge`).
    var rejectedCandidate: String? = nil

    var didChangeText: Bool { outcome == .cleaned }

    var summary: String {
        switch outcome {
        case .cleaned: return "Cleaned up"
        case .unchanged: return "Model returned the text unchanged"
        case .rejected(let why): return "Not usable whole — \(why). Dictation applies its safe edits one by one."
        case .skipped(let why): return "Skipped — \(why)"
        }
    }
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
/// Hybrid attention/recurrent architectures do not belong here — check
/// `general.architecture` in the GGUF header, where `qwen2` (the default
/// below) and `qwen3` are fine and `qwen35` is not. LLM.swift reuses
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
    case qwen25_1_5b_q4_k_m
    case qwen3_4b_instruct_2507_q4_k_m
    case qwen25_7b_q4_k_m

    var id: String { rawValue }

    /// Models listed as dictation cleanup choices. The larger ones are too
    /// slow to run after every dictation and are offered for Command Mode only.
    static let cleanupChoices: [CleanupModelKind] = [
        .qwen25_0_5b_q4_k_m, .qwen3_0_6b_q4_k_m, .qwen25_1_5b_q4_k_m,
    ]

    /// Models strong enough to follow spoken editing instructions.
    static let commandModeChoices: [CleanupModelKind] = [
        .qwen25_1_5b_q4_k_m, .qwen3_4b_instruct_2507_q4_k_m, .qwen25_7b_q4_k_m,
    ]

    static let defaultKind: CleanupModelKind = .qwen25_0_5b_q4_k_m

    static func resolved(stored: String?) -> CleanupModelKind {
        guard let stored, !stored.isEmpty else { return .defaultKind }
        return CleanupModelKind(rawValue: stored) ?? .defaultKind
    }

    var descriptor: CleanupModelDescriptor {
        CleanupModelCatalog.descriptor(for: self)
    }

    var supportsCleanup: Bool { Self.cleanupChoices.contains(self) }
    var supportsCommandMode: Bool { Self.commandModeChoices.contains(self) }
    /// Listed for both features; one download serves both.
    var isShared: Bool { supportsCleanup && supportsCommandMode }
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

    /// Large enough for selected-text commands and translation. This stays
    /// optional because routine cleanup is faster and lighter on the 0.5B model.
    static let quality = CleanupModelDescriptor(
        kind: .qwen25_1_5b_q4_k_m,
        displayName: "Qwen 2.5 1.5B",
        summary: "Handles both cleanup and Command Mode. Slower than 0.5B for cleanup, and the lightest model that follows spoken edits such as shortening, tone changes, and simple translation.",
        sizeDescription: "~1.12 GB",
        fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
        expectedSHA256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
        expectedByteCount: 1_117_320_736,
        maxTokenCount: 8192,
        ramRequiredGB: 2.2,
        recommendation: .quality
    )

    /// Qwen 3 4B Instruct 2507 is the non-thinking release, so every token
    /// goes to the answer. `qwen3` architecture (plain attention), Apache 2.0.
    /// Context is kept at 8K: the KV cache for its 36 layers is ~1.2 GB there.
    static let commandBalanced = CleanupModelDescriptor(
        kind: .qwen3_4b_instruct_2507_q4_k_m,
        displayName: "Qwen 3 4B Instruct",
        summary: "Best Command Mode quality for most Macs. Follows multi-step edits, rewrites, and translation far more reliably than 1.5B. Needs 16 GB of memory to stay comfortable.",
        sizeDescription: "~2.50 GB",
        fileName: "Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF/resolve/a06e946bb6b655725eafa393f4a9745d460374c9/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")!,
        expectedSHA256: "3605803b982cb64aead44f6c1b2ae36e3acdb41d8e46c8a94c6533bc4c67e597",
        expectedByteCount: 2_497_281_120,
        maxTokenCount: 8192,
        ramRequiredGB: 4.0,
        recommendation: .quality
    )

    /// `qwen2` architecture, Apache 2.0. Single-file GGUF (the official Qwen
    /// repository splits the 7B into parts, which the downloader can't join).
    static let commandLarge = CleanupModelDescriptor(
        kind: .qwen25_7b_q4_k_m,
        displayName: "Qwen 2.5 7B Instruct",
        summary: "Largest on-device option, for long selections and nuanced rewrites. Slower — several seconds per paragraph. Needs 16 GB of memory or more.",
        sizeDescription: "~4.68 GB",
        fileName: "Qwen2.5-7B-Instruct-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/8911e8a47f92bac19d6f5c64a2e2095bd2f7d031/Qwen2.5-7B-Instruct-Q4_K_M.gguf")!,
        expectedSHA256: "65b8fcd92af6b4fefa935c625d1ac27ea29dcb6ee14589c55a8f115ceaaa1423",
        expectedByteCount: 4_683_074_240,
        maxTokenCount: 8192,
        ramRequiredGB: 5.6,
        recommendation: .quality
    )

    static let all: [CleanupModelDescriptor] = [recommended, compact, quality, commandBalanced, commandLarge]

    static func descriptor(for kind: CleanupModelKind) -> CleanupModelDescriptor {
        all.first { $0.kind == kind } ?? recommended
    }

    /// File names the catalog owns, so a model dropped from the catalog (or
    /// left behind by an older build) can be cleared off disk.
    static var knownFileNames: Set<String> {
        Set(all.map(\.fileName))
    }
}
