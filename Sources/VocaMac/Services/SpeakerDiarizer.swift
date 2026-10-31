// SpeakerDiarizer.swift
// VocaMac
//
// Tells speakers apart in a note's audio with FluidAudio's offline
// pipeline (pyannote segmentation, WeSpeaker embeddings, VBx clustering),
// all on device. The models download once (about 30 MB, into FluidAudio's
// cache beside Parakeet's) and are loaded only for the note being processed,
// then released.

import FluidAudio
import Foundation

/// Finds who spoke when.
protocol SpeakerDiarizing: Sendable {
    /// Why diarization can't run on this Mac, or nil when it can.
    var unavailableReason: String? { get }
    /// Speaker turns in 16 kHz mono `samples`, in seconds.
    func turns(in samples: [Float]) async throws -> [SpeakerTurn]
}

enum SpeakerDiarizationError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        }
    }
}

/// FluidAudio's offline diarizer.
final class FluidSpeakerDiarizer: SpeakerDiarizing {
    /// Shortest audio worth diarizing: one 10-second segmentation window.
    static let minimumSeconds = 10.0

    var unavailableReason: String? {
        Self.unavailableReason(osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }

    /// macOS 14 has an Apple bug that crashes Core ML on the CPU path the
    /// diarizer's models take (FluidAudio #878, fixed in macOS 15). Rather
    /// than risk the app, speakers aren't told apart there.
    static func unavailableReason(osMajorVersion: Int) -> String? {
        osMajorVersion >= 15 ? nil : "Telling speakers apart needs macOS 15 or later."
    }

    func turns(in samples: [Float]) async throws -> [SpeakerTurn] {
        if let unavailableReason { throw SpeakerDiarizationError.unavailable(unavailableReason) }
        guard Double(samples.count) / 16_000 >= Self.minimumSeconds else { return [] }
        // Detached: segmentation and clustering are seconds of CPU and
        // Neural Engine work that must not run on the caller's actor.
        return try await Task.detached(priority: .userInitiated) {
            let manager = OfflineDiarizerManager()
            try await manager.prepareModels()
            let started = Date()
            let result = try await manager.process(audio: samples)
            VocaLogger.info(
                .general,
                "Diarized \(Int(Double(samples.count) / 16_000))s of audio into \(Set(result.segments.map(\.speakerId)).count) speakers "
                    + "in \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
            )
            return result.segments.map {
                SpeakerTurn(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
            }
        }.value
    }
}
