// Calibration.swift
// VocaMac
//
// The accuracy test: read a passage once, and every downloaded speech model
// transcribes that same recording. Pure parts only — the passages, the
// scoring, and the stored result — so they are testable without audio.

import Foundation

// MARK: - Passage

/// A short text to read aloud, with the words that must come out right.
///
/// No numbers: engines write "twelve" or "12" as they like, and the word
/// error rate would count either as a mistake.
struct CalibrationPassage: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The language the passage is in, as a transcription language code.
    let language: String
    /// What the reader says, word for word.
    let text: String
    /// Names and terms a good model must get right.
    let mustKeep: [String]
    /// A note shown with the results, or nil.
    var note: String?
    /// What the winner did best, for the results headline.
    var winnerPhrase = "heard you best"

    static let everyday = CalibrationPassage(
        id: "everyday",
        title: "Everyday English",
        language: "en",
        text: "The quiet harbor town wakes early. Fishing boats leave the pier before sunrise, "
            + "and the bakery on Main Street already smells of cinnamon. Maria checks the weather, "
            + "sends a short message to her brother in Lisbon, and walks to the library, where she "
            + "volunteers every Thursday. Nobody remembers when the old clock above the door stopped.",
        mustKeep: ["Maria", "Lisbon", "Thursday", "library"]
    )

    static let technical = CalibrationPassage(
        id: "technical",
        title: "Technical English",
        language: "en",
        text: "Open the pull request on GitHub and check why the Kubernetes deployment failed. "
            + "The logs mention a timeout in the PostgreSQL connection pool, so raise it in the config "
            + "file and restart the worker. Then ask Priya to review the TypeScript changes before "
            + "Friday, and update the README with the new API endpoint.",
        mustKeep: ["GitHub", "Kubernetes", "PostgreSQL", "Priya", "TypeScript", "README", "API"]
    )

    /// Scored against Roman script on purpose: it finds the model that
    /// writes Hinglish the way Voca Hinglish does. A model that writes
    /// Devanagari may have heard every word and still score badly, and the
    /// title and note say so rather than calling it the most accurate.
    static let hinglish = CalibrationPassage(
        id: "hinglish",
        title: "Hinglish in Roman script",
        language: "hi",
        text: "Kal subah team ki meeting hai, toh please apna laptop charge karke rakhna. "
            + "Main office thoda late aaunga kyunki traffic bahut zyada hai. Agar client call jaldi "
            + "start ho jaye, toh tum presentation share kar dena aur notes bhi le lena. "
            + "Baad mein hum budget pe baat karenge.",
        mustKeep: ["meeting", "laptop", "client", "presentation", "budget"],
        note: "This compares Hindi written in Roman letters. A model that writes Devanagari scores badly here even when it heard you right, and Roman spellings vary (kyunki, kyonki), so compare the models with each other.",
        winnerPhrase: "wrote your Hinglish best in Roman script"
    )

    static let all: [CalibrationPassage] = [.everyday, .technical, .hinglish]

    /// The passages worth offering someone who dictates in `spokenLanguages`.
    /// English is always offered; it is what most models are best at.
    static func offered(for spokenLanguages: [String]) -> [CalibrationPassage] {
        all.filter { $0.language == "en" || spokenLanguages.contains($0.language) }
    }

    static func passage(withID id: String) -> CalibrationPassage? {
        all.first { $0.id == id }
    }

    /// Words in the passage, for the reading-time estimate.
    var wordCount: Int { WordErrorRate.normalizedWords(text).count }
}

// MARK: - Results

/// The input the accuracy test recorded with.
struct CalibrationInput: Equatable, Sendable {
    /// The device's UID, as Core Audio names it.
    let uid: String
    let name: String
}

/// One model's result on the recording.
struct CalibrationRow: Codable, Equatable, Identifiable, Sendable {
    /// `ModelSize.rawValue`.
    let modelID: String
    let modelName: String
    /// Word error rate, 0…1 (it can exceed 1 when a model adds words). Nil
    /// when the model could not be tested.
    let wordErrorRate: Double?
    /// Seconds from the recording to text, once the model was loaded.
    let seconds: Double?
    /// Must-keep words the model got wrong.
    let lostTerms: [String]
    /// What the model wrote.
    let transcript: String
    /// Why the model wasn't tested, or nil.
    let failure: String?

    var id: String { modelID }

    static func failed(modelID: String, modelName: String, reason: String) -> CalibrationRow {
        CalibrationRow(
            modelID: modelID, modelName: modelName, wordErrorRate: nil,
            seconds: nil, lostTerms: [], transcript: "", failure: reason
        )
    }

    /// "7.3%".
    var errorRateText: String? {
        wordErrorRate.map { String(format: "%.1f%%", $0 * 100) }
    }
}

/// A finished test, kept so the Speech Model page can show what was measured.
struct CalibrationResult: Codable, Equatable, Sendable {
    let date: Date
    let passageID: String
    /// The microphone it was recorded with (its UID; empty for the system
    /// default), so a result from another microphone is marked as such.
    let deviceUID: String
    let deviceName: String
    /// Ranked best first; untested models last.
    let rows: [CalibrationRow]

    /// Measured with a different microphone than the one now selected.
    func isStale(currentDeviceUID: String) -> Bool {
        deviceUID != currentDeviceUID
    }

    func row(for modelID: String) -> CalibrationRow? {
        rows.first { $0.modelID == modelID && $0.wordErrorRate != nil }
    }

    /// The most accurate model that was tested.
    var best: CalibrationRow? { rows.first { $0.wordErrorRate != nil } }

    static func decode(_ json: String) -> CalibrationResult? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(CalibrationResult.self, from: data)
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Scoring

enum CalibrationScoring {
    /// A recording shorter than this can't say much about a model.
    static let minimumSeconds: Double = 4
    /// Samples quieter than this everywhere are silence (as the dictation
    /// path's own "No microphone audio" check counts it).
    static let silenceAmplitude: Float = 0.0001
    static let sampleRate: Double = 16_000

    /// Why `samples` can't be scored, or nil when they can.
    static func recordingProblem(_ samples: [Float], deviceName: String) -> String? {
        if !samples.contains(where: { abs($0) >= silenceAmplitude }) {
            return "No sound came from \(deviceName). Check that it is connected and not muted, then try again."
        }
        if Double(samples.count) / sampleRate < minimumSeconds {
            return "That was too short to compare models. Read the whole passage, then press Done."
        }
        return nil
    }

    /// Score one model's transcript against the passage.
    static func row(
        modelID: String, modelName: String, passage: CalibrationPassage,
        hypothesis: String, seconds: Double
    ) -> CalibrationRow {
        let rate = WordErrorRate.measure(reference: passage.text, hypothesis: hypothesis)
        return CalibrationRow(
            modelID: modelID,
            modelName: modelName,
            wordErrorRate: rate.referenceWords == 0 ? nil : rate.rate,
            seconds: seconds,
            lostTerms: lostTerms(passage.mustKeep, in: hypothesis),
            transcript: hypothesis,
            failure: rate.referenceWords == 0 ? "The passage has no words to compare." : nil
        )
    }

    /// The must-keep terms that aren't in `hypothesis`, compared as the word
    /// error rate compares words (case and punctuation ignored), so
    /// "Postgres QL" doesn't count as "PostgreSQL".
    static func lostTerms(_ terms: [String], in hypothesis: String) -> [String] {
        let words = WordErrorRate.normalizedWords(hypothesis)
        return terms.filter { term in
            let wanted = WordErrorRate.normalizedWords(term)
            guard !wanted.isEmpty, words.count >= wanted.count else { return !wanted.isEmpty }
            for start in 0...(words.count - wanted.count) where Array(words[start..<start + wanted.count]) == wanted {
                return false
            }
            return true
        }
    }

    /// Best first: lowest error rate, then fewest lost terms, then fastest.
    /// Models that couldn't be tested go last, in their original order.
    static func ranked(_ rows: [CalibrationRow]) -> [CalibrationRow] {
        let tested = rows.filter { $0.wordErrorRate != nil }.sorted { lhs, rhs in
            let left = lhs.wordErrorRate ?? .infinity, right = rhs.wordErrorRate ?? .infinity
            if abs(left - right) > 0.0005 { return left < right }
            if lhs.lostTerms.count != rhs.lostTerms.count { return lhs.lostTerms.count < rhs.lostTerms.count }
            return (lhs.seconds ?? .infinity) < (rhs.seconds ?? .infinity)
        }
        return tested + rows.filter { $0.wordErrorRate == nil }
    }

    /// The transcription language for a passage: English passages are read
    /// as English; any other is read in its own language.
    static func transcriptionLanguage(for passage: CalibrationPassage) -> String? {
        passage.language
    }
}
