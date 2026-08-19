// DictationTone.swift
// VocaMac
//
// Shared start/stop dictation-tone catalog. Missing or unknown stored
// ids resolve to `.voca`. Off is a real stored choice. Audio comes from
// bundled WAV files, not an in-app oscillator.

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

    /// Bundled file stem, e.g. `voca_start`. Off has no file.
    func resourceName(for kind: DictationCueKind) -> String? {
        guard playsCues else { return nil }
        return "\(rawValue)_\(kind.rawValue)"
    }

    /// Location of the bundled WAV, or `nil` for Off / a missing file.
    func cueURL(for kind: DictationCueKind) -> URL? {
        guard let name = resourceName(for: kind) else { return nil }
        let bundle = Bundle.module
        return bundle.url(forResource: name, withExtension: "wav", subdirectory: "Resources/Sounds")
            ?? bundle.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
            ?? bundle.url(forResource: name, withExtension: "wav")
    }

    /// WAV bytes for one cue, or `nil` when the tone is silent or the file is missing.
    func audioData(for kind: DictationCueKind) -> Data? {
        guard let url = cueURL(for: kind) else { return nil }
        return try? Data(contentsOf: url)
    }
}
