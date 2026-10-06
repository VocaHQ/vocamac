// DictationPhase.swift
// VocaMac
//
// One name for where a dictation is, read from the flags AppState keeps, and
// the combinations of those flags that should never be left behind.

import Foundation

/// Where the current dictation is.
enum DictationPhase: Equatable {
    case idle
    /// The hotkey was pressed with no speech model in memory; it is loading.
    case loadingModel
    /// The microphone route is being negotiated (Bluetooth can take seconds).
    case startingAudio
    case recording
    /// The audio engine is handing back the recording.
    case stopping
    /// Transcribing, cleaning up, or delivering the text.
    case transcribing
    case error
}

/// The flags that together describe a dictation, in one value so they can be
/// read as a phase and checked for contradictions.
///
/// AppState still owns and sets each flag; this is a read-only view. Every
/// stuck-recording bug so far (#80, #84, #173) was a pair of these flags
/// disagreeing after some path forgot one of them.
struct DictationFlags: Equatable, CustomStringConvertible {
    var appStatus: AppStatus
    var isRecording: Bool
    var isStartingAudio: Bool
    var isStoppingAudio: Bool
    var isLoadingModel: Bool
    var isTranscribing: Bool
    var isTranscribingMedia: Bool
    var hasPendingStopDuringStart: Bool
    var hasPendingStopDuringModelLoad: Bool

    var phase: DictationPhase {
        if isLoadingModel { return .loadingModel }
        if isStartingAudio { return .startingAudio }
        if isStoppingAudio { return .stopping }
        if isRecording || appStatus == .recording { return .recording }
        if isTranscribing { return .transcribing }
        if appStatus == .error { return .error }
        return .idle
    }

    /// Contradictions that must not remain once no start, stop, or cancel is
    /// in progress. Each names the flags involved, for the log.
    var violations: [String] {
        var problems: [String] = []
        if isRecording && appStatus != .recording {
            problems.append("microphone is on but status is \(appStatus.rawValue)")
        }
        if appStatus == .recording && !isRecording {
            problems.append("status is recording but the microphone is off")
        }
        if appStatus == .processing && !isTranscribing && !isLoadingModel && !isTranscribingMedia {
            problems.append("status is processing with nothing being processed")
        }
        if isStartingAudio {
            problems.append("a microphone start never finished")
        }
        if isStoppingAudio {
            problems.append("a microphone stop never finished")
        }
        if hasPendingStopDuringStart {
            problems.append("a stop is still waiting on a start that finished")
        }
        if hasPendingStopDuringModelLoad && !isLoadingModel {
            problems.append("a stop is still waiting on a model load that finished")
        }
        return problems
    }

    var description: String {
        var parts = ["status=\(appStatus.rawValue)"]
        let flags: [(String, Bool)] = [
            ("recording", isRecording), ("startingAudio", isStartingAudio),
            ("stoppingAudio", isStoppingAudio), ("loadingModel", isLoadingModel),
            ("transcribing", isTranscribing), ("transcribingMedia", isTranscribingMedia),
            ("pendingStopDuringStart", hasPendingStopDuringStart),
            ("pendingStopDuringModelLoad", hasPendingStopDuringModelLoad),
        ]
        parts += flags.filter(\.1).map(\.0)
        return parts.joined(separator: " ")
    }
}
