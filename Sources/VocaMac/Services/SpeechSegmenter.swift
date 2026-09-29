// SpeechSegmenter.swift
// VocaMac
//
// Cuts a live recording into pieces at natural pauses, so each finished piece
// can be decoded (and cleaned up) while the user is still talking.

import Foundation

/// Finds where a live recording can be cut: a pause after enough speech, or
/// the quietest point once a piece reaches the engine's length limit.
///
/// Pure and incremental. It keeps frame energies for the open piece only,
/// never audio, so feeding it every microphone chunk costs a few floats per
/// 20 ms frame.
struct SpeechSegmenter {

    struct Configuration: Equatable, Sendable {
        /// Quiet this long, after `minPieceSeconds` of audio, closes a piece.
        var pauseSeconds: Double = 0.6
        /// Shorter pieces decode less like the whole recording and give the
        /// cleanup model too little to work with.
        var minPieceSeconds: Double = 8
        /// The engine's single-pass limit. A piece with no pause is cut at its
        /// quietest point before reaching this.
        var maxPieceSeconds: Double = 25
        var sampleRate: Int = 16_000
    }

    /// Energy (mean square) at or below which a frame is quiet whatever the
    /// speech level: about -70 dBFS.
    static let absoluteQuietEnergy: Float = 1e-7
    /// A frame this far below the recent loud frames counts as quiet (-13 dB).
    /// Relative, so it holds for both a whisper and a loud room.
    static let relativeQuietRatio: Float = 0.05
    /// Per-frame decay of the loudness reference: it halves in about three
    /// seconds, so a sentence's level carries across the pause that ends it.
    static let peakDecay: Float = 0.995

    /// A closed piece, and where the last sound in it ended. Everything from
    /// `speechEnd` to the end of `range` was quiet by this segmenter's measure.
    struct ClosedPiece: Equatable, Sendable {
        let range: Range<Int>
        let speechEnd: Int
    }

    let configuration: Configuration
    private let frameLength = AudioSegmenter.frameLength

    /// Samples past the last whole frame, waiting for the rest of it.
    private var carry: [Float] = []
    /// Absolute offset of the next frame, and the count of samples seen so far
    /// excluding `carry`.
    private var nextFrameOffset = 0
    private var pieceStart = 0
    private var pieceHasSpeech = false
    private var quietRunStart: Int?
    private var peakEnergy: Float = 0
    /// End of the last frame that wasn't quiet, over the whole recording.
    private(set) var lastSpeechEnd = 0
    /// Frames of the open piece.
    private var frameOffsets: [Int] = []
    private var frameEnergies: [Float] = []
    private var frameQuiet: [Bool] = []

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    private var pauseSamples: Int { Int(configuration.pauseSeconds * Double(configuration.sampleRate)) }
    private var minSamples: Int { Int(configuration.minPieceSeconds * Double(configuration.sampleRate)) }
    private var maxSamples: Int {
        max(frameLength * 2, Int(configuration.maxPieceSeconds * Double(configuration.sampleRate)))
    }

    /// Total samples fed so far.
    var sampleCount: Int { nextFrameOffset + carry.count }

    /// Feed samples in order. Returns the ranges of pieces closed by this chunk.
    mutating func append(_ samples: [Float]) -> [Range<Int>] {
        appendPieces(samples).map(\.range)
    }

    /// Feed samples in order. Returns the pieces closed by this chunk.
    mutating func appendPieces(_ samples: [Float]) -> [ClosedPiece] {
        guard !samples.isEmpty else { return [] }
        var closed: [ClosedPiece] = []
        var index = 0
        if !carry.isEmpty {
            let needed = frameLength - carry.count
            let take = min(needed, samples.count)
            carry.append(contentsOf: samples[0..<take])
            index = take
            guard carry.count == frameLength else { return [] }
            observeFrame(energy: Self.energy(carry[...]), closed: &closed)
            carry.removeAll(keepingCapacity: true)
        }
        while index + frameLength <= samples.count {
            observeFrame(energy: Self.energy(samples[index..<(index + frameLength)]), closed: &closed)
            index += frameLength
        }
        if index < samples.count {
            carry.append(contentsOf: samples[index...])
        }
        return closed
    }

    /// Close whatever is left. Normally one range; two if the tail ran past
    /// the length limit.
    mutating func finish() -> [Range<Int>] {
        finishPieces().map(\.range)
    }

    /// Close whatever is left, as `finish` does.
    mutating func finishPieces() -> [ClosedPiece] {
        let end = sampleCount
        guard end > pieceStart else { return [] }
        // Samples short of a whole frame were never measured; if they are
        // loud, the speech runs to the very end.
        if !carry.isEmpty, !isQuiet(Self.energy(carry[...])) {
            lastSpeechEnd = end
        }
        var pieces: [ClosedPiece] = []
        if end - pieceStart > maxSamples, let cut = limitCut(end: end) {
            pieces.append(ClosedPiece(range: pieceStart..<cut, speechEnd: speechEnd(before: cut)))
            pieceStart = cut
        }
        pieces.append(ClosedPiece(range: pieceStart..<end, speechEnd: min(end, max(pieceStart, lastSpeechEnd))))
        pieceStart = end
        resetPiece(from: end)
        return pieces
    }

    // MARK: - Frames

    private func isQuiet(_ energy: Float) -> Bool {
        energy <= max(Self.absoluteQuietEnergy, peakEnergy * Self.relativeQuietRatio)
    }

    private mutating func observeFrame(energy: Float, closed: inout [ClosedPiece]) {
        let offset = nextFrameOffset
        nextFrameOffset += frameLength
        peakEnergy = max(energy, peakEnergy * Self.peakDecay)
        let quiet = isQuiet(energy)

        frameOffsets.append(offset)
        frameEnergies.append(energy)
        frameQuiet.append(quiet)

        if quiet {
            if quietRunStart == nil { quietRunStart = offset }
        } else {
            quietRunStart = nil
            pieceHasSpeech = true
            lastSpeechEnd = offset + frameLength
        }

        let frameEnd = offset + frameLength
        if let runStart = quietRunStart, pieceHasSpeech,
           frameEnd - runStart >= pauseSamples,
           runStart - pieceStart >= minSamples {
            // Cut in the middle of the pause heard so far; the rest of the
            // pause leads into the next piece.
            let cut = runStart + pauseSamples / 2
            close(at: cut, closed: &closed)
            return
        }

        // Cut before the next frame would take the piece past the limit.
        if frameEnd + frameLength - pieceStart > maxSamples {
            let cut = limitCut(end: frameEnd) ?? frameEnd
            close(at: cut, closed: &closed)
        }
    }

    /// The quietest point near the end of an over-long piece.
    private func limitCut(end: Int) -> Int? {
        let searchSamples = min(
            Int(AudioSegmenter.searchWindowSeconds * Double(configuration.sampleRate)),
            maxSamples / 2
        )
        let searchStart = max(pieceStart + frameLength, end - searchSamples)
        var energies: [Float] = []
        var offsets: [Int] = []
        for (offset, energy) in zip(frameOffsets, frameEnergies)
        where offset >= searchStart && offset + frameLength <= end {
            energies.append(energy)
            offsets.append(offset)
        }
        guard !energies.isEmpty else { return nil }
        let cut = AudioSegmenter.bestCutOffset(energies: energies, frameOffsets: offsets, fallback: end)
        return max(pieceStart + frameLength, min(cut, end))
    }

    private mutating func close(at cut: Int, closed: inout [ClosedPiece]) {
        guard cut > pieceStart else { return }
        closed.append(ClosedPiece(range: pieceStart..<cut, speechEnd: speechEnd(before: cut)))
        pieceStart = cut
        resetPiece(from: cut)
    }

    /// End of the last loud frame of the open piece that starts before `cut`.
    private func speechEnd(before cut: Int) -> Int {
        for (offset, quiet) in zip(frameOffsets, frameQuiet).reversed() where offset < cut && !quiet {
            return min(offset + frameLength, cut)
        }
        return pieceStart
    }

    /// Drop frames that now belong to a closed piece, and re-derive the open
    /// piece's state from those left.
    private mutating func resetPiece(from cut: Int) {
        let firstKept = frameOffsets.firstIndex { $0 >= cut } ?? frameOffsets.count
        frameOffsets.removeFirst(firstKept)
        frameEnergies.removeFirst(firstKept)
        frameQuiet.removeFirst(firstKept)
        pieceHasSpeech = frameQuiet.contains(false)
        quietRunStart = nil
        for (offset, quiet) in zip(frameOffsets, frameQuiet) {
            if quiet {
                if quietRunStart == nil { quietRunStart = max(offset, cut) }
            } else {
                quietRunStart = nil
            }
        }
    }

    /// Mean square, the measure `AudioSegmenter` uses.
    static func energy(_ frame: ArraySlice<Float>) -> Float {
        guard !frame.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in frame { sum += sample * sample }
        return sum / Float(frame.count)
    }
}
