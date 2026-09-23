// SettingsPage.swift
// VocaMac
//
// Sidebar page identifiers for the searchable settings shell.

import Foundation
import SwiftUI

/// Sidebar groups, in display order. One flat list of every page reads as
/// a wall; four short groups can be scanned at a glance.
enum SettingsSection: CaseIterable, Identifiable {
    case dictation
    case writing
    case activity
    case app

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .writing: return "Writing"
        case .activity: return "Activity"
        case .app: return "VocaMac"
        }
    }

    /// Pages in this group, in sidebar order.
    var pages: [SettingsPage] {
        switch self {
        case .dictation: return [.dictation, .speechModel, .audio]
        case .writing: return [.writingStyles, .cleanup, .dictionary, .snippets]
        case .activity: return [.history, .stats]
        case .app: return [.application, .performance, .advanced, .gateway, .about]
        }
    }
}

/// Top-level settings topics shown in the left sidebar.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case dictation
    case history
    case writingStyles
    case dictionary
    case snippets
    case cleanup
    case speechModel
    case audio
    case performance
    case application
    case stats
    case advanced
    case gateway
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .history: return "History"
        case .dictionary: return "Dictionary"
        case .writingStyles: return "Writing Styles"
        case .snippets: return "Snippets"
        case .cleanup: return "Cleanup"
        case .speechModel: return "Speech Model"
        case .audio: return "Audio"
        case .performance: return "Performance"
        case .application: return "Application"
        case .stats: return "Stats"
        case .advanced: return "Advanced"
        case .gateway: return "Gateway"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .dictation: return "mic"
        case .history: return "clock.arrow.circlepath"
        case .dictionary: return "character.book.closed"
        case .writingStyles: return "textformat"
        case .snippets: return "text.quote"
        case .cleanup: return "wand.and.stars"
        case .speechModel: return "brain"
        case .audio: return "waveform"
        case .performance: return "bolt.circle"
        case .application: return "gearshape"
        case .stats: return "chart.xyaxis.line"
        case .advanced: return "ladybug"
        case .gateway: return "server.rack"
        case .about: return "info.circle"
        }
    }
}
