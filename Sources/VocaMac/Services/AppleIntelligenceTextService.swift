// AppleIntelligenceTextService.swift
// VocaMac
//
// Runs Command Mode edits on Apple's on-device foundation model (macOS 26+).
// Nothing to download, and like the GGUF models it never leaves the Mac.

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
final class AppleIntelligenceTextService: TextTransforming {

    /// Why Apple Intelligence can't run edits right now, or nil when it can.
    nonisolated static func availabilityProblem() -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This Mac doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in System Settings → Apple Intelligence & Siri."
            case .unavailable(.modelNotReady):
                return "Apple Intelligence is still downloading its model. Try again later."
            case .unavailable:
                return "Apple Intelligence is unavailable right now."
            }
        }
        #endif
        return "Apple Intelligence needs macOS 26 or later."
    }

    nonisolated static var isAvailable: Bool { availabilityProblem() == nil }

    private var task: Task<CleanupAttempt, Never>?

    func transform(_ text: String, prompt: String) async -> CleanupAttempt {
        let started = Date()
        func result(_ output: String, _ outcome: CleanupAttempt.Outcome) -> CleanupAttempt {
            CleanupAttempt(output: output, outcome: outcome, duration: Date().timeIntervalSince(started))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result(text, .skipped("there is nothing to edit")) }
        if let problem = Self.availabilityProblem() {
            return result(text, .skipped(problem))
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let input = TranscriptCleanup.formatInput(trimmed)
            let running = Task { () -> CleanupAttempt in
                do {
                    // Permissive transformations: the request is to rewrite the
                    // user's own text, which the default guardrails often refuse
                    // for ordinary content such as an angry email.
                    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                    let session = LanguageModelSession(model: model, instructions: prompt)
                    let response = try await session.respond(
                        to: input,
                        options: GenerationOptions(temperature: 0.2)
                    )
                    guard let accepted = TranscriptCleanup.acceptedTransformOutput(
                        response.content, original: trimmed
                    ) else {
                        return result(text, .rejected("the rewrite failed the safety check"))
                    }
                    return result(accepted, accepted == trimmed ? .unchanged : .cleaned)
                } catch is CancellationError {
                    return result(text, .skipped("the edit was cancelled"))
                } catch let error as LanguageModelSession.GenerationError {
                    return result(text, .rejected(Self.describe(error)))
                } catch {
                    return result(text, .rejected(error.localizedDescription))
                }
            }
            task = running
            defer { task = nil }
            return await running.value
        }
        #endif
        return result(text, .skipped("Apple Intelligence needs macOS 26 or later"))
    }

    func cancelTransform() {
        task?.cancel()
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "the selection is too long for Apple Intelligence — select less text or choose a local model"
        case .guardrailViolation, .refusal:
            return "Apple Intelligence declined to edit this text"
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence doesn't support this language yet"
        case .assetsUnavailable:
            return "Apple Intelligence is still preparing its model"
        case .rateLimited, .concurrentRequests:
            return "Apple Intelligence is busy — try again in a moment"
        default:
            return error.localizedDescription
        }
    }
    #endif
}
