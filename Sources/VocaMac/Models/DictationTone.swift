// DictationTone.swift
// VocaMac
//
// Shared start/stop dictation-tone catalog. Missing or unknown stored
// ids resolve to `.voca`. Off is a real stored choice.

import Foundation

/// Start or stop half of a dictation tone pair.
enum DictationCueKind: String {
    case start
    case stop
}

/// Start/stop cue set shown in Settings and used while recording.
enum DictationTone: String, CaseIterable, Identifiable, Codable {
    case lift
    case flick
    case ember
    case step
    case voca
    case soft
    case chirp
    case scale
    case drop
    case glass
    case off

    var id: String { rawValue }

    /// New installs and anyone with no saved tone id.
    static let defaultTone: DictationTone = .voca

    var displayName: String {
        switch self {
        case .lift:  return "Lift"
        case .flick: return "Flick"
        case .ember: return "Ember"
        case .step:  return "Step"
        case .voca:  return "Voca"
        case .soft:  return "Soft"
        case .chirp: return "Chirp"
        case .scale: return "Scale"
        case .drop:  return "Drop"
        case .glass: return "Glass"
        case .off:   return "Off"
        }
    }

    /// Whether this tone emits start/stop audio.
    var playsCues: Bool { self != .off }

    /// Resolve a stored preference. Empty, missing, and unknown ids become `voca`.
    /// Known ids, including `off`, are kept as saved.
    static func resolved(stored: String?) -> DictationTone {
        guard let stored, !stored.isEmpty else { return .voca }
        return DictationTone(rawValue: stored) ?? .voca
    }

    /// PCM WAV bytes for one cue, or `nil` when the tone is silent.
    func audioData(for kind: DictationCueKind) -> Data? {
        ToneBank.data(tone: self, kind: kind)
    }
}

// MARK: - WAV cache

private enum ToneBank {
    private static let lock = NSLock()
    private static var cache: [String: Data] = [:]

    static func data(tone: DictationTone, kind: DictationCueKind) -> Data? {
        guard tone.playsCues else { return nil }
        let key = "\(tone.rawValue)-\(kind.rawValue)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let rendered = ToneSynth.render(tone: tone, kind: kind)
        lock.lock()
        cache[key] = rendered
        lock.unlock()
        return rendered
    }
}

// MARK: - Synthesis

/// Short 16 kHz mono PCM pairs. Phase is accumulated so glides do not click.
private enum ToneSynth {
    static let sampleRate: Float = 16_000

    static func render(tone: DictationTone, kind: DictationCueKind) -> Data {
        let isStart = kind == .start
        switch tone {
        case .lift:
            return glide(from: 349.23, to: 440.00, reverse: !isStart, duration: 0.36, amplitude: 0.16)
        case .flick:
            return glide(from: 349.23, to: 440.00, reverse: !isStart, duration: 0.14, amplitude: 0.16)
        case .ember:
            return glide(from: 196.00, to: 261.63, reverse: !isStart, duration: 0.42, amplitude: 0.18)
        case .step:
            return ticks(isStart ? [261.63, 329.63] : [329.63, 261.63], tick: 0.045, gap: 0.03, amplitude: 0.12)
        case .voca:
            return isStart
                ? swell(freqs: [261.63, 392.00], duration: 0.38, amplitude: 0.14)
                : swell(freqs: [196.00, 261.63], duration: 0.42, amplitude: 0.13)
        case .soft:
            return ticks(isStart ? [329.63] : [261.63], tick: 0.022, gap: 0, amplitude: 0.07)
        case .chirp:
            return isStart
                ? glide(from: 1400, to: 2100, reverse: false, duration: 0.07, amplitude: 0.08)
                : glide(from: 1800, to: 1100, reverse: false, duration: 0.08, amplitude: 0.08)
        case .scale:
            return ticks(isStart ? [440.00, 523.25, 587.33] : [587.33, 523.25, 440.00], tick: 0.05, gap: 0.018, amplitude: 0.12)
        case .drop:
            return ticks(isStart ? [196.00] : [130.81], tick: isStart ? 0.14 : 0.18, gap: 0, amplitude: 0.16)
        case .glass:
            return ping(freq: isStart ? 2093 : 1568, duration: isStart ? 0.16 : 0.18, amplitude: 0.10)
        case .off:
            return wav([])
        }
    }

    private static func glide(from f0: Float, to f1: Float, reverse: Bool, duration: Float, amplitude: Float) -> Data {
        let start = reverse ? f1 : f0
        let end = reverse ? f0 : f1
        let count = sampleCount(duration)
        var phase: Float = 0
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let progress = Float(index) / Float(max(count - 1, 1))
            let stepped = progress * progress * (3 - 2 * progress)
            let freq = start + (end - start) * stepped
            let envelope = sineEnvelope(progress) * edgeFade(index: index, count: count)
            phase += 2 * .pi * freq / sampleRate
            samples[index] = sin(phase) * amplitude * envelope
        }
        return wav(samples)
    }

    private static func swell(freqs: [Float], duration: Float, amplitude: Float) -> Data {
        let count = sampleCount(duration)
        var phases = [Float](repeating: 0, count: freqs.count)
        var samples = [Float](repeating: 0, count: count)
        let mix = amplitude / Float(max(freqs.count, 1))
        for index in 0..<count {
            let progress = Float(index) / Float(max(count - 1, 1))
            let envelope = sineEnvelope(progress)
            var value: Float = 0
            for freqIndex in freqs.indices {
                phases[freqIndex] += 2 * .pi * freqs[freqIndex] / sampleRate
                value += sin(phases[freqIndex]) * mix * envelope
            }
            samples[index] = value
        }
        return wav(samples)
    }

    private static func ticks(_ freqs: [Float], tick: Float, gap: Float, amplitude: Float) -> Data {
        var samples: [Float] = []
        let tickCount = sampleCount(tick)
        let gapCount = sampleCount(gap)
        for (offset, freq) in freqs.enumerated() {
            var phase: Float = 0
            for index in 0..<tickCount {
                let envelope = edgeFade(index: index, count: tickCount)
                phase += 2 * .pi * freq / sampleRate
                samples.append(sin(phase) * amplitude * envelope)
            }
            if offset + 1 < freqs.count {
                samples.append(contentsOf: [Float](repeating: 0, count: gapCount))
            }
        }
        return wav(samples)
    }

    private static func ping(freq: Float, duration: Float, amplitude: Float) -> Data {
        let count = sampleCount(duration)
        var phase: Float = 0
        var harmonic: Float = 0
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let progress = Float(index) / Float(max(count - 1, 1))
            let decay = exp(-6 * progress) * edgeFade(index: index, count: count)
            phase += 2 * .pi * freq / sampleRate
            harmonic += 2 * .pi * freq * 2 / sampleRate
            samples[index] = (sin(phase) + 0.15 * sin(harmonic)) * amplitude * decay
        }
        return wav(samples)
    }

    private static func sineEnvelope(_ progress: Float) -> Float {
        let sine = sin(Float.pi * progress)
        return sine * sine
    }

    private static func edgeFade(index: Int, count: Int) -> Float {
        let fade = min(48, count / 3)
        guard fade > 0 else { return 1 }
        if index < fade { return Float(index) / Float(fade) }
        if index + fade >= count { return Float(count - index) / Float(fade) }
        return 1
    }

    private static func sampleCount(_ duration: Float) -> Int {
        max(Int((sampleRate * duration).rounded()), 1)
    }

    private static func wav(_ samples: [Float]) -> Data {
        let dataBytes = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))
        data.append(le16(1))
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate) * 2))
        data.append(le16(2))
        data.append(le16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(le32(dataBytes))
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            var value = Int16((clipped * Float(Int16.max)).rounded())
            data.append(Data(bytes: &value, count: 2))
        }
        return data
    }

    private static func le16(_ value: UInt16) -> Data {
        var value = value.littleEndian
        return Data(bytes: &value, count: 2)
    }

    private static func le32(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return Data(bytes: &value, count: 4)
    }
}
