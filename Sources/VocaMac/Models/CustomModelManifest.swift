// CustomModelManifest.swift
// VocaMac
//
// `vocamodel.json`: what a model the user brings describes about itself, and
// the checks it has to pass before VocaMac will load it. See
// docs/CUSTOM_MODELS.md for the format.

import Foundation

/// Which part of VocaMac runs an imported model.
enum CustomModelEngine: String, Codable, CaseIterable, Sendable {
    /// A WhisperKit CoreML folder (MelSpectrogram, AudioEncoder, TextDecoder).
    case whisperKit
    /// A sherpa-onnx model folder (Moonshine, SenseVoice, NeMo CTC, Canary, Qwen3-ASR).
    case sherpaOnnx
    /// A GGUF for Smart Cleanup and Command Mode, run by llama.cpp.
    case cleanup

    var displayName: String {
        switch self {
        case .whisperKit: return "Whisper (CoreML)"
        case .sherpaOnnx: return "Specialized (ONNX)"
        case .cleanup: return "Writing AI (GGUF)"
        }
    }

    /// The catalog slot an active model of this engine is selected through.
    var modelSlot: ModelSize? {
        switch self {
        case .whisperKit: return .customWhisperKit
        case .sherpaOnnx: return .customSherpaOnnx
        case .cleanup: return nil
        }
    }
}

/// The contents of `vocamodel.json`.
struct CustomModelManifest: Codable, Equatable, Sendable {
    /// Lowercase letters, digits, `.`, `_` and `-`; unique on this Mac.
    var id: String
    var name: String
    var engine: CustomModelEngine
    /// ISO 639-1 codes the model was trained for. Empty means unknown.
    var languages: [String]
    /// Size on disk. Filled in on import when the manifest leaves it out.
    var fileSizeBytes: Int64?
    /// For a GGUF, the SHA-256 of the `.gguf` file; for a folder, the digest
    /// `CustomModelDigest.folderDigest` computes. Optional: a model without
    /// one is imported but shown as unverified.
    var sha256: String?
    /// Where the model came from, shown in the picker.
    var source: String?
    var license: String?
    /// sherpa-onnx recognizer settings; required for `sherpaOnnx`.
    var sherpa: SherpaConfiguration?
    /// GGUF file name inside the folder; required for `cleanup`.
    var gguf: String?
    /// Context window for a GGUF, in tokens. Defaults to 4,096.
    var contextTokens: Int?

    init(
        id: String, name: String, engine: CustomModelEngine, languages: [String] = [],
        fileSizeBytes: Int64? = nil, sha256: String? = nil, source: String? = nil, license: String? = nil,
        sherpa: SherpaConfiguration? = nil, gguf: String? = nil, contextTokens: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.languages = languages
        self.fileSizeBytes = fileSizeBytes
        self.sha256 = sha256
        self.source = source
        self.license = license
        self.sherpa = sherpa
        self.gguf = gguf
        self.contextTokens = contextTokens
    }

    enum CodingKeys: String, CodingKey {
        case id, name, engine, languages, fileSizeBytes, sha256, source, license, sherpa, gguf, contextTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        engine = try container.decode(CustomModelEngine.self, forKey: .engine)
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? []
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        license = try container.decodeIfPresent(String.self, forKey: .license)
        sherpa = try container.decodeIfPresent(SherpaConfiguration.self, forKey: .sherpa)
        gguf = try container.decodeIfPresent(String.self, forKey: .gguf)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
    }

    static let fileName = "vocamodel.json"

    /// Files a WhisperKit model folder must hold.
    static let whisperKitComponents = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    static let whisperKitTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    // MARK: - sherpa-onnx

    /// How sherpa-onnx should build the recognizer, with file names relative
    /// to the model folder.
    struct SherpaConfiguration: Codable, Equatable, Sendable {
        /// `moonshine`, `senseVoice`, `nemoCtc`, `canary`, or `qwen3Asr`.
        var type: String
        var model: String?
        var encoder: String?
        var decoder: String?
        var mergedDecoder: String?
        var convFrontend: String?
        var tokenizer: String?
        /// Languages a Canary model can be told to transcribe.
        var languages: [String]?

        init(
            type: String, model: String? = nil, encoder: String? = nil, decoder: String? = nil,
            mergedDecoder: String? = nil, convFrontend: String? = nil, tokenizer: String? = nil,
            languages: [String]? = nil
        ) {
            self.type = type
            self.model = model
            self.encoder = encoder
            self.decoder = decoder
            self.mergedDecoder = mergedDecoder
            self.convFrontend = convFrontend
            self.tokenizer = tokenizer
            self.languages = languages
        }

        /// The catalog's recognizer kind, or nil when a field it needs is missing.
        var kind: SherpaModelSpec.Kind? {
            switch type {
            case "moonshine":
                guard let encoder, let mergedDecoder else { return nil }
                return .moonshine(encoder: encoder, mergedDecoder: mergedDecoder)
            case "senseVoice":
                return model.map { .senseVoice(model: $0) }
            case "nemoCtc":
                return model.map { .nemoCtc(model: $0) }
            case "canary":
                guard let encoder, let decoder else { return nil }
                return .canary(encoder: encoder, decoder: decoder, supportedLanguages: Set(languages ?? ["en"]))
            case "qwen3Asr":
                guard let convFrontend, let encoder, let decoder, let tokenizer else { return nil }
                return .qwen3Asr(convFrontend: convFrontend, encoder: encoder, decoder: decoder, tokenizer: tokenizer)
            default:
                return nil
            }
        }

        static let knownTypes = ["moonshine", "senseVoice", "nemoCtc", "canary", "qwen3Asr"]
    }

    // MARK: - Validation

    /// Whether `id` can name a model: short, lowercase, filesystem-safe, and
    /// not the id of a built-in model (a slot would then mean two models).
    static func isValidID(_ id: String) -> Bool {
        guard (2...63).contains(id.count),
              let first = id.unicodeScalars.first,
              CharacterSet.lowercaseLetters.contains(first) || CharacterSet.decimalDigits.contains(first) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        guard id.unicodeScalars.allSatisfy(allowed.contains), !id.contains("..") else { return false }
        return ModelSize(rawValue: id) == nil && CleanupModelKind(rawValue: id) == nil
    }

    /// Every reason the model in `directory` can't be used, in reading
    /// order. Empty when it can. Checks the manifest and the files, not the
    /// checksum (`CustomModelDigest` does that, as it reads every byte).
    func problems(in directory: URL, fileManager: FileManager = .default) -> [String] {
        var problems: [String] = []
        if !Self.isValidID(id) {
            problems.append("The id “\(id)” must be 2 to 63 lowercase letters, digits, dots, dashes or underscores, and not a built-in model's id.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("The name is empty.")
        }
        if let sha256, !Self.isHexDigest(sha256) {
            problems.append("sha256 must be 64 hexadecimal characters.")
        }

        func missing(_ relative: String) -> Bool {
            !fileManager.fileExists(atPath: directory.appendingPathComponent(relative).path)
        }

        switch engine {
        case .whisperKit:
            for component in Self.whisperKitComponents
            where !ModelManager.hasUsableCoreMLComponent(at: directory.appendingPathComponent(component), fileManager: fileManager) {
                problems.append("\(component) is missing or incomplete.")
            }
            for file in Self.whisperKitTokenizerFiles where missing(file) {
                problems.append("\(file) is missing; WhisperKit needs the tokenizer next to the model.")
            }
        case .sherpaOnnx:
            guard let sherpa else {
                problems.append("A sherpa-onnx model needs a “sherpa” section naming its type and files.")
                break
            }
            // Every file the engine opens must be inside the model's folder.
            let names = [sherpa.model, sherpa.encoder, sherpa.decoder, sherpa.mergedDecoder,
                         sherpa.convFrontend, sherpa.tokenizer].compactMap { $0 }
            let outside = names.filter { !Self.isInsideFolder($0) }
            guard outside.isEmpty else {
                for name in outside { problems.append("“\(name)” must name a file inside the model's folder.") }
                break
            }
            guard let kind = sherpa.kind else {
                let types = SherpaConfiguration.knownTypes.joined(separator: ", ")
                problems.append("The sherpa type “\(sherpa.type)” is unknown or is missing a file name. Known types: \(types).")
                break
            }
            let required = SherpaModelSpec.requiredFiles(for: kind)
            for file in required where missing(file) {
                problems.append("\(file) is missing.")
            }
        case .cleanup:
            guard let gguf, !gguf.isEmpty, !gguf.contains("/") else {
                problems.append("A Writing AI model needs “gguf”, the .gguf file's name in the folder.")
                break
            }
            let url = directory.appendingPathComponent(gguf)
            guard !missing(gguf) else {
                problems.append("\(gguf) is missing.")
                break
            }
            do {
                let architecture = try GGUFMetadata.read(fileAt: url).architecture
                if !GGUFMetadata.isCleanupArchitectureAllowed(architecture) {
                    problems.append(Self.architectureProblem(architecture))
                }
            } catch {
                problems.append("\(gguf) is not a readable GGUF file: \(error.localizedDescription)")
            }
            if let contextTokens, !(512...131_072).contains(contextTokens) {
                problems.append("contextTokens must be between 512 and 131072.")
            }
        }
        return problems
    }

    /// Why a GGUF architecture is refused (AGENTS.md → Dependencies).
    static func architectureProblem(_ architecture: String?) -> String {
        guard let architecture else {
            return "The GGUF does not say its architecture (general.architecture), so VocaMac can't tell whether it is safe to load."
        }
        return "The GGUF architecture “\(architecture)” is a hybrid attention/recurrent design. VocaMac reuses the model's "
            + "cache between dictations, which those models can't do: they return empty text after the first one."
    }

    /// A relative path that stays inside the folder: not absolute, no
    /// "~", and no ".." component.
    static func isInsideFolder(_ relative: String) -> Bool {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return false }
        return !trimmed.split(separator: "/").contains("..")
    }

    static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

extension SherpaModelSpec {
    /// The files a recognizer of `kind` reads, for a spec not built yet.
    static func requiredFiles(for kind: Kind) -> [String] {
        SherpaModelSpec(
            size: .customSherpaOnnx, archiveURL: URL(fileURLWithPath: "/"), directoryName: "",
            sha256: "", kind: kind
        ).requiredFiles
    }
}
