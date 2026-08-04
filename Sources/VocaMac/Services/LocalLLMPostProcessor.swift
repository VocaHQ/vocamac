// LocalLLMPostProcessor.swift
// VocaMac
//
// Optional local LLM pass for cleaning up dictated text before insertion.

import Foundation

struct LocalLLMModel: Identifiable, Equatable {
    static let recommendedID = "gemma-3-1b-q4"
    static let customID = "custom-gguf"

    let id: String
    let displayName: String
    let detail: String
    let reference: String?

    static let catalog: [LocalLLMModel] = [
        LocalLLMModel(
            id: "gemma-3-1b-q4",
            displayName: "Gemma 3 1B",
            detail: "Recommended default, 806 MB",
            reference: "ggml-org/gemma-3-1b-it-GGUF:Q4_K_M"
        ),
        LocalLLMModel(
            id: "qwen3-1.7b-q8",
            displayName: "Qwen3 1.7B",
            detail: "Larger option, 1.83 GB",
            reference: "Qwen/Qwen3-1.7B-GGUF:Q8_0"
        ),
        LocalLLMModel(
            id: customID,
            displayName: "Custom GGUF",
            detail: "Use a local model file",
            reference: nil
        ),
    ]

    static func model(for id: String) -> LocalLLMModel {
        catalog.first { $0.id == id } ?? catalog[0]
    }
}

enum TextPostProcessingError: LocalizedError {
    case missingRunnerPath
    case missingModelPath
    case runnerNotExecutable(String)
    case modelNotFound(String)
    case homebrewNotFound
    case processFailed(Int32, String)
    case timedOut
    case emptyOutput
    case invalidResponse(String)
    case unexpectedResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingRunnerPath:
            return "Choose a local LLM runner."
        case .missingModelPath:
            return "Choose a local GGUF model."
        case .runnerNotExecutable(let path):
            return "LLM runner is not executable: \(path)"
        case .modelNotFound(let path):
            return "LLM model was not found: \(path)"
        case .homebrewNotFound:
            return "Homebrew was not found. Install llama.cpp manually."
        case .processFailed(let code, let details):
            return details.isEmpty ? "Local LLM exited with code \(code)." : "Local LLM exited with code \(code): \(details)"
        case .timedOut:
            return "Local LLM timed out."
        case .emptyOutput:
            return "Local LLM returned no text."
        case .invalidResponse(let details):
            return details.isEmpty
                ? "Local LLM returned an invalid response."
                : "Local LLM returned an invalid response: \(details)"
        case .unexpectedResponse(let response):
            return response.isEmpty
                ? "Local LLM returned an unexpected response."
                : "Local LLM returned an unexpected response: \(response)"
        }
    }
}

final class LocalLLMPostProcessor: TextPostProcessing {
    static let defaultRunnerPath = detectedRunnerPath() ?? "/opt/homebrew/bin/llama-server"
    static let defaultInstructions = "You are a transcription cleanup engine. Rewrite the user's dictated transcript as clean final text for immediate pasting. Keep the original meaning and intent. Remove filler words and false starts. Fix punctuation and capitalization. Make only conservative wording changes. Do not summarize, answer, invent subject lines, or add commentary. Return only the final rewritten text."
    static let installURL = URL(string: "https://github.com/ggml-org/llama.cpp")!

    private static let runnerCandidates = [
        "/opt/homebrew/bin/llama-server",
        "/usr/local/bin/llama-server",
    ]

    private static let brewCandidates = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    private let timeout: TimeInterval
    private let prepareTimeout: TimeInterval

    init(timeout: TimeInterval = 60, prepareTimeout: TimeInterval = 600) {
        self.timeout = timeout
        self.prepareTimeout = prepareTimeout
    }

    func prepare(configuration: TextPostProcessingConfiguration) async throws {
        let timeout = prepareTimeout
        let response = try await Task.detached(priority: .userInitiated) {
            try Self.run(
                systemPrompt: "Reply with OK and nothing else.",
                userPrompt: "ping",
                configuration: configuration,
                timeout: timeout,
                maxTokens: 8
            )
        }.value

        let normalized = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .lowercased()
        guard normalized == "ok" else {
            throw TextPostProcessingError.unexpectedResponse(response)
        }
    }

    func improve(_ text: String, configuration: TextPostProcessingConfiguration) async throws -> String {
        let timeout = timeout
        return try await Task.detached(priority: .userInitiated) {
            try Self.run(
                systemPrompt: Self.rewriteSystemPrompt(instructions: configuration.instructions),
                userPrompt: text.trimmingCharacters(in: .whitespacesAndNewlines),
                configuration: configuration,
                timeout: timeout,
                maxTokens: 256
            )
        }.value
    }

    static func detectedRunnerPath() -> String? {
        detectedRunnerPath(in: runnerCandidates)
    }

    static func detectedRunnerPath(in candidates: [String]) -> String? {
        candidates.first { runnerExists(at: $0) }
    }

    static func detectedBrewPath() -> String? {
        brewCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func runnerExists(at path: String) -> Bool {
        serverExecutable(for: path) != nil
    }

    static func installLlamaCpp() async throws -> String {
        guard let brewPath = detectedBrewPath() else {
            throw TextPostProcessingError.homebrewNotFound
        }

        return try await Task.detached(priority: .userInitiated) {
            try installLlamaCpp(using: brewPath)
        }.value
    }

    static func rewriteSystemPrompt(instructions: String) -> String {
        let style = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return style.isEmpty ? defaultInstructions : style
    }

    private static func run(
        systemPrompt: String,
        userPrompt: String,
        configuration: TextPostProcessingConfiguration,
        timeout: TimeInterval,
        maxTokens: Int
    ) throws -> String {
        let configuredPath = expandedPath(configuration.runnerPath)
        guard !configuredPath.isEmpty else { throw TextPostProcessingError.missingRunnerPath }
        guard let runnerPath = serverExecutable(for: configuredPath) else {
            throw TextPostProcessingError.runnerNotExecutable(configuredPath)
        }

        let socketURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vocamac-\(UUID().uuidString).sock")
        let server = Process()
        let serverOutput = Pipe()
        let serverFinished = DispatchSemaphore(value: 0)
        let serverOutputRead = DispatchSemaphore(value: 0)
        var serverOutputData = Data()

        server.executableURL = URL(fileURLWithPath: runnerPath)
        server.arguments = (try modelArguments(for: configuration)) + [
            "--host", socketURL.path,
            "-c", "2048",
            "--reasoning", "off",
        ]
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = serverOutput
        server.standardError = serverOutput
        server.terminationHandler = { _ in serverFinished.signal() }

        try server.run()

        DispatchQueue.global(qos: .utility).async {
            serverOutputData = serverOutput.fileHandleForReading.readDataToEndOfFile()
            serverOutputRead.signal()
        }

        defer {
            if server.isRunning {
                server.terminate()
            }
            _ = serverFinished.wait(timeout: .now() + 5)
            try? FileManager.default.removeItem(at: socketURL)
        }

        let deadline = Date().addingTimeInterval(timeout)
        try waitUntilReady(
            server: server,
            socketURL: socketURL,
            deadline: deadline,
            outputRead: serverOutputRead,
            outputData: { serverOutputData }
        )

        let request = ChatCompletionRequest(
            messages: [
                ChatMessage(role: "system", content: systemPrompt),
                ChatMessage(role: "user", content: userPrompt),
            ],
            maxTokens: maxTokens,
            temperature: 0.1,
            topP: 0.8,
            stream: false
        )
        let requestData = try JSONEncoder().encode(request)
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw TextPostProcessingError.timedOut }

        let responseData = try runCurl(
            arguments: [
                "--silent",
                "--show-error",
                "--fail-with-body",
                "--max-time", "\(Int(ceil(remaining)))",
                "--unix-socket", socketURL.path,
                "--header", "Content-Type: application/json",
                "--data-binary", "@-",
                "http://localhost/v1/chat/completions",
            ],
            input: requestData,
            timeout: remaining
        )
        return try responseText(from: responseData)
    }

    static func responseText(from data: Data) throws -> String {
        do {
            let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let text = response.choices.first?.message.content
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { throw TextPostProcessingError.emptyOutput }
            return text
        } catch let error as TextPostProcessingError {
            throw error
        } catch {
            throw TextPostProcessingError.invalidResponse(error.localizedDescription)
        }
    }

    private static func waitUntilReady(
        server: Process,
        socketURL: URL,
        deadline: Date,
        outputRead: DispatchSemaphore,
        outputData: () -> Data
    ) throws {
        while Date() < deadline {
            guard server.isRunning else {
                _ = outputRead.wait(timeout: .now() + 1)
                let details = String(data: outputData(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw TextPostProcessingError.processFailed(server.terminationStatus, details)
            }

            if FileManager.default.fileExists(atPath: socketURL.path),
               (try? runCurl(
                   arguments: [
                       "--silent",
                       "--fail",
                       "--max-time", "1",
                       "--unix-socket", socketURL.path,
                       "http://localhost/health",
                   ],
                   timeout: 2
               )) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw TextPostProcessingError.timedOut
    }

    private static func runCurl(
        arguments: [String],
        input: Data? = nil,
        timeout: TimeInterval
    ) throws -> Data {
        let task = Process()
        let output = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        let finished = DispatchSemaphore(value: 0)
        let outputRead = DispatchSemaphore(value: 0)
        var outputData = Data()

        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = arguments
        task.standardInput = inputPipe ?? FileHandle.nullDevice
        task.standardOutput = output
        task.standardError = output
        task.terminationHandler = { _ in finished.signal() }

        try task.run()
        DispatchQueue.global(qos: .utility).async {
            outputData = output.fileHandleForReading.readDataToEndOfFile()
            outputRead.signal()
        }
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            inputPipe.fileHandleForWriting.closeFile()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            task.terminate()
            throw TextPostProcessingError.timedOut
        }
        outputRead.wait()

        guard task.terminationStatus == 0 else {
            let details = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw TextPostProcessingError.processFailed(task.terminationStatus, details)
        }
        return outputData
    }

    static func modelArguments(for configuration: TextPostProcessingConfiguration) throws -> [String] {
        let model = LocalLLMModel.model(for: configuration.modelID)
        if let reference = model.reference {
            return ["-hf", reference]
        }

        let modelPath = expandedPath(configuration.customModelPath)
        guard !modelPath.isEmpty else { throw TextPostProcessingError.missingModelPath }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw TextPostProcessingError.modelNotFound(modelPath)
        }
        return ["-m", modelPath]
    }

    static func expandedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^~(?=/|$)"#, with: NSHomeDirectory(), options: .regularExpression)
    }

    private static func serverExecutable(for configuredPath: String) -> String? {
        let path = expandedPath(configuredPath)
        guard !path.isEmpty else { return nil }

        if URL(fileURLWithPath: path).lastPathComponent == "llama-server",
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let sibling = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .appendingPathComponent("llama-server")
            .path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    private static func installLlamaCpp(using brewPath: String) throws -> String {
        let task = Process()
        let finished = DispatchSemaphore(value: 0)

        task.executableURL = URL(fileURLWithPath: brewPath)
        task.arguments = ["install", "llama.cpp"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { _ in finished.signal() }

        try task.run()
        guard finished.wait(timeout: .now() + 600) == .success else {
            task.terminate()
            throw TextPostProcessingError.timedOut
        }

        guard task.terminationStatus == 0 else {
            throw TextPostProcessingError.processFailed(task.terminationStatus, "")
        }
        guard let runner = detectedRunnerPath() else {
            throw TextPostProcessingError.runnerNotExecutable("llama.cpp installed, but llama-server was not found.")
        }
        return runner
    }

    private struct ChatCompletionRequest: Encodable {
        let messages: [ChatMessage]
        let maxTokens: Int
        let temperature: Double
        let topP: Double
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case messages
            case maxTokens = "max_tokens"
            case temperature
            case topP = "top_p"
            case stream
        }
    }

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatCompletionResponse: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let message: ChatMessage
        }
    }
}
