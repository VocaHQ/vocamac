// MicrophoneNoteRecorder.swift
// VocaMac
//
// Records the microphone for a voice note, apart from dictation's own audio
// engine so a note and a dictation never fight over one tap. The tap takes
// the input's own format (whatever rate and channel count the device
// offers) and mixes it down; `SystemAudioAccumulator` resamples to 16 kHz.

import AVFoundation
import Foundation
import VocaMacObjC

@MainActor
final class MicrophoneNoteRecorder: ObservableObject {
    enum RecorderError: LocalizedError {
        case noInput
        case tapFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInput: return "No microphone is available."
            case .tapFailed(let reason): return "Could not start the microphone: \(reason)"
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var didReachLimit = false
    /// When audio started arriving, for lining it up with system audio.
    private(set) var startedAt: Date?

    private var engine: AVAudioEngine?
    private let accumulator = SystemAudioAccumulator()

    func start() throws {
        guard !isRecording else { return }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInput }
        accumulator.reset(sampleRate: format.sampleRate)
        didReachLimit = false

        let accumulator = self.accumulator
        let failure = VocaObjCExceptionCatcher.catchException {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let channels = buffer.floatChannelData else { return }
                let frames = Int(buffer.frameLength)
                let count = Int(buffer.format.channelCount)
                guard frames > 0, count > 0 else { return }
                var mono = [Float](repeating: 0, count: frames)
                for channel in 0..<count {
                    let samples = channels[channel]
                    for frame in 0..<frames { mono[frame] += samples[frame] / Float(count) }
                }
                if accumulator.appendMonoSamples(mono) {
                    Task { @MainActor [weak self] in self?.stopAtLimit() }
                }
            }
        }
        if let failure { throw RecorderError.tapFailed(failure.localizedDescription) }
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.tapFailed(error.localizedDescription)
        }
        self.engine = engine
        startedAt = Date()
        isRecording = true
        VocaLogger.info(.audioEngine, "Note microphone started: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch")
    }

    /// Stop and hand back what was recorded, at 16 kHz mono.
    func stop() -> [Float] {
        tearDown()
        didReachLimit = didReachLimit || accumulator.reachedLimit()
        return accumulator.takeNormalizedSamples()
    }

    /// Test support: as if the tap delivered `samples` (16 kHz mono), and
    /// optionally hit the 20-minute limit, without a microphone.
    func receiveForTesting(_ samples: [Float], reachingLimit: Bool) {
        accumulator.reset(sampleRate: 16_000)
        _ = accumulator.appendMonoSamples(samples)
        startedAt = startedAt ?? Date()
        isRecording = true
        if reachingLimit { stopAtLimit() }
    }

    private func stopAtLimit() {
        guard isRecording else { return }
        tearDown()
        didReachLimit = true
    }

    private func tearDown() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false
    }
}

/// Puts a microphone and a system-audio recording on one track.
enum NoteAudioMixer {
    /// Mix two 16 kHz tracks. `secondStartsAfter` is how many seconds after
    /// `first` the `second` began (negative when it began earlier). Where
    /// both play, they add; the result is scaled down only if it would clip.
    static func mix(_ first: [Float], _ second: [Float], secondStartsAfter offset: Double, sampleRate: Double = 16_000) -> [Float] {
        guard !first.isEmpty else { return second }
        guard !second.isEmpty else { return first }
        let shift = Int((offset * sampleRate).rounded())
        let firstStart = max(0, -shift)
        let secondStart = max(0, shift)
        let length = max(firstStart + first.count, secondStart + second.count)
        var mixed = [Float](repeating: 0, count: length)
        for (index, sample) in first.enumerated() { mixed[firstStart + index] += sample }
        for (index, sample) in second.enumerated() { mixed[secondStart + index] += sample }
        let peak = mixed.reduce(0) { max($0, abs($1)) }
        guard peak > 1 else { return mixed }
        let scale = 1 / peak
        return mixed.map { $0 * scale }
    }
}
