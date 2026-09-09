// SettingsPage.swift
// VocaMac
//
// Sidebar page identifiers for the searchable settings shell.

import Foundation
import SwiftUI

/// Top-level settings topics shown in the left sidebar.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case dictation
    case writingStyles
    case snippets
    case cleanup
    case speechModel
    case audio
    case performance
    case application
    case stats
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .writingStyles: return "Writing Styles"
        case .snippets: return "Snippets"
        case .cleanup: return "Cleanup"
        case .speechModel: return "Speech Model"
        case .audio: return "Audio"
        case .performance: return "Performance"
        case .application: return "Application"
        case .stats: return "Stats"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation: return "Make voice typing feel natural to you."
        case .snippets: return "Turn a short spoken phrase into the text you use often."
        case .cleanup: return "Polish your words with an optional model running on this Mac."
        case .speechModel: return "Find the right balance of speed, accuracy, and languages."
        case .audio: return "Choose your microphone and how recording sounds."
        case .performance: return "Keep dictation responsive and manage memory use."
        case .application: return "Make VocaMac at home in your everyday workflow."
        case .stats: return "See how your voice adds up."
        case .advanced: return "Check permissions, inspect logs, and troubleshoot dictation."
        case .about: return "Private voice typing, built in the open."
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: return "mic"
        case .writingStyles: return "textformat"
        case .snippets: return "text.quote"
        case .cleanup: return "wand.and.stars"
        case .speechModel: return "brain"
        case .audio: return "waveform"
        case .performance: return "bolt.circle"
        case .application: return "gearshape"
        case .stats: return "chart.xyaxis.line"
        case .advanced: return "ladybug"
        case .about: return "info.circle"
        }
    }
}
