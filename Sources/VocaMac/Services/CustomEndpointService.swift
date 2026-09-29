// CustomEndpointService.swift
// VocaMac
//
// The Custom Endpoint speech engine: each recording is uploaded as a WAV file
// to a Whisper-compatible HTTP endpoint the user hosts, and the endpoint's
// transcript comes back. No model runs on this Mac — `loadModel` validates
// the endpoint settings and `transcribe` performs one multipart POST.
//
// Request shapes match VocaLinux's Remote API engine: the OpenAI audio API
// (`POST <base>/v1/audio/transcriptions`) or a whisper.cpp server
// (`POST <base>/inference`), both answering with JSON like {"text": "..."}.

import Foundation

/// Failures the endpoint can return, named like the other engines' errors.
enum CustomEndpointError: LocalizedError, Equatable {
    /// `transcribe` was called before `loadModel` succeeded.
    case modelNotLoaded
    /// Nothing was recorded to send.
    case emptyAudio
    /// The saved endpoint settings cannot produce a request.
    case notConfigured(String)
    /// The endpoint answered with a non-2xx status.
    case endpointRejected(status: Int, detail: String?)
    /// A 2xx answer that was not the JSON transcript shape expected.
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "The custom endpoint is not loaded."
        case .emptyAudio:
            return "Nothing was recorded."
        case .notConfigured(let problem):
            return problem
        case .endpointRejected(let status, _):
            return "The endpoint answered HTTP \(status)."
        case .unexpectedResponse:
            return "The endpoint's answer was not the JSON transcript VocaMac expects."
        }
    }
}

final class CustomEndpointService: SpeechTranscribing {

    /// Endpoint settings, read fresh so a Settings edit applies to the next
    /// dictation without a reload.
    private let configurationProvider: () -> SpeechEndpointConfiguration
    private let credentials: EndpointCredentialStoring
    private let session: URLSession

    private(set) var loadedModelName: String?
    private(set) var isModelLoaded = false

    /// The sample rate recordings are captured at across the app.
    static let sampleRate = 16_000

    /// The upload stands between the stop key and the paste like every
    /// decode does, but a remote server can be slower than the on-device
    /// engines, so it gets longer than cleanup's request timeout.
    static let requestTimeout: TimeInterval = 120

    init(
        configurationProvider: @escaping () -> SpeechEndpointConfiguration = {
            SpeechEndpointConfiguration.decode(
                UserDefaults.standard.string(forKey: PreferenceKey.speechEndpoint)
            )
        },
        credentials: EndpointCredentialStoring = KeychainCredentialStore.speechEndpoint,
        session: URLSession = CustomEndpointService.makeSpeechSession()
    ) {
        self.configurationProvider = configurationProvider
        self.credentials = credentials
        self.session = session
    }

    /// A session that re-checks every redirect hop against the speech URL
    /// rules, so a 302/307 cannot bounce a WAV upload onto cleartext public
    /// HTTP. Tests pass a configuration with a stub `URLProtocol`.
    static func makeSpeechSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        return URLSession(
            configuration: configuration,
            delegate: SpeechEndpointRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// Load "the endpoint": validate the saved settings and mark the engine
    /// ready. There is nothing to fetch or warm, so this returns at once.
    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws {
        let configuration = configurationProvider()
        if let problem = configuration.validationProblem() {
            VocaLogger.warning(.customEndpointService, "Endpoint settings rejected on load: \(problem)")
            throw CustomEndpointError.notConfigured(problem)
        }
        loadedModelName = name ?? ModelSize.customEndpoint.rawValue
        isModelLoaded = true
        VocaLogger.info(
            .customEndpointService,
            "Custom endpoint ready: \(configuration.loggableBaseURL)"
        )
    }

    func unloadModel() {
        loadedModelName = nil
        isModelLoaded = false
    }

    /// Upload the recording and return the endpoint's transcript.
    ///
    /// `translate` and `vocabulary` belong to the on-device engines and are
    /// not part of either endpoint contract, so they are dropped here.
    func transcribe(
        audioData: [Float],
        language: String?,
        translate: Bool,
        vocabulary: String
    ) async throws -> VocaTranscription {
        guard isModelLoaded else { throw CustomEndpointError.modelNotLoaded }
        guard !audioData.isEmpty else { throw CustomEndpointError.emptyAudio }
        let configuration = configurationProvider()
        guard let url = configuration.transcriptionsURL else {
            let problem = configuration.validationProblem() ?? "The endpoint settings are invalid."
            throw CustomEndpointError.notConfigured(problem)
        }

        var form = MultipartForm()
        let wav = WAVEncoder.pcm16Mono(from: audioData, sampleRate: Self.sampleRate)
        form.appendFile("file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        switch configuration.kind {
        case .openAICompatible:
            form.appendField("model", configuration.resolvedModel)
            form.appendField("response_format", "json")
            if let language { form.appendField("language", language) }
        case .whisperCpp:
            form.appendField("temperature", "0")
            form.appendField("temperature_inc", "0.2")
            form.appendField("response_format", "json")
            if let language { form.appendField("language", language) }
        }
        form.close()

        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(form.boundary)", forHTTPHeaderField: "Content-Type"
        )
        if let key = credentials.readAPIKey(), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = form.body

        let started = Date()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomEndpointError.unexpectedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data.prefix(240), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                VocaLogger.warning(
                    .customEndpointService,
                    "Endpoint rejected the recording with HTTP \(http.statusCode): \(detail)"
                )
            } else {
                VocaLogger.warning(
                    .customEndpointService,
                    "Endpoint rejected the recording with HTTP \(http.statusCode)"
                )
            }
            throw CustomEndpointError.endpointRejected(status: http.statusCode, detail: detail)
        }

        let text = try Self.transcript(from: data)
        return VocaTranscription(
            text: text,
            duration: Date().timeIntervalSince(started),
            detectedLanguage: language ?? "auto",
            audioLengthSeconds: Double(audioData.count) / Double(Self.sampleRate),
            modelUsed: .customEndpoint
        )
    }

    /// Pull the transcript out of a 2xx answer. `text` is the documented
    /// shape for both contracts; the fallbacks cover the variants VocaLinux
    /// accepts so an endpoint behaves the same on either app.
    static func transcript(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Segment: Decodable { let text: String? }
            let text: String?
            let transcript: String?
            let transcription: String?
            let segments: [Segment]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CustomEndpointError.unexpectedResponse
        }
        if let text = decoded.text ?? decoded.transcript ?? decoded.transcription {
            return text
        }
        if let segments = decoded.segments {
            return segments.compactMap(\.text).joined(separator: " ")
        }
        throw CustomEndpointError.unexpectedResponse
    }
}

/// A `multipart/form-data` request body, built by hand so the service stays
/// dependency-free like the rest of the app.
struct MultipartForm {
    let boundary = "VocaMacBoundary-\(UUID().uuidString)"
    private(set) var body = Data()

    mutating func appendField(_ name: String, _ value: String) {
        let name = Self.withoutLineBreaks(name)
        let value = Self.withoutLineBreaks(value)
        body.append(contentsOf: (
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            + "\(value)\r\n"
        ).utf8)
    }

    mutating func appendFile(_ name: String, filename: String, contentType: String, data: Data) {
        let name = Self.withoutLineBreaks(name)
        let filename = Self.withoutLineBreaks(filename)
        let contentType = Self.withoutLineBreaks(contentType)
        body.append(contentsOf: (
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
            + "Content-Type: \(contentType)\r\n\r\n"
        ).utf8)
        body.append(data)
        body.append(contentsOf: "\r\n".utf8)
    }

    mutating func close() {
        body.append(contentsOf: "--\(boundary)--\r\n".utf8)
    }

    /// CR/LF in a multipart name or value would split the body into extra
    /// parts. Drop them rather than send a malformed upload. Filtered at
    /// scalar level: a CRLF pair is one `Character` and would slip past a
    /// Character comparison.
    static func withoutLineBreaks(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" })
    }
}

/// Follows a redirect only when the next hop would still pass speech URL
/// validation (HTTPS, or cleartext on loopback / RFC1918 / `.local`).
final class SpeechEndpointRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, SpeechEndpointConfiguration.allowsRecordingDestination(url) else {
            VocaLogger.warning(
                .customEndpointService,
                "Rejected a redirect that would leave the speech allowlist"
            )
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
