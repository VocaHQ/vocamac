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
import os

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

/// Unchecked: the loaded state is behind a lock, the configuration and
/// credentials are read from UserDefaults and the Keychain (both safe from
/// any thread), and URLSession is thread-safe.
final class CustomEndpointService: SpeechTranscribing, @unchecked Sendable {

    /// Endpoint settings, read fresh so a Settings edit applies to the next
    /// dictation without a reload.
    private let configurationProvider: () -> SpeechEndpointConfiguration
    private let credentials: EndpointCredentialStoring
    private let session: URLSession

    private struct LoadState {
        var modelName: String?
        var isLoaded = false
    }

    private let loadState = OSAllocatedUnfairLock(initialState: LoadState())

    var loadedModelName: String? { loadState.withLock { $0.modelName } }
    var isModelLoaded: Bool { loadState.withLock { $0.isLoaded } }

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
    func _loadModel(name: String?, folder: URL?, onPhaseChange: (@Sendable (String) -> Void)?) async throws {
        let configuration = configurationProvider()
        if let problem = configuration.validationProblem() {
            VocaLogger.warning(.customEndpointService, "Endpoint settings rejected on load: \(problem)")
            throw CustomEndpointError.notConfigured(problem)
        }
        let modelName = name ?? ModelSize.customEndpoint.rawValue
        loadState.withLock { $0 = LoadState(modelName: modelName, isLoaded: true) }
        VocaLogger.info(
            .customEndpointService,
            "Custom endpoint ready: \(configuration.loggableBaseURL)"
        )
    }

    func unloadModel() {
        loadState.withLock { $0 = LoadState() }
    }

    /// Upload the recording and return the endpoint's transcript.
    ///
    /// `vocabulary` goes as the `prompt` field both contracts accept, the
    /// same "Glossary:" Whisper gets on this Mac (see `prompt(for:)`).
    /// `translate` belongs to the on-device engines and is dropped.
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

        // Verbose JSON carries the detected language and per-segment timing
        // and scores, which the language rules and the hallucination guard
        // use. An endpoint that refuses it is asked for plain JSON, and
        // remembered so later dictations upload once.
        let formatKey = "\(url.absoluteString)|\(configuration.resolvedModel)"
        let wantsVerbose = Self.mayAcceptVerboseJSON(configuration)
            && !verboseRefused.withLock { $0.contains(formatKey) }
        let started = Date()
        var (data, status) = try await upload(
            audioData, to: url, configuration: configuration, language: language,
            vocabulary: vocabulary, verbose: wantsVerbose
        )
        if wantsVerbose, Self.refusesVerboseJSON(status: status) {
            VocaLogger.info(
                .customEndpointService,
                "Endpoint refused verbose JSON (HTTP \(status)); asking for plain JSON from now on"
            )
            verboseRefused.withLock { _ = $0.insert(formatKey) }
            (data, status) = try await upload(
                audioData, to: url, configuration: configuration, language: language,
                vocabulary: vocabulary, verbose: false
            )
        }
        guard (200..<300).contains(status) else {
            // Keep any body snippet on the thrown error for callers; never
            // write response bodies into logs (they can carry prompt text or
            // other sensitive detail from the user's server).
            let detail = String(data: data.prefix(240), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            VocaLogger.warning(
                .customEndpointService,
                "Endpoint rejected the recording with HTTP \(status)"
            )
            throw CustomEndpointError.endpointRejected(status: status, detail: detail)
        }

        let answer = try Self.response(from: data)
        var transcription = VocaTranscription(
            text: answer.text,
            duration: Date().timeIntervalSince(started),
            detectedLanguage: language ?? answer.language ?? "auto",
            audioLengthSeconds: Double(audioData.count) / Double(Self.sampleRate),
            modelUsed: .customEndpoint,
            segments: answer.segments
        )
        transcription.quality = answer.quality
        return transcription
    }

    /// Endpoints that refused verbose JSON, by URL and model.
    private let verboseRefused = OSAllocatedUnfairLock(initialState: Set<String>())

    /// Upload the recording once; the answer's body and HTTP status.
    private func upload(
        _ audioData: [Float], to url: URL, configuration: SpeechEndpointConfiguration,
        language: String?, vocabulary: String, verbose: Bool
    ) async throws -> (Data, Int) {
        var form = MultipartForm()
        let wav = WAVEncoder.pcm16Mono(from: audioData, sampleRate: Self.sampleRate)
        form.appendFile("file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        let format = verbose ? "verbose_json" : "json"
        switch configuration.kind {
        case .openAICompatible:
            form.appendField("model", configuration.resolvedModel)
            form.appendField("response_format", format)
            if let language { form.appendField("language", language) }
        case .whisperCpp:
            form.appendField("temperature", "0")
            form.appendField("temperature_inc", "0.2")
            form.appendField("response_format", format)
            if let language { form.appendField("language", language) }
        }
        if let prompt = Self.prompt(for: vocabulary) { form.appendField("prompt", prompt) }
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

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CustomEndpointError.unexpectedResponse
        }
        return (data, http.statusCode)
    }

    /// Whether to ask for verbose JSON at all. OpenAI's GPT-4o transcribe
    /// models accept only plain JSON or text, so they are never asked.
    static func mayAcceptVerboseJSON(_ configuration: SpeechEndpointConfiguration) -> Bool {
        switch configuration.kind {
        case .whisperCpp:
            return true
        case .openAICompatible:
            return !configuration.resolvedModel.lowercased().hasPrefix("gpt-")
        }
    }

    /// The statuses a server answers an unsupported `response_format` with.
    static func refusesVerboseJSON(status: Int) -> Bool {
        status == 400 || status == 415 || status == 422
    }

    /// Longest glossary sent, in characters. OpenAI reads only the last 224
    /// tokens of a Whisper prompt; this stays well inside that.
    static let maximumPromptCharacters = 600

    /// The "Glossary:" prompt for a comma/newline vocabulary, keeping the
    /// terms at its end (the user's own, see `AppState.recognitionVocabulary`)
    /// when it is too long. Nil when there are no terms.
    static func prompt(for vocabulary: String) -> String? {
        var kept: [String] = []
        var used = 0
        for term in RecognitionHints.terms(from: vocabulary).reversed() {
            guard used + term.count + 2 <= maximumPromptCharacters else { break }
            kept.insert(term, at: 0)
            used += term.count + 2
        }
        return kept.isEmpty ? nil : "Glossary: " + kept.joined(separator: ", ")
    }

    /// What a 2xx answer says.
    struct Answer: Equatable {
        var text: String
        /// ISO 639-1 code, when the answer names a language.
        var language: String?
        var segments: [TimedSegment] = []
        var quality: DecodeQuality?
    }

    /// Pull the transcript out of a 2xx answer. `text` is the documented
    /// shape for both contracts; the fallbacks cover the variants VocaLinux
    /// accepts so an endpoint behaves the same on either app.
    static func transcript(from data: Data) throws -> String {
        try response(from: data).text
    }

    /// The transcript and, from a verbose answer, its language, segment
    /// timings and Whisper scores.
    static func response(from data: Data) throws -> Answer {
        struct Response: Decodable {
            struct Word: Decodable {
                let word: String?
                let start: Double?
                let end: Double?
                let probability: Double?
            }
            struct Segment: Decodable {
                let text: String?
                let start: Double?
                let end: Double?
                let tokens: [Int]?
                let avgLogprob: Double?
                let compressionRatio: Double?
                let noSpeechProb: Double?
                let words: [Word]?

                enum CodingKeys: String, CodingKey {
                    case text, start, end, tokens, words
                    case avgLogprob = "avg_logprob"
                    case compressionRatio = "compression_ratio"
                    case noSpeechProb = "no_speech_prob"
                }
            }
            let text: String?
            let transcript: String?
            let transcription: String?
            let language: String?
            let segments: [Segment]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw CustomEndpointError.unexpectedResponse
        }
        let segments = decoded.segments ?? []
        let text: String
        if let whole = decoded.text ?? decoded.transcript ?? decoded.transcription {
            text = whole
        } else if decoded.segments != nil {
            text = segments.compactMap(\.text).joined(separator: " ")
        } else {
            throw CustomEndpointError.unexpectedResponse
        }
        let timed = segments.compactMap { segment -> TimedSegment? in
            guard let start = segment.start, let end = segment.end, let segmentText = segment.text else { return nil }
            let words = (segment.words ?? []).compactMap { word -> TimedWord? in
                guard let text = word.word, let start = word.start, let end = word.end else { return nil }
                return TimedWord(
                    word: text.trimmingCharacters(in: .whitespaces), start: start, end: end,
                    probability: word.probability
                )
            }
            return TimedSegment(
                start: start, end: end, text: segmentText.trimmingCharacters(in: .whitespaces), words: words
            )
        }
        let scored = segments.compactMap { segment -> DecodeQuality.Segment? in
            guard let logProbability = segment.avgLogprob else { return nil }
            return DecodeQuality.Segment(
                averageLogProbability: logProbability,
                compressionRatio: segment.compressionRatio ?? 1,
                noSpeechProbability: segment.noSpeechProb,
                weight: segment.tokens?.count ?? segment.text?.count ?? 1
            )
        }
        return Answer(
            text: text, language: languageCode(decoded.language), segments: timed,
            quality: DecodeQuality(segments: scored)
        )
    }

    /// An ISO 639-1 code for a reported language: OpenAI and whisper.cpp
    /// write the English name ("english", "german"), others a code.
    static func languageCode(_ reported: String?) -> String? {
        guard let reported = reported?.trimmingCharacters(in: .whitespaces).lowercased(),
              !reported.isEmpty else { return nil }
        if reported.count <= 3, reported.allSatisfy(\.isLetter) { return reported }
        if reported.count > 3, reported.contains("-") || reported.contains("_") {
            return String(reported.prefix { $0.isLetter })
        }
        return languageCodesByName[reported]
    }

    /// ISO 639-1 codes by English language name.
    private static let languageCodesByName: [String: String] = {
        let english = Locale(identifier: "en")
        var codes: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes where code.identifier.count == 2 {
            if let name = english.localizedString(forLanguageCode: code.identifier)?.lowercased() {
                codes[name] = codes[name] ?? code.identifier
            }
        }
        return codes
    }()
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

/// Follows a redirect only when the next hop keeps the recording off
/// cleartext-public HTTP: never HTTPS→HTTP (even to loopback), and otherwise
/// only destinations that still pass speech URL validation.
final class SpeechEndpointRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        let fromScheme = response.url?.scheme?.lowercased()
        let toScheme = url.scheme?.lowercased()
        // A 307 would resend the WAV (and Authorization) on the next hop.
        // Reject any HTTPS→HTTP downgrade, including loopback / RFC1918 /
        // `.local`, so a TLS front door cannot bounce the recording to
        // cleartext.
        if fromScheme == "https", toScheme == "http" {
            VocaLogger.warning(
                .customEndpointService,
                "Rejected an HTTPS→HTTP redirect that would cleartext the recording"
            )
            completionHandler(nil)
            return
        }
        guard SpeechEndpointConfiguration.allowsRecordingDestination(url) else {
            VocaLogger.warning(
                .customEndpointService,
                "Rejected a redirect that would leave the speech allowlist"
            )
            completionHandler(nil)
            return
        }
        // The API key is for the configured endpoint only; a redirect to a
        // different host must not forward it.
        var redirected = request
        if url.host?.lowercased() != response.url?.host?.lowercased() {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}
