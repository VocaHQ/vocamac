// LipCommandMatcher.swift
// VocaMac
//
// Recognises a silently mouthed command by comparing the lip movement with
// the takes the user taught: nearest neighbour under dynamic time warping,
// so the same word matches whether it was mouthed quickly or slowly.
//
// Small vocabulary, one person, no model to download. A match must be close
// in absolute terms and clearly closer than the next-best command; anything
// else is "not sure" rather than a guess, because a wrong command presses
// keys in someone's document.
//
// `LipCommandEvaluation` answers the question the user cares about before
// switching commands on: can these takes be told apart at all? Leave-one-out
// accuracy against a label-shuffled baseline.

import Foundation

// MARK: - Features of a take

enum LipSequence {
    /// The feature vectors of the frames that have readable lips.
    static func features(_ frames: [LipFrame]) -> [[Double]] {
        frames.compactMap { $0.usableShape.flatMap(LipFeatures.init)?.vector }
    }
}

// MARK: - Dynamic time warping

enum DynamicTimeWarping {
    /// Distance between two sequences of equal-length vectors, normalised by
    /// path length and by the vectors' dimension, so long and short takes and
    /// any feature count compare on one scale. A Sakoe–Chiba band keeps the
    /// alignment from pairing the start of one take with the end of another.
    static func distance(_ a: [[Double]], _ b: [[Double]], bandFraction: Double = 0.3) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return .infinity }
        let band = max(abs(n - m), Int(Double(max(n, m)) * bandFraction))
        var previous = [Double](repeating: .infinity, count: m + 1)
        var current = previous
        previous[0] = 0
        for i in 1...n {
            for j in current.indices { current[j] = .infinity }
            let lower = max(1, i - band)
            let upper = min(m, i + band)
            if lower <= upper {
                for j in lower...upper {
                    let cost = frameDistance(a[i - 1], b[j - 1])
                    current[j] = cost + min(previous[j], current[j - 1], previous[j - 1])
                }
            }
            swap(&previous, &current)
        }
        return previous[m] / Double(n + m)
    }

    /// Root-mean-square difference per dimension.
    static func frameDistance(_ x: [Double], _ y: [Double]) -> Double {
        let count = min(x.count, y.count)
        guard count > 0 else { return 0 }
        var sum = 0.0
        for index in 0..<count {
            let difference = x[index] - y[index]
            sum += difference * difference
        }
        return (sum / Double(count)).squareRoot()
    }
}

// MARK: - Scaling

/// Per-feature standard deviations across the taught takes, so no one
/// measure (the contour's 30-odd coordinates against a single openness
/// value) decides the distance alone.
struct LipFeatureScale: Equatable, Sendable {
    var deviations: [Double]

    init(deviations: [Double]) {
        self.deviations = deviations
    }

    init(sequences: [[[Double]]]) {
        guard let dimensions = sequences.first(where: { !$0.isEmpty })?.first?.count else {
            deviations = []
            return
        }
        var sum = [Double](repeating: 0, count: dimensions)
        var sumOfSquares = [Double](repeating: 0, count: dimensions)
        var count = 0.0
        for sequence in sequences {
            for frame in sequence where frame.count == dimensions {
                for index in 0..<dimensions {
                    sum[index] += frame[index]
                    sumOfSquares[index] += frame[index] * frame[index]
                }
                count += 1
            }
        }
        guard count > 1 else {
            deviations = [Double](repeating: 1, count: dimensions)
            return
        }
        deviations = (0..<dimensions).map { index in
            let mean = sum[index] / count
            // A constant feature's variance can come out a hair below zero
            // in floating point, and its square root is NaN.
            let variance = max(sumOfSquares[index] / count - mean * mean, 0)
            return max(variance.squareRoot(), 1e-4)
        }
    }

    func apply(_ sequence: [[Double]]) -> [[Double]] {
        guard !deviations.isEmpty else { return sequence }
        return sequence.map { frame in
            zip(frame, deviations).map { $0 / $1 }
        }
    }
}

// MARK: - Matcher

/// One command's rank against a mouthed take.
struct LipCommandCandidate: Equatable, Sendable {
    var commandID: UUID
    var distance: Double
}

/// The matcher's answer for one take.
struct LipCommandMatch: Equatable, Sendable {
    /// Every command, closest first.
    var ranked: [LipCommandCandidate]
    /// 0…1: how much closer the best command is than the runner-up.
    var margin: Double
    /// Close enough, and clearly enough, to run.
    var isAccepted: Bool

    var best: LipCommandCandidate? { ranked.first }
}

/// Matches mouthed takes against the user's taught commands.
struct LipCommandMatcher: Sendable {
    /// The best command must be at least this much closer than the next.
    static let minimumMargin = 0.12
    /// Bounds for the distance a match may have, whatever the takes say.
    /// Takes taught very consistently get a strict limit, not a loose
    /// floor: lips at rest come out about 0.3 from a word taught that way.
    static let distanceBounds: ClosedRange<Double> = 0.2...1.1
    /// A take may be this much further from its command than the taught
    /// takes are from each other.
    static let spreadAllowance = 1.35

    private let entries: [(commandID: UUID, frames: [[Double]])]
    private let scale: LipFeatureScale
    /// The largest distance a match may have, from how alike the taught
    /// takes of each command are.
    let maximumDistance: Double

    var commandCount: Int { Set(entries.map(\.commandID)).count }

    /// Nil when no command has a usable take.
    init?(commands: [SilentCommand]) {
        let raw: [(UUID, [[Double]])] = commands.flatMap { command in
            command.takes.compactMap { take in take.frames.isEmpty ? nil : (command.id, take.frames) }
        }
        guard !raw.isEmpty else { return nil }
        let scale = LipFeatureScale(sequences: raw.map(\.1))
        let entries = raw.map { (commandID: $0.0, frames: scale.apply($0.1)) }
        self.scale = scale
        self.entries = entries
        self.maximumDistance = Self.calibratedMaximum(entries: entries)
    }

    /// Rank every command against `frames` (feature vectors).
    func rank(_ frames: [[Double]]) -> [LipCommandCandidate] {
        let query = scale.apply(frames)
        var best: [UUID: Double] = [:]
        for entry in entries {
            let distance = DynamicTimeWarping.distance(query, entry.frames)
            best[entry.commandID] = min(best[entry.commandID] ?? .infinity, distance)
        }
        return best.map { LipCommandCandidate(commandID: $0.key, distance: $0.value) }
            .sorted { $0.distance < $1.distance }
    }

    func match(_ frames: [[Double]]) -> LipCommandMatch {
        let ranked = rank(frames)
        let margin = Self.margin(ranked.map(\.distance))
        guard let best = ranked.first, best.distance.isFinite else {
            return LipCommandMatch(ranked: ranked, margin: 0, isAccepted: false)
        }
        // With a single command there is no runner-up to beat; the distance
        // alone decides, so it must be well inside the limit.
        let accepted = ranked.count >= 2
            ? best.distance <= maximumDistance && margin >= Self.minimumMargin
            : best.distance <= maximumDistance * 0.8
        return LipCommandMatch(ranked: ranked, margin: margin, isAccepted: accepted)
    }

    static func margin(_ sortedDistances: [Double]) -> Double {
        guard sortedDistances.count >= 2, sortedDistances[1] > 0, sortedDistances[1].isFinite else { return 0 }
        return max(0, 1 - sortedDistances[0] / sortedDistances[1])
    }

    /// The match limit: how far apart each command's own takes are, plus
    /// an allowance, within `distanceBounds`. Takes taught carefully give a
    /// strict limit; loose ones a looser one.
    private static func calibratedMaximum(entries: [(commandID: UUID, frames: [[Double]])]) -> Double {
        var withinCommand: [Double] = []
        for (index, entry) in entries.enumerated() {
            for other in entries[(index + 1)...] where other.commandID == entry.commandID {
                withinCommand.append(DynamicTimeWarping.distance(entry.frames, other.frames))
            }
        }
        guard let spread = withinCommand.max() else { return distanceBounds.upperBound * 0.75 }
        return min(max(spread * spreadAllowance, distanceBounds.lowerBound), distanceBounds.upperBound)
    }
}

// MARK: - Evaluation

/// Can the taught commands be told apart? Leave-one-out accuracy, compared
/// with the same procedure on shuffled labels. Port of the check subvox
/// (github.com/joeblau/subvox, MIT) runs on head-motion templates.
struct LipCommandEvaluation: Equatable, Sendable {
    var commandCount: Int
    var takeCount: Int
    /// Share of takes whose nearest other take belongs to the same command.
    var accuracy: Double
    /// Always guessing the command with the most takes.
    var chance: Double
    /// Share of shuffled labellings that did at least as well.
    var pValue: Double

    /// Distinguishable, and better than chance by a clear margin. The
    /// permutation bar is looser than the usual 0.05: two commands with
    /// three takes each can't get below 0.1 however well they separate.
    var isReliable: Bool { accuracy >= 0.8 && accuracy - chance >= 0.25 && pValue < 0.2 }

    /// Nil until at least two commands have two takes each.
    static func run(commands: [SilentCommand], permutations: Int = 200) -> LipCommandEvaluation? {
        var generator = SystemRandomNumberGenerator()
        return run(commands: commands, permutations: permutations, using: &generator)
    }

    static func run<Generator: RandomNumberGenerator>(
        commands: [SilentCommand], permutations: Int, using generator: inout Generator
    ) -> LipCommandEvaluation? {
        let usable = commands.filter { $0.takes.filter { !$0.frames.isEmpty }.count >= 2 }
        guard usable.count >= 2 else { return nil }
        var sequences: [[[Double]]] = []
        var labels: [Int] = []
        for (label, command) in usable.enumerated() {
            for take in command.takes where !take.frames.isEmpty {
                sequences.append(take.frames)
                labels.append(label)
            }
        }
        let scale = LipFeatureScale(sequences: sequences)
        let scaled = sequences.map(scale.apply)
        let count = scaled.count
        var distance = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
        for i in 0..<count {
            for j in (i + 1)..<max(i + 1, count) {
                let value = DynamicTimeWarping.distance(scaled[i], scaled[j])
                distance[i][j] = value
                distance[j][i] = value
            }
        }

        func accuracy(_ assignment: [Int]) -> Double {
            var correct = 0
            for i in 0..<count {
                var best = Double.infinity
                var predicted = -1
                for j in 0..<count where j != i && distance[i][j] < best {
                    best = distance[i][j]
                    predicted = assignment[j]
                }
                if predicted == assignment[i] { correct += 1 }
            }
            return Double(correct) / Double(count)
        }

        let observed = accuracy(labels)
        var atLeast = 0
        for _ in 0..<permutations {
            let shuffled = labels.shuffled(using: &generator)
            if accuracy(shuffled) >= observed { atLeast += 1 }
        }
        let largest = Dictionary(grouping: labels, by: { $0 }).values.map(\.count).max() ?? 0
        return LipCommandEvaluation(
            commandCount: usable.count,
            takeCount: count,
            accuracy: observed,
            chance: Double(largest) / Double(count),
            pValue: Double(atLeast + 1) / Double(permutations + 1)
        )
    }
}
