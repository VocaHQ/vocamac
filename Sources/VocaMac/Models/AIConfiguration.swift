// AIConfiguration.swift
// VocaMac
//
// Persisted choices for transcript cleanup and command-mode inference.

import Foundation

/// How aggressively a cleanup pass may change a transcript.
enum CleanupLevel: String, CaseIterable, Codable, Identifiable {
    case none, light, medium, high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .light: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var detail: String {
        switch self {
        case .none: return "Keep the engine transcript unchanged, “um” and “uh” included."
        case .light: return "Tidy punctuation and capitalization only. Keeps “um” and “uh”."
        case .medium: return "Also remove fillers and repeated starts, and keep only the fix when you correct a day, month, number, or time (“tomorrow, no, Wednesday” → “Wednesday”). “Um”, “uh”, and these corrections are handled in every app, even with Smart Cleanup off. In Code and Terminal the model only removes filler, never rewords."
        case .high: return "Also let the model resolve looser corrections (“send it to John, no, Mary” → “Mary”) and drop what you cancel with “scratch that”."
        }
    }

    /// Whether "um" and "uh" are removed without the model. None and Light
    /// promise to keep every spoken sound.
    var removesHesitations: Bool {
        self == .medium || self == .high
    }

    func prompt(custom: String) -> String {
        let base = custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? TranscriptCleanup.defaultPrompt
            : custom
        let rule: String
        switch self {
        case .none:
            return base
        case .light:
            rule = "Apply light cleanup only: punctuation and sentence capitalization. Keep every spoken word, including fillers, repetitions, and corrections."
        case .medium:
            rule = "Apply medium cleanup: punctuation, sentence capitalization, fillers, and obvious repeated false starts. Preserve all facts and wording."
        case .high:
            rule = "Apply high cleanup: punctuation, fillers, false starts, and explicit self-corrections. When the speaker says ‘actually’, ‘rather’, or ‘I mean’, keep the corrected value."
        }
        return base + "\n\nCleanup level for this request: \(rule)"
    }
}

/// Where optional text inference runs. Local remains the default.
enum CleanupProvider: String, CaseIterable, Codable, Identifiable {
    case local
    case ollama
    case lmStudio
    case openAICompatible

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "On this Mac"
        case .ollama: return "Ollama"
        case .lmStudio: return "LM Studio"
        case .openAICompatible: return "OpenAI-compatible"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .local: return ""
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        case .openAICompatible: return "https://api.openai.com/v1"
        }
    }

    var defaultModel: String {
        switch self {
        case .local: return ""
        case .ollama: return "qwen2.5:3b"
        case .lmStudio: return "local-model"
        case .openAICompatible: return "gpt-4.1-mini"
        }
    }
}

/// What runs Command Mode's selected-text edits. Chosen separately from
/// dictation cleanup: edits need a larger model than the one that tidies every
/// dictation, and Command Mode should work with cleanup turned off.
enum CommandModeEngine: Hashable, Identifiable {
    /// Apple's on-device model (macOS 26 with Apple Intelligence on).
    case appleIntelligence
    /// The Ollama / LM Studio / OpenAI-compatible endpoint set for cleanup.
    case endpoint
    /// A downloaded GGUF model run with llama.cpp.
    case local(CleanupModelKind)

    static let defaultLocalModel: CleanupModelKind = .qwen25_1_5b_q4_k_m

    var id: String { storageValue }

    var storageValue: String {
        switch self {
        case .appleIntelligence: return "appleIntelligence"
        case .endpoint: return "endpoint"
        case .local(let kind): return kind.rawValue
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "appleIntelligence": self = .appleIntelligence
        case "endpoint": self = .endpoint
        default:
            guard let kind = CleanupModelKind(rawValue: storageValue),
                  CleanupModelKind.commandModeChoices.contains(kind) else { return nil }
            self = .local(kind)
        }
    }

    var displayName: String {
        switch self {
        case .appleIntelligence: return "Apple Intelligence"
        case .endpoint: return "Cleanup endpoint"
        case .local(let kind): return kind.descriptor.displayName
        }
    }

    /// An explicit choice wins, except an endpoint that has since been
    /// switched off. Apple Intelligence stays chosen while it is briefly
    /// unavailable (its model can be mid-update), so the error names it
    /// rather than silently switching models. With nothing stored, prefer what
    /// needs no download: a configured endpoint, then Apple Intelligence, then
    /// the smallest capable local model.
    static func resolve(
        stored: String,
        endpointIsConfigured: Bool,
        appleIntelligenceAvailable: Bool
    ) -> CommandModeEngine {
        if let explicit = CommandModeEngine(storageValue: stored),
           explicit != .endpoint || endpointIsConfigured {
            return explicit
        }
        if endpointIsConfigured { return .endpoint }
        if appleIntelligenceAvailable { return .appleIntelligence }
        return .local(defaultLocalModel)
    }
}

/// Non-secret endpoint settings. API keys live in Keychain and are never exported.
struct CleanupEndpointConfiguration: Codable, Equatable {
    var provider: CleanupProvider = .local
    var baseURL: String = ""
    var model: String = ""

    var resolvedBaseURL: String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultBaseURL : trimmed
    }

    var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    var isLocal: Bool { provider == .local }

    func validationProblem() -> String? {
        guard !isLocal else { return nil }
        guard let url = URL(string: resolvedBaseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return "Enter an HTTP or HTTPS endpoint."
        }
        // Plain HTTP would put the transcript and API key on the wire in the
        // clear, and App Transport Security blocks it for public hosts anyway.
        guard scheme == "https" || Self.isLocalNetworkHost(url.host) else {
            return "Use HTTPS for servers outside this Mac or your local network."
        }
        guard !resolvedModel.isEmpty else { return "Enter a model name." }
        return nil
    }

    /// This Mac, a `.local` name, a bare host name, or a private IPv4 address —
    /// the hosts `NSAllowsLocalNetworking` lets through without TLS.
    static func isLocalNetworkHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else { return false }
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        return !host.contains(".") && !host.contains(":")
    }

    var chatCompletionsURL: URL? {
        guard validationProblem() == nil else { return nil }
        let base = resolvedBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: base + "/chat/completions")
    }

    static func decode(_ json: String?) -> CleanupEndpointConfiguration {
        guard let data = json?.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }
}

/// A browser-specific writing rule. The app binding remains the fallback.
struct WebsiteStyleBinding: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var hostPattern: String
    var displayName: String
    var style: WritingStyle
    var intent: WritingIntent = .preserve
    var cleanup: WritingCleanupPolicy = .inherit
    var cleanupLevel: CleanupLevel? = nil
    var cleanupPrompt: String? = nil
    var isEnabled = true

    func matches(_ url: URL) -> Bool {
        guard isEnabled, let host = url.host?.lowercased() else { return false }
        let pattern = hostPattern.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !pattern.isEmpty else { return false }
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix("." + suffix)
        }
        return host == pattern || host.hasSuffix("." + pattern)
    }
}

struct WebsiteStyleBindingStore: Codable {
    var schemaVersion = 1
    var bindings: [WebsiteStyleBinding] = []

    static func decode(_ json: String?) -> [WebsiteStyleBinding] {
        guard let data = json?.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion <= 1 else { return [] }
        return value.bindings
    }

    static func encode(_ bindings: [WebsiteStyleBinding]) -> String {
        guard let data = try? JSONEncoder().encode(Self(bindings: bindings)),
              let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }
}
