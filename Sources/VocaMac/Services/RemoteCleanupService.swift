// RemoteCleanupService.swift
// VocaMac
//
// Opt-in OpenAI-compatible text inference. Local inference remains the default.

import Combine
import Foundation
import Security

protocol CleanupCredentialStoring {
    func readAPIKey() -> String?
    func saveAPIKey(_ value: String) throws
    func deleteAPIKey() throws
}

struct CleanupCredentialStore: CleanupCredentialStoring {
    private let service = "com.vocamac.app.cleanup-endpoint"
    private let account = "api-key"

    func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func saveAPIKey(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteAPIKey()
            return
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(trimmed.utf8)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var create = base
            create[kSecValueData as String] = data
            let createStatus = SecItemAdd(create as CFDictionary, nil)
            guard createStatus == errSecSuccess else { throw CredentialError(status: createStatus) }
        } else if status != errSecSuccess {
            throw CredentialError(status: status)
        }
    }

    func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError(status: status)
        }
    }

    private struct CredentialError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        }
    }
}

@MainActor
final class RemoteCleanupService: TranscriptCleaning {
    let configuration: CleanupEndpointConfiguration
    private let credentials: CleanupCredentialStoring
    private let session: URLSession
    private let changes = PassthroughSubject<Void, Never>()
    private var transformTask: Task<CleanupAttempt, Never>?

    /// Dictation cleanup holds up the paste, so a slow or unreachable server
    /// must fall back to the raw transcript quickly. Command Mode is an edit
    /// the user is explicitly waiting on and may be long.
    static let cleanupTimeout: TimeInterval = 15
    static let transformTimeout: TimeInterval = 60

    /// Endpoints that just failed to answer. Without this, a server that is
    /// switched off makes every dictation wait out the timeout before pasting.
    /// Command Mode, which the user starts deliberately, always tries.
    private static var unreachableUntil: [URL: Date] = [:]
    static let unreachableBackoff: TimeInterval = 60

    static func resetReachabilityForTesting() { unreachableUntil = [:] }

    init(
        configuration: CleanupEndpointConfiguration,
        credentials: CleanupCredentialStoring = CleanupCredentialStore(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.session = session
    }

    var modelState: CleanupModelState { configuration.validationProblem().map(CleanupModelState.error) ?? .ready }
    var isLoaded: Bool { configuration.validationProblem() == nil }
    nonisolated func inputBudget(forPrompt prompt: String) -> Int { max(0, 64_000 - prompt.count) }
    var objectWillChangePublisher: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

    func clean(_ text: String, prompt: String) async -> String {
        await attempt(text, prompt: prompt).output
    }

    func attempt(_ text: String, prompt: String) async -> CleanupAttempt {
        await request(text, prompt: prompt, allowsTransform: false)
    }

    func preview(_ text: String, prompt: String) async -> CleanupAttempt {
        await request(text, prompt: prompt, allowsTransform: false)
    }

    func transform(_ text: String, prompt: String) async -> CleanupAttempt {
        let task = Task { await request(text, prompt: prompt, allowsTransform: true) }
        transformTask = task
        defer { if transformTask == task { transformTask = nil } }
        return await task.value
    }

    func cancelTransform() {
        transformTask?.cancel()
    }

    func availabilityProblem(for kind: CleanupModelKind) -> String? {
        configuration.validationProblem()
    }

    private func request(_ text: String, prompt: String, allowsTransform: Bool) async -> CleanupAttempt {
        let start = Date()
        func result(_ output: String, _ outcome: CleanupAttempt.Outcome) -> CleanupAttempt {
            CleanupAttempt(output: output, outcome: outcome, duration: Date().timeIntervalSince(start))
        }
        guard let url = configuration.chatCompletionsURL else {
            return result(text, .skipped(configuration.validationProblem() ?? "the endpoint is invalid"))
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return result(text, .skipped("there is nothing to clean")) }
        if !allowsTransform, let until = Self.unreachableUntil[url], until > Date() {
            return result(text, .skipped("the endpoint didn't answer a moment ago; retrying shortly"))
        }

        struct Message: Encodable { let role: String; let content: String }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let stream: Bool
        }
        let body = Body(
            model: configuration.resolvedModel,
            messages: [
                Message(role: "system", content: prompt),
                Message(role: "user", content: TranscriptCleanup.formatInput(trimmed)),
            ],
            temperature: 0,
            stream: false
        )
        var request = URLRequest(
            url: url,
            timeoutInterval: allowsTransform ? Self.transformTimeout : Self.cleanupTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = credentials.readAPIKey(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        do {
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                return result(text, .rejected("endpoint returned HTTP \(status)"))
            }
            struct Response: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable { let content: String? }
                    let message: Message
                }
                let choices: [Choice]
            }
            Self.unreachableUntil[url] = nil
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let raw = decoded.choices.first?.message.content ?? ""
            let accepted = allowsTransform
                ? TranscriptCleanup.acceptedTransformOutput(raw, original: trimmed)
                : TranscriptCleanup.acceptedOutput(raw, original: trimmed)
            guard let accepted else {
                return result(text, .rejected("the rewrite failed the safety check"))
            }
            return result(accepted, accepted == trimmed ? .unchanged : .cleaned)
        } catch let error where Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            return result(text, .skipped("request cancelled"))
        } catch {
            if let code = (error as? URLError)?.code, Self.unreachableCodes.contains(code) {
                Self.unreachableUntil[url] = Date().addingTimeInterval(Self.unreachableBackoff)
            }
            VocaLogger.warning(.transcriptCleanup, "Remote cleanup failed: \(error.localizedDescription)")
            return result(text, .rejected(error.localizedDescription))
        }
    }

    private static let unreachableCodes: Set<URLError.Code> = [
        .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
        .networkConnectionLost, .notConnectedToInternet,
    ]

    func isDownloaded(_ kind: CleanupModelKind) -> Bool { isLoaded }
    func pruneUnknownModels() {}
    func download(_ kind: CleanupModelKind) async {}
    func cancelDownload() {}
    func load(_ kind: CleanupModelKind) async {}
    func unload() {}
    func delete(_ kind: CleanupModelKind) {}
}
