// OverlaySettings.swift
// VocaMac
//
// User-facing configuration for the recording overlay.

import Foundation

/// Controls how much information the recording overlay displays.
enum OverlayStyle: String, CaseIterable, Codable, Identifiable {
    /// Do not show a recording overlay.
    case off

    /// Show a compact waveform and processing state.
    case minimal

    /// Show the larger Handy-inspired status panel.
    ///
    /// Shows partial words while Whisper or Parakeet is decoding.
    case live

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .live: return "Live panel"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Do not show recording status on screen."
        case .minimal:
            return "Show a compact waveform while recording and a spinner while transcribing."
        case .live:
            return "Show a larger waveform and live words while Whisper or Parakeet is listening."
        }
    }
}

/// Controls where the recording overlay is anchored.
enum OverlayPosition: String, CaseIterable, Codable, Identifiable {
    /// Place the overlay next to the focused text caret.
    case nearCursor = "near_cursor"

    /// Center the overlay near the top of the active display.
    case top

    /// Center the overlay near the bottom of the active display.
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nearCursor: return "Near cursor"
        case .top: return "Top of screen"
        case .bottom: return "Bottom of screen"
        }
    }
}
