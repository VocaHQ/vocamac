// CustomEndpointServiceTests.swift
// VocaMac
//
// Protocol-level coverage of the custom speech endpoint: request
// construction, response parsing, settings persistence, and load/unload
// state — all through a stub URLProtocol, never the network.

import XCTest
@testable import VocaMac

private struct StubEndpointCredentials: EndpointCredentialStoring {
    let apiKey: String?
    func readAPIKey() -> String? { apiKey }
    func saveAPIKey(_ value: String) throws {}
    func deleteAPIKey() throws {}
}

/// Holds the last request the stub saw so a test can assert on it after the
/// service call returns (the handler itself is `@Sendable`).
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?
    func put(_ request: URLRequest) { lock.withLock { stored = request } }
    var request: URLRequest? { lock.withLock { stored } }
}

private final class StubEndpointURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let handlerLock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?

    static func install(_ value: @escaping Handler) {
        handlerLock.withLock { handler = value }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.handlerLock.withLock { Self.handler }
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class SpeechEndpointConfigurationTests: XCTestCase {

    func testDefaultsAreTheOpenAIContract() {
        let configuration = SpeechEndpointConfiguration()
        XCTAssertEqual(configuration.kind, .openAICompatible)
        XCTAssertEqual(configuration.resolvedModel, "whisper-1")
        XCTAssertNotNil(configuration.validationProblem(), "No base URL is not a usable endpoint")
        XCTAssertNil(configuration.transcriptionsURL)
    }

    func testTranscriptionsURLJoinsBaseAndPath() {
        var configuration = SpeechEndpointConfiguration()
        configuration.baseURL = "https://speech.example.com/"
        configuration.kind = .openAICompatible
        XCTAssertEqual(
            configuration.transcriptionsURL?.absoluteString,
            "https://speech.example.com/v1/audio/transcriptions"
        )
        configuration.kind = .whisperCpp
        XCTAssertEqual(
            configuration.transcriptionsURL?.absoluteString,
            "https://speech.example.com/inference"
        )
    }

    func testPlainHTTPRequiresALocalNetworkHost() {
        var configuration = SpeechEndpointConfiguration()

        configuration.baseURL = "http://192.168.1.20:8080"
        XCTAssertNil(configuration.validationProblem())

        configuration.baseURL = "http://localhost:8080"
        XCTAssertNil(configuration.validationProblem())

        configuration.baseURL = "http://speech.local"
        XCTAssertNil(configuration.validationProblem())

        configuration.baseURL = "http://speech.example.com"
        XCTAssertEqual(
            configuration.validationProblem(),
            "Use HTTPS for servers outside this Mac or your local network."
        )

        configuration.baseURL = "https://speech.example.com"
        XCTAssertNil(configuration.validationProblem())
    }

    func testNonHTTPSchemesAreRejected() {
        var configuration = SpeechEndpointConfiguration()
        configuration.baseURL = "ftp://192.168.1.20"
        XCTAssertNotNil(configuration.validationProblem())
        configuration.baseURL = "not a url"
        XCTAssertNotNil(configuration.validationProblem())
    }

    func testDecodeOfEmptyOrGarbageFallsBackToDefaults() {
        XCTAssertEqual(SpeechEndpointConfiguration.decode(nil), SpeechEndpointConfiguration())
        XCTAssertEqual(SpeechEndpointConfiguration.decode(""), SpeechEndpointConfiguration())
        XCTAssertEqual(SpeechEndpointConfiguration.decode("{nope"), SpeechEndpointConfiguration())
    }

    func testEncodedRoundTrips() {
        var configuration = SpeechEndpointConfiguration()
        configuration.kind = .whisperCpp
        configuration.baseURL = "http://nas.local:8178"
        configuration.model = "large-v3"
        XCTAssertEqual(SpeechEndpointConfiguration.decode(configuration.encoded()), configuration)
    }
}

final class CustomEndpointServiceTests: XCTestCase {

    private let requestBox = RequestBox()

    private func makeService(
        configuration: SpeechEndpointConfiguration,
        apiKey: String? = nil
    ) -> CustomEndpointService {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubEndpointURLProtocol.self]
        return CustomEndpointService(
            configurationProvider: { configuration },
            credentials: StubEndpointCredentials(apiKey: apiKey),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    private func configuredService(
        kind: SpeechEndpointKind = .openAICompatible,
        model: String = "",
        apiKey: String? = nil
    ) -> CustomEndpointService {
        var configuration = SpeechEndpointConfiguration()
        configuration.kind = kind
        configuration.baseURL = "https://speech.example.com"
        configuration.model = model
        return makeService(configuration: configuration, apiKey: apiKey)
    }

    /// Load the engine and send one 2-second recording through the stub,
    /// which answers `status`/`body` and remembers the request it saw.
    private func transcribe(
        _ service: CustomEndpointService,
        body: String = #"{"text": "hello world"}"#,
        status: Int = 200,
        language: String? = nil
    ) async throws -> VocaTranscription {
        try await service.loadModel(name: ModelSize.customEndpoint.rawValue)
        StubEndpointURLProtocol.install { [requestBox] request in
            requestBox.put(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        return try await service.transcribe(
            audioData: [Float](repeating: 0.5, count: 32_000),
            language: language, translate: false, vocabulary: ""
        )
    }

    /// The request body as text. The WAV payload is binary, so undecodable
    /// bytes become replacement characters — the ASCII field markers the
    /// tests look for still match.
    private var capturedBody: String? {
        requestBox.request
            .flatMap { StubEndpointURLProtocol.bodyData(from: $0) }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    private func littleEndianBytes(of value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: - Loading

    func testLoadModelMarksTheEndpointReady() async throws {
        let service = configuredService()
        try await service.loadModel(name: ModelSize.customEndpoint.rawValue)
        XCTAssertTrue(service.isModelLoaded)
        XCTAssertEqual(service.loadedModelName, ModelSize.customEndpoint.rawValue)
    }

    func testLoadModelRejectsInvalidSettings() async {
        let service = makeService(configuration: SpeechEndpointConfiguration())
        do {
            try await service.loadModel()
            XCTFail("expected notConfigured")
        } catch let error as CustomEndpointError {
            guard case .notConfigured = error else {
                return XCTFail("expected notConfigured, got \(error)")
            }
        } catch {
            XCTFail("expected CustomEndpointError, got \(error)")
        }
        XCTAssertFalse(service.isModelLoaded)
    }

    func testUnloadModelClearsTheReadyFlag() async throws {
        let service = configuredService()
        try await service.loadModel()
        service.unloadModel()
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertNil(service.loadedModelName)
    }

    func testTranscribeBeforeLoadThrowsModelNotLoaded() async {
        let service = configuredService()
        do {
            _ = try await service.transcribe(
                audioData: [0.5], language: nil, translate: false, vocabulary: ""
            )
            XCTFail("expected modelNotLoaded")
        } catch let error as CustomEndpointError {
            XCTAssertEqual(error, .modelNotLoaded)
        } catch {
            XCTFail("expected CustomEndpointError, got \(error)")
        }
    }

    func testTranscribeEmptyAudioThrows() async throws {
        let service = configuredService()
        try await service.loadModel()
        do {
            _ = try await service.transcribe(
                audioData: [], language: nil, translate: false, vocabulary: ""
            )
            XCTFail("expected emptyAudio")
        } catch let error as CustomEndpointError {
            XCTAssertEqual(error, .emptyAudio)
        } catch {
            XCTFail("expected CustomEndpointError, got \(error)")
        }
    }

    // MARK: - Request construction

    func testOpenAIRequestShape() async throws {
        let service = configuredService(model: "large-v3", apiKey: "sk-test")
        _ = try await transcribe(service, language: "en")

        let request = try XCTUnwrap(requestBox.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://speech.example.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try XCTUnwrap(capturedBody)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(body.contains("Content-Type: audio/wav"))
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nlarge-v3"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(body.hasSuffix("--\r\n"))
    }

    func testOpenAIRequestOmitsLanguageWhenUnset() async throws {
        let service = configuredService()
        _ = try await transcribe(service)
        let body = try XCTUnwrap(capturedBody)
        XCTAssertFalse(body.contains("name=\"language\""))
        // The documented default model stands in when none is configured.
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertNil(requestBox.request?.value(forHTTPHeaderField: "Authorization"))
    }

    func testWhisperCppRequestShape() async throws {
        let service = configuredService(kind: .whisperCpp)
        _ = try await transcribe(service, language: "de")

        XCTAssertEqual(
            requestBox.request?.url?.absoluteString,
            "https://speech.example.com/inference"
        )
        let body = try XCTUnwrap(capturedBody)
        XCTAssertTrue(body.contains("name=\"temperature\"\r\n\r\n0"))
        XCTAssertTrue(body.contains("name=\"temperature_inc\"\r\n\r\n0.2"))
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\njson"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertFalse(body.contains("name=\"model\""))
    }

    func testUploadCarriesA16kHzMonoWAV() async throws {
        let service = configuredService()
        _ = try await transcribe(service)
        let request = try XCTUnwrap(requestBox.request)
        let data = try XCTUnwrap(StubEndpointURLProtocol.bodyData(from: request))
        guard let riff = data.range(of: Data("RIFF".utf8)) else {
            return XCTFail("no RIFF header in the upload")
        }
        let wav = data.subdata(in: riff.lowerBound..<data.count)
        XCTAssertEqual(wav.subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(wav.subdata(in: 22..<24), Data([1, 0])) // mono
        XCTAssertEqual(wav.subdata(in: 24..<28), Data([0x80, 0x3E, 0, 0])) // 16_000
        // The RIFF and data-chunk sizes declare 64_000 bytes of PCM — 32_000
        // 16-bit samples — after a 44-byte header.
        let pcmBytes = 32_000 * 2
        XCTAssertEqual(wav.subdata(in: 4..<8), littleEndianBytes(of: UInt32(36 + pcmBytes)))
        XCTAssertEqual(wav.subdata(in: 40..<44), littleEndianBytes(of: UInt32(pcmBytes)))
        XCTAssertGreaterThanOrEqual(wav.count, 44 + pcmBytes)
    }

    // MARK: - Response parsing

    func testParsesTheTextField() async throws {
        let service = configuredService()
        let result = try await transcribe(service, body: #"{"text": "dictated words"}"#)
        XCTAssertEqual(result.text, "dictated words")
        XCTAssertEqual(result.modelUsed, .customEndpoint)
        XCTAssertEqual(result.audioLengthSeconds, 2.0, accuracy: 0.001)
    }

    func testParsesVocaLinuxFallbackKeys() async throws {
        let service = configuredService()
        var result = try await transcribe(service, body: #"{"transcript": "a"}"#)
        XCTAssertEqual(result.text, "a")
        result = try await transcribe(service, body: #"{"transcription": "b"}"#)
        XCTAssertEqual(result.text, "b")
        result = try await transcribe(service, body: #"{"segments": [{"text": "c"}, {"text": "d"}]}"#)
        XCTAssertEqual(result.text, "c d")
    }

    func testEmptyTranscriptIsNotAnError() async throws {
        let service = configuredService()
        let result = try await transcribe(service, body: #"{"text": ""}"#)
        XCTAssertEqual(result.text, "")
    }

    func testMalformedJSONThrowsUnexpectedResponse() async throws {
        let service = configuredService()
        do {
            _ = try await transcribe(service, body: "<html>no</html>")
            XCTFail("expected unexpectedResponse")
        } catch let error as CustomEndpointError {
            XCTAssertEqual(error, .unexpectedResponse)
        } catch {
            XCTFail("expected CustomEndpointError, got \(error)")
        }
    }

    func testJSONWithoutARecognizedKeyThrows() async throws {
        let service = configuredService()
        do {
            _ = try await transcribe(service, body: "{}")
            XCTFail("expected unexpectedResponse")
        } catch let error as CustomEndpointError {
            XCTAssertEqual(error, .unexpectedResponse)
        } catch {
            XCTFail("expected CustomEndpointError, got \(error)")
        }
    }

    func testHTTPErrorSurfacesStatusAndDetail() async throws {
        let service = configuredService()
        do {
            _ = try await transcribe(service, body: #"{"error": "model missing"}"#, status: 500)
            XCTFail("expected endpointRejected")
        } catch let error as CustomEndpointError {
            guard case let .endpointRejected(status, detail) = error else {
                return XCTFail("expected endpointRejected, got \(error)")
            }
            XCTAssertEqual(status, 500)
            XCTAssertEqual(detail, #"{"error": "model missing"}"#)
        } catch {
            XCTFail("expected CustomEndpointError, got \(error)")
        }
    }

    func testNetworkFailurePropagatesTheURLError() async throws {
        let service = configuredService()
        try await service.loadModel()
        StubEndpointURLProtocol.install { _ in throw URLError(.timedOut) }
        do {
            _ = try await service.transcribe(
                audioData: [Float](repeating: 0.1, count: 1_600),
                language: nil, translate: false, vocabulary: ""
            )
            XCTFail("expected a URLError")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("expected URLError, got \(error)")
        }
    }

    // MARK: - Settings persistence

    @MainActor
    func testAppStatePersistsTheEndpointSettings() {
        let (appState, _) = AppState.makeTestState()
        defer { UserDefaults.standard.removeObject(forKey: PreferenceKey.speechEndpoint) }

        var configuration = SpeechEndpointConfiguration()
        configuration.kind = .whisperCpp
        configuration.baseURL = "http://nas.local:8178"
        appState.speechEndpoint = configuration

        XCTAssertEqual(
            SpeechEndpointConfiguration.decode(
                UserDefaults.standard.string(forKey: PreferenceKey.speechEndpoint)
            ),
            configuration
        )
        XCTAssertEqual(appState.speechEndpoint, configuration)
    }

    func testEngineResolutionFindsTheEndpoint() {
        XCTAssertEqual(
            TranscriptionRouter.engine(forModelIdentifier: ModelSize.customEndpoint.rawValue),
            .customEndpoint
        )
    }
}
