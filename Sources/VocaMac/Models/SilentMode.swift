// SilentMode.swift
// VocaMac
//
// Silent Mode's data: the actions a mouthed command can run, the commands
// the user taught, and where their takes are kept. Takes are lip
// measurements, never pictures, and they stay on this Mac: they are not in
// the settings export.

import CoreGraphics
import Foundation

// MARK: - Actions

/// What a silently mouthed command does. Fixed keys and VocaMac actions
/// only; a Shortcut runs only when its name is on the Command Mode allow-list.
enum SilentCommandAction: Codable, Hashable, Sendable {
    /// Press Return: send a message, submit a prompt.
    case pressReturn
    /// Shift-Return: a new line where Return would send.
    case newLine
    /// ⌘Z.
    case undo
    /// Tab.
    case tab
    /// Escape.
    case escape
    /// ⌥⌫: delete the word before the cursor.
    case deleteWord
    /// Type the last dictation again.
    case pasteLastDictation
    /// Run a Shortcut from the Command Mode allow-list.
    case runShortcut(String)

    /// The fixed actions, in the order the teach dialog offers them.
    static let builtIn: [SilentCommandAction] = [
        .pressReturn, .newLine, .undo, .deleteWord, .tab, .escape, .pasteLastDictation,
    ]

    /// The name in Settings.
    var title: String {
        switch self {
        case .pressReturn: return "Send"
        case .newLine: return "New line"
        case .undo: return "Undo"
        case .tab: return "Tab"
        case .escape: return "Cancel"
        case .deleteWord: return "Delete word"
        case .pasteLastDictation: return "Paste last dictation"
        case .runShortcut(let name): return "Run “\(name)”"
        }
    }

    /// What it presses or does, under the title.
    var detail: String {
        switch self {
        case .pressReturn: return "Presses Return"
        case .newLine: return "Presses Shift-Return"
        case .undo: return "Presses ⌘Z"
        case .tab: return "Presses Tab"
        case .escape: return "Presses Esc"
        case .deleteWord: return "Presses ⌥⌫"
        case .pasteLastDictation: return "Types your last dictation again"
        case .runShortcut: return "Runs a Shortcut on your Command Mode list"
        }
    }

    /// The chip the overlay shows when the command is recognised.
    var chip: String {
        switch self {
        case .pressReturn: return "Send ↩"
        case .newLine: return "New line ⇧↩"
        case .undo: return "Undo ⌘Z"
        case .tab: return "Tab ⇥"
        case .escape: return "Cancel ⎋"
        case .deleteWord: return "Delete word ⌥⌫"
        case .pasteLastDictation: return "Paste last dictation"
        case .runShortcut(let name): return "Run “\(name)”"
        }
    }

    /// A word that reads well on the lips for this action, offered when teaching.
    var suggestedWord: String {
        switch self {
        case .pressReturn: return "send"
        case .newLine: return "next line"
        case .undo: return "undo"
        case .tab: return "tab"
        case .escape: return "cancel"
        case .deleteWord: return "delete"
        case .pasteLastDictation: return "paste"
        case .runShortcut: return "run"
        }
    }
}

// MARK: - Commands

/// One mouthed take: the lip feature vectors of its frames.
struct LipTake: Codable, Equatable, Sendable {
    var frames: [[Double]]
    var recordedAt: Date

    init(frames: [[Double]], recordedAt: Date = Date()) {
        self.frames = frames
        self.recordedAt = recordedAt
    }
}

/// A command the user taught: the action, the word they mouth for it, and
/// the takes it is recognised by.
struct SilentCommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var action: SilentCommandAction
    /// The word the user mouths, as they typed it. Only shown back to them.
    var word: String
    var takes: [LipTake]

    /// Takes a command needs before it is matched.
    static let minimumTakes = 3
    /// More than this adds little and slows matching.
    static let maximumTakes = 8

    init(id: UUID = UUID(), action: SilentCommandAction, word: String, takes: [LipTake] = []) {
        self.id = id
        self.action = action
        self.word = word
        self.takes = takes
    }

    var isReady: Bool { takes.count >= Self.minimumTakes }
}

// MARK: - Store

/// Reads and writes the taught commands as JSON in VocaMac's Application
/// Support folder. A missing or unreadable file is an empty list.
struct SilentCommandStore: Sendable {
    /// Nil keeps nothing on disk (tests, headless runs).
    let fileURL: URL?

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VocaMac", isDirectory: true)
            .appendingPathComponent("silent-commands.json")
    }

    func load() -> [SilentCommand] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([SilentCommand].self, from: data)
        } catch {
            VocaLogger.warning(.silentMode, "Couldn't read the taught silent commands: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ commands: [SilentCommand]) {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(commands)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            VocaLogger.error(.silentMode, "Couldn't save the taught silent commands: \(error.localizedDescription)")
        }
    }

    func delete() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Live state

/// What the camera side of Silent Mode is doing, for the overlay and Settings.
enum SilentTrackingPhase: Equatable, Sendable {
    /// The camera is off.
    case off
    /// The camera is starting.
    case starting
    /// The camera is on, looking for a face.
    case searching
    /// A face is in view; the lips are still.
    case tracking
    /// The lips are moving.
    case speaking
    /// The camera can't be used; the reason is shown.
    case unavailable(String)

    /// The headline the overlay strip shows.
    var title: String {
        switch self {
        case .off: return "Camera off"
        case .starting: return "Starting camera…"
        case .searching: return "Looking for your face…"
        case .tracking: return "Watching your lips"
        case .speaking: return "Reading your lips"
        case .unavailable: return "Camera unavailable"
        }
    }

    /// The line under it.
    var detail: String {
        switch self {
        case .off: return "Turns on only while Silent Mode records"
        case .starting: return "Whisper or mouth your words"
        case .searching: return "Face the camera, with your mouth in view"
        case .tracking: return "Whisper or mouth your words"
        case .speaking: return "Only what your lips say is typed"
        case .unavailable(let reason): return reason
        }
    }

    /// The camera is on.
    var isCameraOn: Bool {
        switch self {
        case .starting, .searching, .tracking, .speaking: return true
        case .off, .unavailable: return false
        }
    }

    var hasFace: Bool { self == .tracking || self == .speaking }
}

/// The lips to draw, mirrored like a mirror, in two forms: fitted into a
/// unit square (the badge and the outline-only strip) and in the camera
/// picture's unit square (over the video), both with a top-left origin.
struct LipOutline: Equatable, Sendable {
    var outer: [CGPoint]
    var inner: [CGPoint]
    var outerInImage: [CGPoint]
    var innerInImage: [CGPoint]
    /// The face box in the picture's unit square, top-left origin, mirrored.
    var faceInImage: CGRect

    init(outer: [CGPoint], inner: [CGPoint], outerInImage: [CGPoint], innerInImage: [CGPoint], faceInImage: CGRect) {
        self.outer = outer
        self.inner = inner
        self.outerInImage = outerInImage
        self.innerInImage = innerInImage
        self.faceInImage = faceInImage
    }

    /// The outline of `shape`, levelled and centred for the badge.
    init?(_ shape: LipShape) {
        guard let features = LipFeatures(shape) else { return nil }
        // Features are centred on the mouth and one mouth-width wide; fit
        // them into the unit square with room around them, y down, mirrored.
        func fitted(_ point: CGPoint) -> CGPoint {
            CGPoint(x: 0.5 - point.x * 0.8, y: 0.5 - point.y * 0.8)
        }
        let image = shape.imagePoints
        func inImage(_ point: CGPoint) -> CGPoint {
            CGPoint(x: 1 - point.x, y: 1 - point.y)
        }
        let face = shape.faceBox
        self.init(
            outer: features.outer.map(fitted),
            inner: features.inner.map(fitted),
            outerInImage: image.outer.map(inImage),
            innerInImage: image.inner.map(inImage),
            faceInImage: CGRect(x: 1 - face.maxX, y: 1 - face.maxY, width: face.width, height: face.height)
        )
    }
}
