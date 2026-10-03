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

    /// The scene behind every page header in the group, so each group keeps
    /// its own time of day.
    var mood: SceneMood {
        switch self {
        case .dictation: return .day
        case .writing: return .dawn
        case .activity: return .dusk
        case .app: return .night
        }
    }

    /// The group a page sits in.
    static func containing(_ page: SettingsPage) -> SettingsSection {
        allCases.first { $0.pages.contains(page) } ?? .dictation
    }

    /// Pages in this group, in sidebar order.
    var pages: [SettingsPage] {
        switch self {
        case .dictation: return [.dictation, .speechModel, .audio, .performance]
        case .writing: return [.writingStyles, .cleanup, .commandMode, .dictionary, .snippets]
        case .activity: return [.history, .stats]
        case .app: return [.application, .gateway, .advanced, .about]
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
    case commandMode
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
        case .cleanup: return "Smart Cleanup"
        case .commandMode: return "Command Mode"
        case .speechModel: return "Speech Model"
        case .audio: return "Audio"
        case .performance: return "Performance"
        case .application: return "Application"
        case .stats: return "Stats"
        // Raw value stays `advanced` so a remembered last page still resolves.
        case .advanced: return "Permissions & Logs"
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
        case .cleanup: return "sparkles"
        case .commandMode: return "wand.and.stars"
        case .speechModel: return "brain"
        case .audio: return "waveform"
        case .performance: return "bolt.circle"
        case .application: return "gearshape"
        case .stats: return "chart.xyaxis.line"
        case .advanced: return "checkmark.shield"
        case .gateway: return "server.rack"
        case .about: return "info.circle"
        }
    }
}
