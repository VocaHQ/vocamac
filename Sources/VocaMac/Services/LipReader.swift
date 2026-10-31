// LipReader.swift
// VocaMac
//
// Reads mouthed English from mouth crops: Auto-AVSR's visual speech
// recognition model (LRS3_V_WER19.1, encoder and CTC head) converted to
// Core ML, decoded greedily. English only: the model was trained on English
// TED talks and knows no other language.
//
// The model isn't bundled or downloaded: its weights carry the training
// data's research and non-commercial terms. It is built on this Mac with
// `scripts/convert-lip-reading-model.sh` (or imported) into
// ~/Library/Application Support/VocaMac/models/lip-reading/.
//
// The Core ML model accepts a fixed set of lengths (every 10 frames, 0.4 s,
// up to 30 s). `LipReadingWindow` widens each stretch of speech to one of
// them with real camera frames from around it, and splits longer speech.

import CoreML
import Foundation

// MARK: - Protocol

protocol LipReading: AnyObject, Sendable {
    /// The model is on this Mac.
    var isInstalled: Bool { get }
    /// Load the model ahead of the first read (it takes a few seconds).
    func prepare() async
    /// The words in `crops`: 25 frames a second, one of the model's lengths.
    func read(_ crops: [MouthCrop]) async throws -> String
    /// The length the model reads `frames` frames as: the next one it accepts.
    func modelLength(for frames: Int) -> Int
    /// Free the loaded model.
    func unload()
}

extension LipReading {
    func modelLength(for frames: Int) -> Int { LipReadingWindow.modelLength(for: frames) }
}

enum LipReadingError: LocalizedError {
    case notInstalled
    case modelFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "The lip-reading model isn't installed. See Settings › Silent Mode."
        case .modelFailed(let detail): return "Lip reading failed: \(detail)"
        }
    }
}

// MARK: - Windows

enum LipReadingWindow {
    /// The model's frame rate.
    static let fps = 25.0
    /// The lengths `scripts/convert-lip-reading-model.py` builds the model
    /// for: fine steps for short stretches, where a few copied frames would
    /// matter, coarser ones for long ones. Core ML allows 128 at most.
    static let lengths: [Int] = Array(stride(from: 8, to: 60, by: 2)) + Array(stride(from: 60, to: 200, by: 4))
        + Array(stride(from: 200, to: 400, by: 8)) + Array(stride(from: 400, through: 750, by: 10))
    static var minimumFrames: Int { lengths.first ?? 8 }
    static var maximumFrames: Int { lengths.last ?? 750 }

    /// The model length for `frames` frames: the shortest of `lengths` that holds them.
    static func modelLength(for frames: Int, lengths: [Int] = LipReadingWindow.lengths) -> Int {
        lengths.first { $0 >= frames } ?? lengths.last ?? frames
    }

    /// Stretches of speech, joined while they fit in one read and split
    /// when one alone is too long. Seconds on the frames' clock.
    static func chunks(_ speaking: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
        let longest = Double(maximumFrames) / fps - 0.4
        var result: [ClosedRange<TimeInterval>] = []
        for span in ArticulationDetector.merged(speaking) {
            var start = span.lowerBound
            while span.upperBound - start > longest {
                result.append(start...(start + longest))
                start += longest
            }
            let piece = start...span.upperBound
            if let last = result.last, piece.upperBound - last.lowerBound <= longest {
                result[result.count - 1] = last.lowerBound...piece.upperBound
            } else {
                result.append(piece)
            }
        }
        return result
    }

    /// The 25 fps frame times to read for `span`, widened to a model length
    /// evenly on both sides, and kept inside `available` where it allows.
    static func frameTimes(
        for span: ClosedRange<TimeInterval>, available: ClosedRange<TimeInterval>,
        length lengthFor: (Int) -> Int = { LipReadingWindow.modelLength(for: $0) }
    ) -> [TimeInterval] {
        let frames = max(1, Int(((span.upperBound - span.lowerBound) * fps).rounded()))
        let length = lengthFor(frames)
        let duration = Double(length - 1) / fps
        var start = (span.lowerBound + span.upperBound) / 2 - duration / 2
        // Slide into the recorded frames rather than repeat an edge frame.
        if start + duration > available.upperBound { start = available.upperBound - duration }
        if start < available.lowerBound { start = available.lowerBound }
        return (0..<length).map { start + Double($0) / fps }
    }

    /// The crop nearest each time. `crops` must be in time order.
    static func crops(at times: [TimeInterval], from crops: [MouthCrop]) -> [MouthCrop] {
        guard !crops.isEmpty else { return [] }
        var index = 0
        return times.map { time in
            while index + 1 < crops.count, abs(crops[index + 1].time - time) <= abs(crops[index].time - time) {
                index += 1
            }
            var crop = crops[index]
            crop.time = time
            return crop
        }
    }
}

// MARK: - Lighting

/// Lifts a dark or flat clip into the brightness and contrast range of the
/// model's training video. Laptop cameras in a dim room give clips darker
/// and flatter than any TED talk; well-lit clips are left as they are.
///
/// On 60 LRS3 test clips (greedy decoding): darkened clips went from 35.8%
/// to 33.7% of words wrong, darkened and flattened from 37.7% to 33.3%;
/// clips as recorded stayed at 31%.
enum LipLighting {
    /// The 5th percentiles of LRS3 test clips' mean brightness and its
    /// standard deviation, in 0…255.
    static let minimumMean: Float = 48.6
    static let minimumDeviation: Float = 20.4

    /// The mean and standard deviation of every pixel in `crops`.
    static func statistics(_ crops: [MouthCrop]) -> (mean: Float, deviation: Float) {
        var sum: Double = 0, squares: Double = 0, count: Double = 0
        for crop in crops {
            for value in crop.pixels {
                let v = Double(value)
                sum += v; squares += v * v; count += 1
            }
        }
        guard count > 0 else { return (0, 0) }
        let mean = sum / count
        return (Float(mean), Float(max(squares / count - mean * mean, 0).squareRoot()))
    }

    /// `crops` with brightness and contrast raised to the minimums where
    /// they fall short; unchanged otherwise.
    static func adjusted(_ crops: [MouthCrop]) -> [MouthCrop] {
        let (mean, deviation) = statistics(crops)
        let targetMean = max(mean, minimumMean), targetDeviation = max(deviation, minimumDeviation)
        guard targetMean != mean || targetDeviation != deviation, deviation > 0.5 else { return crops }
        let scale = targetDeviation / deviation
        return crops.map { crop in
            var adjusted = crop
            adjusted.pixels = crop.pixels.map { value in
                UInt8(max(0, min(255, ((Float(value) - mean) * scale + targetMean).rounded())))
            }
            return adjusted
        }
    }
}

// MARK: - Decoding

enum CTCGreedyDecoder {
    /// The text for per-frame best token ids: repeats collapsed, the blank
    /// (first) and end (last) tokens dropped, SentencePiece's "▁" read as a
    /// word start. Lowercased: the model writes capitals.
    static func decode(bestTokens: [Int], tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "" }
        var pieces: [String] = []
        var previous: Int?
        for id in bestTokens {
            defer { previous = id }
            guard id != previous, id != 0, id != tokens.count - 1, tokens.indices.contains(id) else { continue }
            pieces.append(tokens[id])
        }
        return pieces.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}

// MARK: - Core ML

/// `@unchecked Sendable`: the loaded models, tokens and lengths are guarded
/// by `lock`; predictions run one at a time on `queue`.
final class CoreMLLipReader: LipReading, @unchecked Sendable {
    static let encoderName = "LipReader"
    static let decoderName = "LipDecoder"

    /// ~/Library/Application Support/VocaMac/models/lip-reading/
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VocaMac", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("lip-reading", isDirectory: true)
    }

    let directory: URL?
    var beamSearch = LipBeamSearch.Configuration()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.vocamac.lipreading", qos: .userInitiated)
    private var loaded: LoadedModels?

    /// The encoder, the decoder when installed, the tokens, and the lengths
    /// the encoder accepts.
    private struct LoadedModels {
        var encoder: MLModel
        var decoder: MLModel?
        var tokens: [String]
        var lengths: [Int]
    }

    init(directory: URL? = CoreMLLipReader.defaultDirectory) {
        self.directory = directory
    }

    private func url(_ name: String, _ suffix: String) -> URL? {
        directory?.appendingPathComponent("\(name).\(suffix)", isDirectory: true)
    }

    private func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private var tokensURL: URL? { directory?.appendingPathComponent("tokens.json") }

    var isInstalled: Bool {
        exists(tokensURL) && (exists(url(Self.encoderName, "mlmodelc")) || exists(url(Self.encoderName, "mlpackage")))
    }

    /// The decoder is installed (models built before it read greedily).
    var hasDecoder: Bool {
        exists(url(Self.decoderName, "mlmodelc")) || exists(url(Self.decoderName, "mlpackage"))
    }

    func prepare() async {
        _ = try? await loadedModels()
    }

    func modelLength(for frames: Int) -> Int {
        let lengths = lock.withLock { loaded?.lengths } ?? LipReadingWindow.lengths
        return LipReadingWindow.modelLength(for: frames, lengths: lengths)
    }

    func read(_ crops: [MouthCrop]) async throws -> String {
        let models = try await loadedModels()
        let crops = LipLighting.adjusted(crops)
        let length = crops.count
        guard length >= (models.lengths.first ?? 1) else { return "" }
        let size = MouthCropGeometry.cropSize
        let search = beamSearch
        // MLModel isn't Sendable; this read is its only user on `queue`.
        let box = UncheckedSendableBox(models)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let models = box.value
                    let input = try MLMultiArray(shape: [1, 1, NSNumber(value: length), NSNumber(value: size), NSNumber(value: size)], dataType: .float32)
                    let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
                    let frameSize = size * size
                    for (frame, crop) in crops.enumerated() {
                        for (index, value) in crop.pixels.prefix(frameSize).enumerated() {
                            pointer[frame * frameSize + index] = (Float(value) / 255 - 0.421) / 0.165
                        }
                    }
                    let output = try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["video": input]))
                    guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue else {
                        throw LipReadingError.modelFailed("no output")
                    }
                    let ctc = Self.scores(logProbs)
                    let tokenIDs: [Int]
                    if let decoder = models.decoder, let memory = output.featureValue(for: "encoder_out")?.multiArrayValue {
                        tokenIDs = try LipBeamSearch.decode(ctc: ctc, configuration: search) { prefixes, position in
                            try Self.decoderStep(decoder, prefixes: prefixes, memory: memory, position: position, configuration: search)
                        }
                        continuation.resume(returning: Self.text(tokenIDs, tokens: models.tokens))
                    } else {
                        continuation.resume(returning: CTCGreedyDecoder.decode(bestTokens: Self.bestTokens(ctc), tokens: models.tokens))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Token ids as text: SentencePiece's "▁" read as a word start, lowercased.
    static func text(_ ids: [Int], tokens: [String]) -> String {
        ids.compactMap { tokens.indices.contains($0) ? tokens[$0] : nil }
            .joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }

    /// A [1, T, V] output as a row-major table.
    static func scores(_ array: MLMultiArray) -> LipBeamSearch.CTCScores {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let frames = shape.count == 3 ? shape[1] : 0
        let vocabulary = shape.count == 3 ? shape[2] : 0
        var values = [Float](repeating: 0, count: frames * vocabulary)
        func copy(_ value: (Int) -> Float) {
            for frame in 0..<frames {
                for token in 0..<vocabulary {
                    values[frame * vocabulary + token] = value(frame * strides[1] + token * strides[2])
                }
            }
        }
        switch array.dataType {
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: array.count)
            copy { Float(pointer[$0]) }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            copy { Float(pointer[$0]) }
        default:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            copy { pointer[$0] }
        }
        return LipBeamSearch.CTCScores(frames: frames, vocabulary: vocabulary, values: values)
    }

    /// The highest-scoring token in each frame.
    static func bestTokens(_ scores: LipBeamSearch.CTCScores) -> [Int] {
        (0..<scores.frames).map { frame in
            var best = 0
            var bestValue = -Float.infinity
            for token in 0..<scores.vocabulary where scores.at(frame, token) > bestValue {
                bestValue = scores.at(frame, token)
                best = token
            }
            return best
        }
    }

    /// One decoder call: `prefixes` padded to the decoder's fixed shape.
    private static func decoderStep(
        _ decoder: MLModel, prefixes: [[Int]], memory: MLMultiArray, position: Int,
        configuration: LipBeamSearch.Configuration
    ) throws -> [[Float]] {
        let rows = configuration.beamWidth, columns = configuration.maximumLength
        let tokens = try MLMultiArray(shape: [NSNumber(value: rows), NSNumber(value: columns)], dataType: .int32)
        let end = Int32(clamping: (prefixes.first?.first ?? 0))
        let pointer = tokens.dataPointer.bindMemory(to: Int32.self, capacity: tokens.count)
        for index in 0..<(rows * columns) { pointer[index] = end }
        for (row, prefix) in prefixes.prefix(rows).enumerated() {
            for (column, token) in prefix.prefix(columns).enumerated() {
                pointer[row * columns + column] = Int32(clamping: token)
            }
        }
        let positionArray = try MLMultiArray(shape: [1], dataType: .int32)
        positionArray[0] = NSNumber(value: position)
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "tokens": tokens, "memory": memory, "position": positionArray,
        ]))
        guard let logProbs = output.featureValue(for: "log_probs")?.multiArrayValue else {
            throw LipReadingError.modelFailed("no decoder output")
        }
        let shape = logProbs.shape.map(\.intValue)
        let strides = logProbs.strides.map(\.intValue)
        guard shape.count == 2 else { throw LipReadingError.modelFailed("unexpected decoder output") }
        let values = logProbs.dataPointer.bindMemory(to: Float.self, capacity: logProbs.count)
        return (0..<shape[0]).map { row in
            (0..<shape[1]).map { values[row * strides[0] + $0 * strides[1]] }
        }
    }

    // MARK: Loading

    private func loadedModels() async throws -> LoadedModels {
        if let loaded = lock.withLock({ loaded }) { return loaded }
        guard isInstalled, let tokensURL else { throw LipReadingError.notInstalled }
        let started = ProcessInfo.processInfo.systemUptime
        let configuration = MLModelConfiguration()
        // CPU-only and the Neural Engine fail on all but the default length
        // with this export; the GPU runs every length.
        configuration.computeUnits = .cpuAndGPU
        let encoder = try MLModel(contentsOf: try await compiled(Self.encoderName), configuration: configuration)
        let decoder = hasDecoder ? try MLModel(contentsOf: try await compiled(Self.decoderName), configuration: configuration) : nil
        let tokens = try JSONDecoder().decode([String].self, from: Data(contentsOf: tokensURL))
        let shapes = encoder.modelDescription.inputDescriptionsByName["video"]?.multiArrayConstraint?.shapeConstraint.enumeratedShapes ?? []
        let lengths = shapes.compactMap { $0.count == 5 ? $0[2].intValue : nil }.sorted()
        let models = LoadedModels(encoder: encoder, decoder: decoder, tokens: tokens, lengths: lengths.isEmpty ? LipReadingWindow.lengths : lengths)
        lock.withLock { loaded = models }
        VocaLogger.info(.silentMode, String(
            format: "Lip-reading model loaded in %.1fs (%d tokens, %d lengths, %@)",
            ProcessInfo.processInfo.systemUptime - started, tokens.count, models.lengths.count,
            decoder == nil ? "greedy decoding" : "beam search"
        ))
        return models
    }

    /// The compiled model, compiling an imported or freshly converted package once.
    private func compiled(_ name: String) async throws -> URL {
        guard let compiledURL = url(name, "mlmodelc"), let packageURL = url(name, "mlpackage") else {
            throw LipReadingError.notInstalled
        }
        if FileManager.default.fileExists(atPath: compiledURL.path) { return compiledURL }
        let compiled = try await MLModel.compileModel(at: packageURL)
        try? FileManager.default.removeItem(at: compiledURL)
        try FileManager.default.moveItem(at: compiled, to: compiledURL)
        return compiledURL
    }

    /// Drop the loaded models (about 1 GB together).
    func unload() {
        lock.withLock { loaded = nil }
    }

    /// Copy a model folder (LipReader and optionally LipDecoder, as
    /// .mlpackage or .mlmodelc, and tokens.json) into place, replacing what is there.
    func install(from folder: URL) throws {
        guard let directory else { throw LipReadingError.notInstalled }
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let models = [Self.encoderName, Self.decoderName].flatMap { ["\($0).mlmodelc", "\($0).mlpackage"] }
        guard names.contains("tokens.json"), names.contains(where: { $0.hasPrefix(Self.encoderName + ".") && models.contains($0) }) else {
            throw LipReadingError.modelFailed("the folder needs \(Self.encoderName).mlpackage and tokens.json")
        }
        unload()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in models + ["tokens.json"] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        for name in names where models.contains(name) || name == "tokens.json" {
            try fileManager.copyItem(at: folder.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
    }

    /// Remove the model from this Mac.
    func remove() throws {
        unload()
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }
}

/// Stands in where no model may be read (tests, headless runs).
final class UnavailableLipReader: LipReading {
    var isInstalled: Bool { false }
    func prepare() async {}
    func read(_ crops: [MouthCrop]) async throws -> String { throw LipReadingError.notInstalled }
    func unload() {}
}
