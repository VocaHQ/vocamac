// Music.swift
// Original score for the promo film, synthesized from scratch (no samples, no licensing).
// 96 BPM, C major: pad, bass, arpeggio pluck, kick, hats, clap, riser and a finale chord.

import Foundation

enum Music {
    static let sampleRate = 44_100.0
    static let bpm = 96.0
    static var beat: Double { 60.0 / bpm }
    static var bar: Double { beat * 4 }

    private static func hz(_ midi: Int) -> Double { 440.0 * pow(2.0, Double(midi - 69) / 12.0) }

    // Chord per bar: bass note and pad voicing (MIDI).
    private static let chords: [(bass: Int, pad: [Int])] = [
        (36, [55, 59, 62, 64]),  // Cmaj9
        (43, [55, 59, 62, 69]),  // G add9
        (45, [57, 60, 64, 67]),  // Am9
        (41, [53, 57, 60, 64]),  // Fmaj9
    ]

    private static func chord(forBar b: Int, totalBars: Int) -> (bass: Int, pad: [Int]) {
        if b >= totalBars - 2 { return chords[0] }          // final resolve on C
        if b >= totalBars - 4 { return chords[b % 2 == 0 ? 3 : 1] }  // F, G lead-in
        return chords[b % 4]
    }

    /// Renders `seconds` of stereo audio, interleaved Float in -1...1.
    static func render(seconds: Double) -> [Float] {
        let n = Int(seconds * sampleRate)
        let totalBars = Int(seconds / bar)
        var dry = [Double](repeating: 0, count: n)      // mono bus that stays dry
        var wet = [Double](repeating: 0, count: n)      // mono send to reverb
        var kickEnv = [Double](repeating: 0, count: n)  // for sidechain pumping
        var rng = SystemRandomNumberGenerator()
        func noise() -> Double { Double.random(in: -1...1, using: &rng) }

        // Sidechain envelope from a kick on every beat from bar 4.
        let kickStartBar = 4
        func hasKick(_ bar: Int) -> Bool { bar >= kickStartBar && bar < totalBars - 2 }
        for b in 0..<totalBars where hasKick(b) {
            for q in 0..<4 {
                let t0 = Double(b) * bar + Double(q) * beat
                let i0 = Int(t0 * sampleRate)
                let len = Int(0.32 * sampleRate)
                for i in 0..<len where i0 + i < n {
                    let t = Double(i) / sampleRate
                    kickEnv[i0 + i] = max(kickEnv[i0 + i], exp(-t * 9))
                }
            }
        }
        func duck(_ i: Int) -> Double { 1 - 0.55 * kickEnv[i] }

        // Pad: three detuned saws per note through a slowly moving one-pole low-pass.
        for b in 0..<totalBars {
            let c = chord(forBar: b, totalBars: totalBars)
            let t0 = Double(b) * bar
            let len = Int((bar + 0.9) * sampleRate)
            let i0 = Int(t0 * sampleRate)
            let gain = b < 2 ? 0.55 : 1.0
            for note in c.pad {
                var lp = 0.0
                for i in 0..<len where i0 + i < n {
                    let t = Double(i) / sampleRate
                    let env = min(1, t / 0.5) * (t < bar ? 1 : max(0, 1 - (t - bar) / 0.9))
                    var s = 0.0
                    for d in [-0.006, 0.0, 0.006] {
                        let ph = (hz(note) * (1 + d) * (t0 + t)).truncatingRemainder(dividingBy: 1)
                        s += ph * 2 - 1
                    }
                    let cutoff = 0.05 + 0.03 * sin((t0 + t) * 0.35)
                    lp += cutoff * (s / 3 - lp)
                    let v = lp * env * 0.11 * gain * duck(i0 + i)
                    dry[i0 + i] += v * 0.45
                    wet[i0 + i] += v * 0.55
                }
            }
        }

        // Bass from bar 4: a sine with a touch of second harmonic, half notes.
        for b in kickStartBar..<max(kickStartBar, totalBars - 2) {
            let c = chord(forBar: b, totalBars: totalBars)
            for half in 0..<2 {
                let t0 = Double(b) * bar + Double(half) * beat * 2
                let i0 = Int(t0 * sampleRate)
                let len = Int(beat * 2 * sampleRate)
                let f = hz(c.bass)
                for i in 0..<len where i0 + i < n {
                    let t = Double(i) / sampleRate
                    let env = min(1, t / 0.01) * exp(-t * 0.9)
                    let v = (sin(2 * .pi * f * t) + 0.25 * sin(4 * .pi * f * t)) * env * 0.26 * duck(i0 + i)
                    dry[i0 + i] += v
                }
            }
        }

        // Arpeggio pluck: 8th notes from bar 2, building in level.
        let pattern = [0, 1, 2, 3, 2, 1, 2, 3]
        for b in 2..<totalBars - 1 {
            let c = chord(forBar: b, totalBars: totalBars)
            let level = b < 4 ? 0.55 : (b < 8 ? 0.8 : 1.0)
            for s in 0..<8 {
                let t0 = Double(b) * bar + Double(s) * beat / 2
                let i0 = Int(t0 * sampleRate)
                let len = Int(0.7 * sampleRate)
                let f = hz(c.pad[pattern[s] % c.pad.count] + 12)
                for i in 0..<len where i0 + i < n {
                    let t = Double(i) / sampleRate
                    let env = min(1, t / 0.004) * exp(-t * 5.5)
                    let mod = sin(2 * .pi * f * 2 * t) * 1.6 * exp(-t * 9)
                    let v = sin(2 * .pi * f * t + mod) * env * 0.085 * level * duck(i0 + i)
                    dry[i0 + i] += v * 0.55
                    wet[i0 + i] += v * 0.75
                }
            }
        }

        // Drums.
        for b in 0..<totalBars {
            if hasKick(b) {
                for q in 0..<4 {
                    let t0 = Double(b) * bar + Double(q) * beat
                    let i0 = Int(t0 * sampleRate)
                    let len = Int(0.4 * sampleRate)
                    var phase = 0.0
                    for i in 0..<len where i0 + i < n {
                        let t = Double(i) / sampleRate
                        let f = 48 + 90 * exp(-t * 28)
                        phase += 2 * .pi * f / sampleRate
                        dry[i0 + i] += sin(phase) * exp(-t * 8) * 0.55
                    }
                }
            }
            if b >= 6 && b < totalBars - 2 {
                for e in 0..<8 where e % 2 == 1 {  // off-beat hats
                    let t0 = Double(b) * bar + Double(e) * beat / 2
                    let i0 = Int(t0 * sampleRate)
                    let len = Int(0.05 * sampleRate)
                    var prev = 0.0
                    for i in 0..<len where i0 + i < n {
                        let t = Double(i) / sampleRate
                        let x = noise()
                        let hp = x - prev; prev = x  // crude high-pass
                        dry[i0 + i] += hp * exp(-t * 90) * 0.06
                    }
                }
            }
            if b >= 8 && b < totalBars - 2 {
                for q in [1, 3] {  // clap on 2 and 4
                    let t0 = Double(b) * bar + Double(q) * beat
                    let i0 = Int(t0 * sampleRate)
                    let len = Int(0.22 * sampleRate)
                    var lp = 0.0
                    for i in 0..<len where i0 + i < n {
                        let t = Double(i) / sampleRate
                        lp += 0.45 * (noise() - lp)
                        let burst = exp(-t * 28) + 0.6 * exp(-max(0, t - 0.012) * 60)
                        let v = lp * burst * 0.11
                        dry[i0 + i] += v * 0.7
                        wet[i0 + i] += v * 0.5
                    }
                }
            }
        }

        // Riser into the finale, then a crash on the downbeat of the last four bars.
        let riseStart = Double(totalBars - 6) * bar, riseEnd = Double(totalBars - 4) * bar
        var lpR = 0.0
        for i in Int(riseStart * sampleRate)..<min(n, Int(riseEnd * sampleRate)) {
            let p = (Double(i) / sampleRate - riseStart) / (riseEnd - riseStart)
            lpR += (0.02 + 0.5 * p * p) * (noise() - lpR)
            let v = lpR * p * p * 0.22
            dry[i] += v * 0.6; wet[i] += v * 0.6
        }
        let crashI = Int(Double(totalBars - 4) * bar * sampleRate)
        var prev = 0.0
        for i in 0..<Int(3.0 * sampleRate) where crashI + i < n {
            let t = Double(i) / sampleRate
            let x = noise(); let hp = x - prev; prev = x
            let v = hp * exp(-t * 1.6) * 0.09
            dry[crashI + i] += v * 0.5; wet[crashI + i] += v
        }

        // Final shimmer on C: bell tones over the last two bars.
        let lastStart = Double(totalBars - 2) * bar
        for (k, note) in [72, 76, 79, 84, 88].enumerated() {
            let t0 = lastStart + Double(k) * 0.18
            let i0 = Int(t0 * sampleRate)
            let f = hz(note)
            for i in 0..<Int(4.0 * sampleRate) where i0 + i < n {
                let t = Double(i) / sampleRate
                let env = min(1, t / 0.004) * exp(-t * 1.3)
                let mod = sin(2 * .pi * f * 3.5 * t) * 1.2 * exp(-t * 4)
                let v = sin(2 * .pi * f * t + mod) * env * 0.06
                dry[i0 + i] += v * 0.4; wet[i0 + i] += v
            }
        }

        // Schroeder reverb on the send, slightly different delays per channel for width.
        func reverb(_ input: [Double], scale: Double) -> [Double] {
            var out = [Double](repeating: 0, count: input.count)
            let combs: [(Double, Double)] = [(0.0297, 0.80), (0.0371, 0.78), (0.0411, 0.77), (0.0437, 0.76)]
            for (delay, fb) in combs {
                let d = Int(delay * scale * sampleRate)
                var buf = [Double](repeating: 0, count: d)
                var idx = 0
                var damp = 0.0
                for i in 0..<input.count {
                    let y = buf[idx]
                    damp += 0.35 * (y - damp)
                    buf[idx] = input[i] + damp * fb
                    idx = (idx + 1) % d
                    out[i] += y * 0.25
                }
            }
            for delay in [0.0050, 0.0017] {
                let d = Int(delay * scale * sampleRate)
                var buf = [Double](repeating: 0, count: d)
                var idx = 0
                for i in 0..<out.count {
                    let y = buf[idx]
                    let x = out[i] + 0.5 * y
                    buf[idx] = x
                    out[i] = y - 0.5 * x
                    idx = (idx + 1) % d
                }
            }
            return out
        }
        let revL = reverb(wet, scale: 1.0), revR = reverb(wet, scale: 1.13)

        var out = [Float](repeating: 0, count: n * 2)
        let fadeIn = Int(0.6 * sampleRate), fadeOut = Int(2.2 * sampleRate)
        for i in 0..<n {
            var g = 1.0
            if i < fadeIn { g = Double(i) / Double(fadeIn) }
            if i > n - fadeOut { g = min(g, Double(n - i) / Double(fadeOut)) }
            let l = (dry[i] + revL[i] * 0.9) * g, r = (dry[i] + revR[i] * 0.9) * g
            out[2 * i] = Float(tanh(l * 1.25) * 0.88)
            out[2 * i + 1] = Float(tanh(r * 1.25) * 0.88)
        }
        return out
    }

    /// Writes 16-bit stereo PCM WAV.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; data.append(Data(bytes: &x, count: 2)) }
        let bytes = samples.count * 2
        data.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + bytes))
        data.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4); u16(4); u16(16)
        data.append("data".data(using: .ascii)!); u32(UInt32(bytes))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() { pcm[i] = Int16(max(-1, min(1, s)) * 32767) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }
}
