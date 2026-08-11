// SettingsPage.swift
// VocaMac
//
// Sidebar page identifiers for the searchable settings shell.

import Foundation
import SwiftUI

/// Top-level settings topics shown in the left sidebar.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case dictation
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
        case .speechModel: return "Speech Model"
        case .audio: return "Audio"
        case .performance: return "Performance"
        case .application: return "Application"
        case .stats: return "Stats"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: return "mic"
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
