// PauseParagraphs.swift
// VocaMac
//
// Lays a long dictation out in paragraphs: a blank line goes where the
// speaker stopped for a long breath between two sentences, and an email's
// greeting gets a line of its own. Pure and deterministic.
//
// Where the pauses are comes from the recording's loudness, not from the
// engine's word timings: Whisper's aligned words drift into the silence
// around them, and Parakeet's token ends are frame skips. The timings only
// say which two words a pause falls between.

import Foundation

enum PauseParagraphs {

    struct Configuration: Equatable, Sendable {
        /// Quiet at least this long between two sentences starts a paragraph.
        /// A sentence ends with about half a second of quiet and a thought
        /// with more; a pause to think mid-sentence is ruled out by asking
        /// for a sentence end before it.
        var paragraphPauseSeconds: Double = 1.8
        /// Every paragraph keeps at least this many words, so one long breath
        /// after a short sentence doesn't leave it standing alone.
        var minimumParagraphWords: Int = 12
        var sampleRate: Int = 16_000
    }

    // MARK: - Entry point

    /// `text` with a blank line at each long pause between two sentences.
    ///
    /// Only ever adds line breaks: every word and mark is kept as it was.
    /// A pause is skipped whenever where it falls in the text is unclear (a
    /// word the engine timed differs from the text's), so a doubtful break
    /// is never made.
    ///
    /// - Parameters:
    ///   - segments: The transcript's timings, on the recording's timeline.
    ///     Without word timings nothing changes.
    ///   - audio: The complete recording. Without it the gaps between timed
    ///     words stand in for the pauses.
    static func apply(
        to text: String,
        segments: [TimedSegment],
        audio: [Float]?,
        configuration: Configuration = Configuration()
    ) -> String {
        let timed = segments.flatMap(\.words)
        let textWords = words(in: text)
        guard timed.count >= 2,
              textWords.count >= configuration.minimumParagraphWords * 2,
              !text.contains("\n") else { return text }

        // Where a pause falls in the text, by the timed word it follows.
        var textWordAfter: [Int: Int] = [:]
        for (index, boundary) in alignedBoundaries(timed: timed, textWords: textWords) {
            textWordAfter[index] = boundary
        }
        let pauses: [Int]
        if let audio {
            pauses = quietStretches(
                in: audio, minimumSeconds: configuration.paragraphPauseSeconds,
                sampleRate: configuration.sampleRate
            ).compactMap { nearestBoundary(to: $0, in: timed) }
        } else {
            pauses = (0..<(timed.count - 1)).filter {
                timed[$0 + 1].start - timed[$0].end >= configuration.paragraphPauseSeconds
            }
        }
        let breakAfter = Set(pauses.compactMap { textWordAfter[$0] })
            .filter { endsSentence(String(text[textWords[$0].range])) }
            .sorted()

        // Left to right, keeping each paragraph long enough on both sides.
        var accepted: [Int] = []
        var paragraphStart = 0
        for boundary in breakAfter {
            let wordsBefore = boundary + 1 - paragraphStart
            let wordsAfter = textWords.count - (boundary + 1)
            guard wordsBefore >= configuration.minimumParagraphWords,
                  wordsAfter >= configuration.minimumParagraphWords else { continue }
            accepted.append(boundary)
            paragraphStart = boundary + 1
        }
        guard !accepted.isEmpty else { return text }

        var result = text
        // From the end, so earlier ranges stay valid.
        for boundary in accepted.reversed() {
            let gap = textWords[boundary].range.upperBound..<textWords[boundary + 1].range.lowerBound
            result.replaceSubrange(gap, with: "\n\n")
        }
        return result
    }

    // MARK: - Greeting

    private static let greetingExpression = try? NSRegularExpression(
        pattern: #"^((?:hi|hello|hey|dear|good (?:morning|afternoon|evening))(?:[ \t]+[^\s,.!?:;]+){1,3},)[ \t]+(\S)"#,
        options: [.caseInsensitive]
    )

    /// An email's opening "Hi Sarah," on a line of its own, with the next
    /// sentence capitalized. Needs a name after the greeting word ("Hey,
    /// can you…" is not a greeting line) and a few words after it. Runs on
    /// the finished text: it needs no timings, and the model never sees a
    /// greeting cut off from its sentence.
    static func separatingGreeting(_ text: String) -> String {
        guard let greetingExpression,
              let match = greetingExpression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let greeting = Range(match.range(at: 1), in: text),
              let next = Range(match.range(at: 2), in: text),
              words(in: String(text[next.lowerBound...])).count >= 3 else { return text }
        return String(text[greeting]) + "\n\n" + text[next].uppercased() + String(text[next.upperBound...])
    }

    // MARK: - Pauses in the audio

    /// The quiet stretches of `samples` at least `minimumSeconds` long, in
    /// seconds, judged as `SpeechSegmenter` judges a pause: quiet against an
    /// absolute floor, or well below the recent speech level, so it holds
    /// for a whisper and for a loud room.
    static func quietStretches(
        in samples: [Float],
        minimumSeconds: Double,
        sampleRate: Int = 16_000
    ) -> [Range<Double>] {
        let frameLength = AudioSegmenter.frameLength
        let minimumFrames = max(1, Int((minimumSeconds * Double(sampleRate) / Double(frameLength)).rounded(.up)))
        let seconds = { (frame: Int) in Double(frame * frameLength) / Double(sampleRate) }
        var stretches: [Range<Double>] = []
        var peak: Float = 0
        var runStart: Int?
        var frame = 0
        var offset = 0
        while offset + frameLength <= samples.count {
            var energy: Float = 0
            for index in offset..<(offset + frameLength) {
                energy += samples[index] * samples[index]
            }
            energy /= Float(frameLength)
            peak = max(energy, peak * SpeechSegmenter.peakDecay)
            let isQuiet = energy <= SpeechSegmenter.absoluteQuietEnergy
                || energy <= peak * SpeechSegmenter.relativeQuietRatio
            if isQuiet {
                if runStart == nil { runStart = frame }
            } else if let start = runStart {
                if frame - start >= minimumFrames { stretches.append(seconds(start)..<seconds(frame)) }
                runStart = nil
            }
            frame += 1
            offset += frameLength
        }
        if let start = runStart, frame - start >= minimumFrames {
            stretches.append(seconds(start)..<seconds(frame))
        }
        return stretches
    }

    /// The timed word a quiet stretch follows: the one whose gap to the next
    /// word is nearest the stretch's middle. Word timings drift into the
    /// silence around them (Whisper stretches a word's end, Parakeet emits a
    /// sentence's full stop as the next word starts), so the gap need not
    /// contain the pause; nearest still picks the right two words. Nil for
    /// quiet before the first word or after the last.
    static func nearestBoundary(to stretch: Range<Double>, in timed: [TimedWord]) -> Int? {
        let middle = (stretch.lowerBound + stretch.upperBound) / 2
        guard let first = timed.first, let last = timed.last,
              middle > first.start, middle < last.end else { return nil }
        var best: (index: Int, distance: Double)?
        for index in 0..<(timed.count - 1) {
            let lower = min(timed[index].end, timed[index + 1].start)
            let upper = max(timed[index].end, timed[index + 1].start)
            let distance = middle < lower ? lower - middle : (middle > upper ? middle - upper : 0)
            if best == nil || distance < (best?.distance ?? .infinity) {
                best = (index, distance)
            }
        }
        return best?.index
    }

    // MARK: - Text

    struct TextWord: Equatable {
        let range: Range<String.Index>
        /// Lowercased letters and digits only, for matching against the
        /// engine's timed words.
        let key: String
    }

    static func words(in text: String) -> [TextWord] {
        var result: [TextWord] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard !text[index].isWhitespace else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, !text[end].isWhitespace { end = text.index(after: end) }
            result.append(TextWord(range: index..<end, key: key(String(text[index..<end]))))
            index = end
        }
        return result
    }

    static func key(_ word: String) -> String {
        String(String.UnicodeScalarView(
            word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        ))
    }

    /// Whether a word closes its sentence: a final `.` `!` `?` or `…`,
    /// possibly inside a closing quote or bracket. Not an abbreviation that
    /// usually leads into a name ("Dr.", "Mr.").
    static func endsSentence(_ word: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        var trimmed = Substring(word)
        while let last = trimmed.last, closers.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last, [".", "!", "?", "…"].contains(last) else { return false }
        let titles: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "prof", "sr", "jr"]
        return !titles.contains(key(String(trimmed)))
    }

    /// The places where a timed word and the next one meet at a text word
    /// boundary: `(timed index, text word index)` pairs meaning "the pause
    /// after timed word `i` falls after text word `w`".
    ///
    /// Timed words are matched to the text in order by their letters and
    /// digits, so "Hello," matches "hello" and two word pieces can make one
    /// text word. A timed word the text doesn't continue with is looked for
    /// a few words ahead; one not found there is left out, and no boundary
    /// is reported next to it.
    static func alignedBoundaries(timed: [TimedWord], textWords: [TextWord]) -> [(Int, Int)] {
        let lookahead = 6
        // Where each timed word starts and ends in the text, as (word, offset
        // within its key); nil when it couldn't be placed.
        var spans: [(start: (Int, Int), end: (Int, Int))?] = Array(repeating: nil, count: timed.count)
        var wordIndex = 0, offset = 0

        func consume(_ key: [Character], from position: (Int, Int)) -> (Int, Int)? {
            var (word, at) = position
            var remaining = key[...]
            while let character = remaining.first {
                guard word < textWords.count else { return nil }
                let textKey = Array(textWords[word].key)
                if at >= textKey.count {
                    word += 1
                    at = 0
                    continue
                }
                guard textKey[at] == character else { return nil }
                at += 1
                remaining = remaining.dropFirst()
            }
            return (word, at)
        }

        for (index, timedWord) in timed.enumerated() {
            let timedKey = Array(key(timedWord.word))
            guard !timedKey.isEmpty else { continue }
            // Mid-word: carry on in the same text word. At a word end, the
            // next timed word starts the next text word.
            var start = (wordIndex, offset)
            if wordIndex < textWords.count, offset >= textWords[wordIndex].key.count {
                start = (wordIndex + 1, 0)
            }
            if let end = consume(timedKey, from: start) {
                spans[index] = (start, end)
                (wordIndex, offset) = end
                continue
            }
            // Resynchronize at the start of a nearby text word.
            let first = offset == 0 ? wordIndex : wordIndex + 1
            for candidate in first..<min(textWords.count, first + lookahead) {
                if let end = consume(timedKey, from: (candidate, 0)) {
                    spans[index] = ((candidate, 0), end)
                    (wordIndex, offset) = end
                    break
                }
            }
        }

        var boundaries: [(Int, Int)] = []
        for index in 0..<(timed.count - 1) {
            guard let before = spans[index], let after = spans[index + 1] else { continue }
            let (endWord, endOffset) = before.end
            guard endWord < textWords.count,
                  endOffset == textWords[endWord].key.count,
                  after.start == (endWord + 1, 0) else { continue }
            boundaries.append((index, endWord))
        }
        return boundaries
    }
}
