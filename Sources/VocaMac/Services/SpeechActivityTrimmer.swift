// SpeechActivityTrimmer.swift
// VocaMac
//
// Removes silence from a recording before it reaches the speech model.
//
// A voice activity detector (Silero, via FluidAudio) marks where speech is.
// Leading and trailing silence is dropped and long pauses are shortened, so
// the model decodes less audio and has no empty stretch to hallucinate over
// (Whisper's "Thank you." on a silent clip). A recording with no speech at
// all is never decoded.
//
// Trimming is best effort: until the VAD model has downloaded, or if it
// fails, the recording is decoded as recorded.

import Foundation
import FluidAudio

// MARK: - Plan (pure)

enum SpeechActivityTrimmer {

    static let sampleRate = 16_000

    /// Silence kept before and after each stretch of speech, so a soft first
    /// consonant or trailing word is not clipped.
    static let speechPadding: TimeInterval = 0.2

    /// Longest pause kept between two stretches of speech. Long enough for a
    /// model to hear a sentence boundary, short enough to skip dead air.
    static let maximumPause: TimeInterval = 0.4

    /// Below this peak speech probability the recording is silence.
    static let noSpeechProbability: Float = 0.15

    /// Trimming that saves less than this share of the audio is not worth
    /// changing what the model hears.
    static let minimumSavings = 0.1

    enum Decision: Equatable {
        /// Decode these sample ranges, in order, joined by short pauses.
        case trim([Range<Int>])
        /// Decode the recording as recorded.
        case keep
        /// Nothing was said; skip the decode.
        case noSpeech
    }

    /// Decide what to decode from the detector's speech ranges.
    ///
    /// - Parameters:
    ///   - speech: Padded speech ranges in samples, in order.
    ///   - peakProbability: Highest speech probability over the recording.
    ///   - totalSamples: Length of the recording.
    static func decide(speech: [Range<Int>], peakProbability: Float, totalSamples: Int) -> Decision {
        guard totalSamples > 0 else { return .noSpeech }
        let ranges = speech
            .map { max(0, $0.lowerBound)..<min(totalSamples, $0.upperBound) }
            .filter { !$0.isEmpty }
        guard !ranges.isEmpty else {
            // Unsure (quiet or whispered speech): let the model decide.
            return peakProbability < noSpeechProbability ? .noSpeech : .keep
        }
        let kept = assembledLength(ranges)
        guard Double(totalSamples - kept) >= Double(totalSamples) * minimumSavings else { return .keep }
        return .trim(ranges)
    }

    /// Join speech ranges, keeping at most `maximumPause` of each gap.
    static func apply(_ ranges: [Range<Int>], to samples: [Float]) -> [Float] {
        let pause = Int(maximumPause * Double(sampleRate))
        var output: [Float] = []
        output.reserveCapacity(assembledLength(ranges))
        var previousEnd: Int?
        for range in ranges {
            let lower = max(range.lowerBound, previousEnd ?? 0)
            guard lower < range.upperBound, range.upperBound <= samples.count else { continue }
            if let previousEnd, lower > previousEnd {
                let gap = lower - previousEnd
                if gap <= pause {
                    output.append(contentsOf: samples[previousEnd..<lower])
                } else {
                    // Keep the edges of the pause: the tail of one word and
                    // the breath before the next.
                    let half = pause / 2
                    output.append(contentsOf: samples[previousEnd..<(previousEnd + half)])
                    output.append(contentsOf: samples[(lower - (pause - half))..<lower])
                }
            }
            output.append(contentsOf: samples[lower..<range.upperBound])
            previousEnd = range.upperBound
        }
        return output
    }

    /// Samples `apply` will return for these ranges.
    static func assembledLength(_ ranges: [Range<Int>]) -> Int {
        let pause = Int(maximumPause * Double(sampleRate))
        var total = 0
        var previousEnd: Int?
        for range in ranges {
            let lower = max(range.lowerBound, previousEnd ?? 0)
            guard lower < range.upperBound else { continue }
            if let previousEnd, lower > previousEnd { total += min(lower - previousEnd, pause) }
            total += range.upperBound - lower
            previousEnd = range.upperBound
        }
        return total
    }
}

// MARK: - CoreMLModelCache

enum CoreMLModelCache {

    /// Whether every compiled model in `directory` has its program. A bundle
    /// missing `model.mil` (an interrupted download) makes CoreML crash with
    /// a null program instead of throwing.
    static func isComplete(_ directory: URL) -> Bool {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return false
        }
        let bundles = entries.filter { $0.pathExtension == "mlmodelc" }
        guard !bundles.isEmpty else { return false }
        return bundles.allSatisfy { bundle in
            manager.fileExists(atPath: bundle.appendingPathComponent("coremldata.bin").path)
                && (manager.fileExists(atPath: bundle.appendingPathComponent("model.mil").path)
                    || manager.fileExists(atPath: bundle.appendingPathComponent("model.espresso.net").path))
        }
    }

    /// Delete a cached model directory that exists but is incomplete.
    static func removeIfIncomplete(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path), !isComplete(directory) else { return }
        VocaLogger.warning(.general, "Removing incomplete model cache at \(directory.lastPathComponent)")
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - VoiceActivityDetector

/// Runs Silero VAD over a recording. The ~2 MB model downloads into
/// FluidAudio's cache on first use.
actor VoiceActivityDetector {

    /// Silero's usual speech threshold; FluidAudio's 0.85 default is tuned
    /// for segmentation of long audio and misses soft dictation.
    static let speechThreshold: Float = 0.5

    /// Recordings longer than this skip the VAD pass: a long file is not a
    /// dictation, and the pass would add seconds for little gain.
    static let maximumSeconds: TimeInterval = 600

    private var manager: VadManager?
    private var isLoading = false
    /// Bumped by `unload()`, so a load that finishes afterwards is dropped.
    private var generation = 0

    /// FluidAudio's cache for the Silero model.
    static var modelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/silero-vad", isDirectory: true)
    }

    /// Start loading (and, the first time, downloading) the model.
    func prepare() {
        guard manager == nil, !isLoading else { return }
        isLoading = true
        // An interrupted download leaves a bundle CoreML crashes on rather
        // than rejecting; remove it so FluidAudio downloads it again.
        CoreMLModelCache.removeIfIncomplete(Self.modelDirectory)
        let generation = generation
        Task {
            do {
                let manager = try await VadManager(config: VadConfig(defaultThreshold: Self.speechThreshold))
                self.finishLoading(manager, generation: generation)
            } catch {
                VocaLogger.warning(.general, "Voice activity detection unavailable: \(error.localizedDescription)")
                self.finishLoading(nil, generation: generation)
            }
        }
    }

    private func finishLoading(_ manager: VadManager?, generation: Int) {
        guard generation == self.generation else { return }
        isLoading = false
        self.manager = manager
    }

    var isLoaded: Bool { manager != nil }

    /// Release the model with the speech engine; the next decode reloads it.
    func unload() {
        generation &+= 1
        isLoading = false
        manager = nil
    }

    /// What to decode from `samples`. Returns `.keep` whenever the detector
    /// is not ready yet, so trimming never waits on a download.
    func decision(for samples: [Float]) async -> SpeechActivityTrimmer.Decision {
        guard Double(samples.count) / Double(SpeechActivityTrimmer.sampleRate) <= Self.maximumSeconds else {
            return .keep
        }
        guard let manager else {
            prepare()
            return .keep
        }
        do {
            let results = try await manager.process(samples)
            let segments = await manager.segmentSpeech(
                from: results,
                totalSamples: samples.count,
                config: VadSegmentationConfig(
                    minSpeechDuration: 0.25,
                    minSilenceDuration: 0.3,
                    maxSpeechDuration: 3_600,
                    speechPadding: SpeechActivityTrimmer.speechPadding
                )
            )
            let ranges = segments.map {
                $0.startSample(sampleRate: SpeechActivityTrimmer.sampleRate)
                    ..< $0.endSample(sampleRate: SpeechActivityTrimmer.sampleRate)
            }
            let peak = results.map(\.probability).max() ?? 0
            return SpeechActivityTrimmer.decide(speech: ranges, peakProbability: peak, totalSamples: samples.count)
        } catch {
            VocaLogger.warning(.general, "Voice activity detection failed: \(error.localizedDescription)")
            return .keep
        }
    }
}
