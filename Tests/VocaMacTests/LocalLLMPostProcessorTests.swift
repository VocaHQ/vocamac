// LocalLLMPostProcessorTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

final class LocalLLMPostProcessorTests: XCTestCase {
    func testRewriteSystemPromptUsesCustomInstructions() {
        XCTAssertEqual(
            LocalLLMPostProcessor.rewriteSystemPrompt(instructions: "Keep it concise."),
            "Keep it concise."
        )
    }

    func testResponseTextDecodesStructuredAssistantReply() throws {
        let response = """
        {
          "choices": [
            {
              "message": {
                "role": "assistant",
                "content": "Email Namrata about the launch."
              }
            }
          ]
        }
        """

        XCTAssertEqual(
            try LocalLLMPostProcessor.responseText(from: Data(response.utf8)),
            "Email Namrata about the launch."
        )
    }

    func testResponseTextRejectsMissingAssistantReply() {
        let response = #"{"choices":[]}"#

        XCTAssertThrowsError(
            try LocalLLMPostProcessor.responseText(from: Data(response.utf8))
        ) { error in
            guard case TextPostProcessingError.emptyOutput = error else {
                return XCTFail("Expected emptyOutput, got \(error)")
            }
        }
    }

    func testModelArgumentsUseHuggingFaceReferenceForCatalogModel() throws {
        let config = TextPostProcessingConfiguration(
            runnerPath: "/usr/bin/false",
            modelID: "gemma-3-1b-q4",
            customModelPath: "",
            instructions: ""
        )

        XCTAssertEqual(
            try LocalLLMPostProcessor.modelArguments(for: config),
            ["-hf", "ggml-org/gemma-3-1b-it-GGUF:Q4_K_M"]
        )
    }

    func testModelArgumentsValidateCustomModelPath() {
        let config = TextPostProcessingConfiguration(
            runnerPath: "/usr/bin/false",
            modelID: LocalLLMModel.customID,
            customModelPath: "/definitely/not/a/model.gguf",
            instructions: ""
        )

        XCTAssertThrowsError(try LocalLLMPostProcessor.modelArguments(for: config))
    }

    func testDetectedRunnerPathUsesFirstExecutableServerCandidate() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocamac-llama-tools-\(UUID().uuidString)")
        let serverURL = directoryURL.appendingPathComponent("llama-server")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: serverURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        XCTAssertEqual(
            LocalLLMPostProcessor.detectedRunnerPath(in: ["/definitely/missing", serverURL.path]),
            serverURL.path
        )
    }

    func testRunnerExistsResolvesServerNextToLegacyCLIPath() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocamac-llama-tools-\(UUID().uuidString)")
        let serverURL = directoryURL.appendingPathComponent("llama-server")
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: serverURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        XCTAssertTrue(
            LocalLLMPostProcessor.runnerExists(
                at: directoryURL.appendingPathComponent("llama-cli").path
            )
        )
    }

    func testLocalLlamaServerIntegrationWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["VOCAMAC_RUN_LOCAL_LLM_TEST"] == "1" else {
            throw XCTSkip("Set VOCAMAC_RUN_LOCAL_LLM_TEST=1 to run the local model integration test.")
        }
        guard LocalLLMPostProcessor.runnerExists(at: LocalLLMPostProcessor.defaultRunnerPath) else {
            throw XCTSkip("llama-server is not installed.")
        }

        let result = try await LocalLLMPostProcessor().improve(
            "um the launch moved to friday",
            configuration: TextPostProcessingConfiguration(
                runnerPath: LocalLLMPostProcessor.defaultRunnerPath,
                modelID: LocalLLMModel.recommendedID,
                customModelPath: "",
                instructions: ""
            )
        )

        XCTAssertTrue(result.localizedCaseInsensitiveContains("Friday"))
        XCTAssertFalse(result.contains("\"choices\""))
        XCTAssertFalse(result.contains("Loading model"))
    }
}
