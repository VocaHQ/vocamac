// VoiceActivityStream.swift
// VocaMac
//
// Runs the silence detector over a recording while it is being made, so the
// pass at stop (`VoiceActivityDetector.decision`) covers only its last
// fraction of a second instead of the whole recording.

import Foundation
import FluidAudio
import os

/// Silero probabilities for a recording, computed while the user speaks.
///
/// The recording is cut into the same 4,096-sample chunks, from the same
/// first sample, with the same model state carried from one to the next, as
/// the batch pass (`VadManager.process`). Its probabilities, and so the trim
/// decided from them, are therefore the same; the batch pass only runs on
/// what is left at stop. Each processed chunk is fingerprinted, and a stop
/// whose audio does not match (a recording cut short, a different start)
/// falls back to the batch pass over the whole recording.
///
/// Unchecked: everything mutable is in `state`, an unfair lock. `append` is
/// called on Core Audio's render thread and only copies samples under that
/// lock; the model runs on `worker`, never on the render thread.
final class VoiceActivityStream: @unchecked Sendable {

    static let chunkSize = VadManager.chunkSize

    /// Probabilities for the start of a recording, and where the batch pass
    /// picks up.
    struct Progress: Sendable {
        /// One result per full chunk processed, from sample zero.
        var results: [VadResult]
        /// Fingerprint of each processed chunk's samples.
        var chunkHashes: [UInt64]
        /// Model state after the last processed chunk.
        var streamState: VadStreamState
        var manager: VadManager

        /// Samples the results cover.
        var processedSamples: Int { results.count * VoiceActivityStream.chunkSize }
    }

    private struct State {
        /// Received and not yet processed; always shorter than a few chunks.
        var pending: [Float] = []
        var receivedSamples = 0
        var results: [VadResult] = []
        var chunkHashes: [UInt64] = []
        var streamState = VadStreamState.initial()
        var manager: VadManager?
        /// False once audio went missing or the model failed: the batch pass
        /// runs over the whole recording.
        var isUsable = true
        var inputEnded = false
    }

    private let state: OSAllocatedUnfairLock<State>
    private let wake: AsyncStream<Void>.Continuation
    private let worker: Task<Void, Never>

    /// Longest recording followed; `VoiceActivityDetector` skips longer ones.
    static let maximumSamples = Int(VoiceActivityDetector.maximumSeconds) * SpeechActivityTrimmer.sampleRate

    /// - Parameter manager: The loaded detector, or nil when it is not ready,
    ///   in which case the stream does nothing and the stop runs the batch pass.
    init(manager: @escaping @Sendable () async -> VadManager?) {
        let (signals, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        let state = OSAllocatedUnfairLock(initialState: State())
        self.state = state
        worker = Task.detached(priority: .utility) {
            guard let manager = await manager() else {
                state.withLock { $0.isUsable = false }
                return
            }
            state.withLock { $0.manager = manager }
            for await _ in signals {
                while let chunk = Self.nextChunk(from: state) {
                    let streamState = state.withLock { $0.streamState }
                    do {
                        let result = try await manager.processStreamingChunk(chunk, state: streamState)
                        let vadResult = VadResult(
                            probability: result.probability,
                            isVoiceActive: result.probability >= VoiceActivityDetector.speechThreshold,
                            processingTime: 0,
                            outputState: result.state.modelState
                        )
                        let hash = Self.fingerprint(chunk[...])
                        state.withLock {
                            $0.results.append(vadResult)
                            $0.chunkHashes.append(hash)
                            $0.streamState = result.state
                        }
                    } catch {
                        VocaLogger.debug(.general, "Voice activity while recording stopped: \(error.localizedDescription)")
                        state.withLock { $0.isUsable = false }
                        return
                    }
                }
            }
        }
    }

    deinit {
        wake.finish()
        worker.cancel()
    }

    /// Take the next full chunk to process, if one has arrived.
    private static func nextChunk(from state: OSAllocatedUnfairLock<State>) -> [Float]? {
        state.withLock { state in
            guard state.isUsable, state.pending.count >= chunkSize else { return nil }
            let chunk = Array(state.pending.prefix(chunkSize))
            state.pending.removeFirst(chunkSize)
            return chunk
        }
    }

    /// Feed samples captured at `offset` in the recording. A gap or overlap
    /// stops the stream; the stop then runs the batch pass.
    func append(_ samples: [Float], at offset: Int) {
        guard !samples.isEmpty else { return }
        let shouldWake = state.withLock { state -> Bool in
            guard state.isUsable, !state.inputEnded else { return false }
            guard offset == state.receivedSamples,
                  state.receivedSamples + samples.count <= Self.maximumSamples else {
                state.isUsable = false
                state.pending = []
                return false
            }
            state.receivedSamples += samples.count
            state.pending.append(contentsOf: samples)
            return state.pending.count >= Self.chunkSize
        }
        if shouldWake { wake.yield() }
    }

    /// End the input and wait for the chunks already received to be
    /// processed. Nil when the stream cannot stand in for the batch pass.
    func finish() async -> Progress? {
        state.withLock { $0.inputEnded = true }
        wake.finish()
        await worker.value
        return state.withLock { state in
            guard state.isUsable, let manager = state.manager else { return nil }
            return Progress(
                results: state.results, chunkHashes: state.chunkHashes,
                streamState: state.streamState, manager: manager
            )
        }
    }

    /// Stop following the recording; nothing will read it.
    func cancel() {
        state.withLock { $0.isUsable = false }
        wake.finish()
        worker.cancel()
    }

    /// FNV-1a over the samples' bit patterns: enough to tell whether the
    /// audio decoded at stop is the audio processed while recording.
    static func fingerprint(_ samples: ArraySlice<Float>) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in samples {
            hash ^= UInt64(sample.bitPattern)
            hash &*= 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Whether the processed chunks are the start of `samples`.
    static func matches(_ progress: Progress, samples: [Float]) -> Bool {
        progress.chunkHashes.count == progress.results.count
            && matches(chunkHashes: progress.chunkHashes, samples: samples)
    }

    /// Whether chunks with these fingerprints, from sample zero, are the
    /// start of `samples`.
    static func matches(chunkHashes: [UInt64], samples: [Float]) -> Bool {
        guard chunkHashes.count * chunkSize <= samples.count else { return false }
        for (index, hash) in chunkHashes.enumerated() {
            let start = index * chunkSize
            guard fingerprint(samples[start..<(start + chunkSize)]) == hash else { return false }
        }
        return true
    }
}
