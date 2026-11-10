// AccuracyBaseline.swift
// VocaMac
//
// Stored accuracy numbers the nightly benchmark compares against.

import Foundation

/// Corpus-level numbers per model from an earlier accuracy run, and the
/// comparison that fails a run when a model got worse. See docs/ACCURACY.md.
///
/// Rates are fractions (0.072 is 7.2%). A model missing from the baseline
/// is reported but never fails the run, so a new model can be measured
/// before it has a recorded number.
struct AccuracyBaseline: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// Corpus WER over the files scored in words.
        var corpusWER: Double?
        /// Corpus CER over the files scored in characters.
        var corpusCER: Double?
        /// WER of the final text (output rules, and the cleanup model when
        /// one was loaded) against the intended text.
        var finalCorpusWER: Double?
        /// Share of files whose first or last reference word was dropped.
        var edgeDropRate: Double?

        enum CodingKeys: String, CodingKey {
            case corpusWER = "corpus_wer"
            case corpusCER = "corpus_cer"
            case finalCorpusWER = "final_corpus_wer"
            case edgeDropRate = "edge_drop_rate"
        }
    }

    /// Free text: where and how the numbers were recorded.
    var note: String?
    /// The corpus the numbers came from. A run on a different corpus is
    /// not compared.
    var corpus: String?
    /// How far above the baseline a rate may go before the run fails,
    /// in absolute terms (0.01 is one percentage point).
    var tolerance: Double?
    var models: [String: Entry]

    /// One measured number above its baseline by more than the tolerance.
    struct Regression: Equatable, CustomStringConvertible {
        let model: String
        let metric: String
        let baseline: Double
        let measured: Double

        var description: String {
            String(format: "%@ %@ %.4f is above the baseline %.4f", model, metric, measured, baseline)
        }
    }

    /// Every number in `measured` that is worse than this baseline by more
    /// than `tolerance` (or the baseline's own tolerance when given none).
    func regressions(in measured: [String: Entry], tolerance: Double? = nil) -> [Regression] {
        let allowed = tolerance ?? self.tolerance ?? Self.defaultTolerance
        var found: [Regression] = []
        for (model, expected) in models.sorted(by: { $0.key < $1.key }) {
            guard let actual = measured[model] else { continue }
            let pairs: [(String, Double?, Double?)] = [
                ("corpus WER", expected.corpusWER, actual.corpusWER),
                ("corpus CER", expected.corpusCER, actual.corpusCER),
                ("final corpus WER", expected.finalCorpusWER, actual.finalCorpusWER),
                ("edge drop rate", expected.edgeDropRate, actual.edgeDropRate),
            ]
            for (metric, baseline, value) in pairs {
                guard let baseline, let value, value > baseline + allowed + 1e-12 else { continue }
                found.append(Regression(model: model, metric: metric, baseline: baseline, measured: value))
            }
        }
        return found
    }

    static let defaultTolerance = 0.01

    static func load(from url: URL) throws -> AccuracyBaseline {
        try JSONDecoder().decode(AccuracyBaseline.self, from: Data(contentsOf: url))
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
