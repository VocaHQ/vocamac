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
        case .none: return "Keep the engine transcript unchanged."
        case .light: return "Tidy punctuation and capitalization only."
        case .medium: return "Also remove fillers and repeated starts."
        case .high: return "Also resolve explicit spoken corrections such as ‘actually 3’."
        }
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
        guard !resolvedModel.isEmpty else { return "Enter a model name." }
        return nil
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
