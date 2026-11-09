// SeamRepair.swift
// VocaMac
//
// Mends the join between two pieces of audio decoded on their own.
//
// Long recordings are split for engines that decode one utterance at a
// time (the ONNX models' 8–20 s limits, Whisper files over two minutes). A
// cut that lands in a pause joins cleanly. A cut inside running speech —
// there was no pause to find — leaves each side decoded as if it were
// complete: the first ends "…we should move the.", the second starts "Meeting
// to Friday." Where the cut was not in a pause, and the second side opens
// with a word that rarely starts an English sentence after a full stop,
// the stop and the capital are taken back out.

import Foundation

enum SeamRepair {

    /// Half the window measured on each side of a cut: 100 ms.
    static let probeSamples = 1_600

    /// Context measured around the cut to judge "quiet": 1 s each side.
    static let contextSamples = 16_000

    /// A cut is in a pause when the audio right at it is at least 10 dB
    /// quieter than the speech around it.
    static let pauseRatio: Float = 0.1

    /// Whether the cut at `index` lands in a pause in `samples`.
    static func isPause(at index: Int, in samples: [Float]) -> Bool {
        guard index > 0, index < samples.count else { return true }
        let probe = max(0, index - probeSamples)..<min(samples.count, index + probeSamples)
        let context = max(0, index - contextSamples)..<min(samples.count, index + contextSamples)
        let probeEnergy = meanSquare(samples[probe])
        let contextEnergy = meanSquare(samples[context])
        guard contextEnergy > 0 else { return true }
        return probeEnergy <= contextEnergy * pauseRatio
    }

    private static func meanSquare(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in slice { sum += sample * sample }
        return sum / Float(slice.count)
    }

    /// Words that seldom open an English sentence right after a full stop
    /// the speaker didn't pause for. "I", names, and anything ambiguous
    /// ("So", "Then") are left out: those often do start one.
    static let continuationWords: Set<String> = [
        "the", "a", "an", "of", "to", "in", "on", "at", "for", "with", "from", "by", "into", "about",
        "and", "or", "but", "nor", "than", "that", "which", "who", "whom", "whose",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "has", "have", "had", "do", "does", "did",
        "its", "their", "our", "your", "his", "her", "my",
        "as", "because", "though", "although", "unless", "until", "while", "whether",
        "not", "too", "also", "will", "would", "can", "could", "should", "might", "must",
    ]

    /// `left` and `right` with the seam between them mended, when the cut
    /// was not in a pause. English only: other languages' sentence starts
    /// are not something this list can judge.
    static func repair(left: String, right: String, cutInPause: Bool, language: String?) -> (left: String, right: String) {
        guard !cutInPause, isEnglishOrUnknown(language) else { return (left, right) }
        let trimmedLeft = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRight = right.trimmingCharacters(in: .whitespacesAndNewlines)
        // One full stop, not an ellipsis or an abbreviation's dot ("U.S.").
        guard trimmedLeft.hasSuffix("."), !trimmedLeft.hasSuffix(".."),
              let lastWord = trimmedLeft.dropLast().split(separator: " ").last,
              !lastWord.contains("."),
              let first = trimmedRight.first, first.isUppercase,
              let firstWord = trimmedRight.split(separator: " ").first else { return (left, right) }
        let word = firstWord.trimmingCharacters(in: .punctuationCharacters)
        // "The" opens a sentence, "THE" is shouted or an acronym.
        guard word.dropFirst().allSatisfy({ !$0.isUppercase }),
              continuationWords.contains(word.lowercased()) else { return (left, right) }
        let mendedRight = trimmedRight.prefix(1).lowercased() + trimmedRight.dropFirst()
        return (String(trimmedLeft.dropLast()), mendedRight)
    }

    /// Mend every seam of `pieces`; `cutsInPause[i]` says whether the cut
    /// between piece `i` and `i + 1` was in a pause.
    static func repair(_ pieces: [String], cutsInPause: [Bool], language: String?) -> [String] {
        guard pieces.count > 1 else { return pieces }
        var mended = pieces
        for index in 1..<mended.count {
            let inPause = index - 1 < cutsInPause.count ? cutsInPause[index - 1] : true
            (mended[index - 1], mended[index]) = repair(
                left: mended[index - 1], right: mended[index], cutInPause: inPause, language: language
            )
        }
        return mended
    }

    private static func isEnglishOrUnknown(_ language: String?) -> Bool {
        guard let code = DictationOutputPipeline.knownLanguage(
            language?.replacingOccurrences(of: "<|", with: "").replacingOccurrences(of: "|>", with: "")
        ) else { return true }
        return code.hasPrefix("en")
    }
}
