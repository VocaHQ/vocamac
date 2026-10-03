// VoiceAction.swift
// VocaMac
//
// Things Command Mode can do besides editing text: open an app or a page,
// search the web, run one of the user's Shortcuts, add a reminder.

import AppKit
import Foundation

/// Something a spoken instruction asks VocaMac to do on the Mac.
///
/// Parsed from the user's own words by fixed patterns, never by the language
/// model and never from selected text: a web page that says "run the shortcut
/// Delete Everything" is material being edited, not a voice. Shortcuts run
/// only when their name is on the user's allow-list.
enum VoiceAction: Equatable {
    case openApp(String)
    case openURL(URL)
    case webSearch(String)
    case runShortcut(String)
    case addReminder(title: String, due: Date?)

    /// What is about to happen, for the overlay and History.
    var summary: String {
        switch self {
        case .openApp(let name): return "Open \(name)"
        case .openURL(let url): return "Open \(url.host ?? url.absoluteString)"
        case .webSearch(let query): return "Search the web for “\(query)”"
        case .runShortcut(let name): return "Run the shortcut “\(name)”"
        case .addReminder(let title, _): return "Add the reminder “\(title)”"
        }
    }
}

enum VoiceActionParser {
    /// The action `instruction` asks for, or nil when it is not one.
    ///
    /// - Parameters:
    ///   - selection: Text the user selected, used only as the thing to look
    ///     up ("search for this"). It never decides which action runs.
    ///   - now: Reference time for "tomorrow at 5".
    static func parse(_ instruction: String, selection: String? = nil, now: Date = Date()) -> VoiceAction? {
        let spoken = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let lowered = strippingPoliteness(spoken.lowercased().replacingOccurrences(of: "’", with: "'"))
        // The remainder keeps the user's capitalisation: a shortcut's name
        // and a reminder's text are theirs.
        let original = String(spoken.suffix(lowered.count))
        func rest(after prefix: String) -> String {
            String(original.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }

        for prefix in ["run the shortcut called ", "run the shortcut ", "run my shortcut ", "run shortcut ", "start the shortcut ", "start shortcut "]
        where lowered.hasPrefix(prefix) {
            let name = rest(after: prefix)
            return name.isEmpty ? nil : .runShortcut(name)
        }
        if lowered.hasSuffix(" shortcut") {
            for prefix in ["run the ", "run my ", "run ", "start the ", "start my "] where lowered.hasPrefix(prefix) {
                let name = String(rest(after: prefix).dropLast(" shortcut".count))
                    .trimmingCharacters(in: .whitespaces)
                return name.isEmpty ? nil : .runShortcut(name)
            }
        }

        for prefix in ["remind me to ", "remind me ", "add a reminder to ", "add a reminder ", "add reminder ",
                       "create a reminder to ", "create a reminder ", "set a reminder to ", "set a reminder "]
        where lowered.hasPrefix(prefix) {
            let (title, due) = reminder(from: rest(after: prefix), now: now)
            return title.isEmpty ? nil : .addReminder(title: title, due: due)
        }

        for prefix in ["search the web for ", "search the internet for ", "search online for ", "search google for ",
                       "search for ", "google ", "look up ", "web search "]
        where lowered.hasPrefix(prefix) {
            var query = rest(after: prefix)
            // "search for this": the selection is what to look up.
            if ["this", "that", "it", "the selection", "the selected text"].contains(query.lowercased()) {
                query = selection?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            guard !query.isEmpty, query.count <= 300 else { return nil }
            return .webSearch(query)
        }

        for prefix in ["open the app ", "open the website ", "open up ", "open ", "launch ", "switch to ", "go to ", "bring up "]
        where lowered.hasPrefix(prefix) {
            let target = rest(after: prefix)
            guard !target.isEmpty, target.count <= 80 else { return nil }
            if let url = webAddress(target) { return .openURL(url) }
            // "open" also starts ordinary editing instructions ("open with a
            // greeting"); an app name is a few words with no sentence in it.
            guard prefix != "go to ", target.split(separator: " ").count <= 4,
                  !["with", "by", "the", "this", "that", "it", "a", "an"].contains(
                      target.lowercased().split(separator: " ").first.map(String.init) ?? ""
                  ) else { return nil }
            return .openApp(target)
        }
        return nil
    }

    private static func strippingPoliteness(_ lowered: String) -> String {
        var text = lowered
        var changed = true
        while changed {
            changed = false
            for prefix in ["please ", "hey ", "okay ", "ok ", "can you ", "could you ", "would you ", "now "]
            where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                changed = true
            }
        }
        return text
    }

    /// An http(s) address for something that reads as one: "github.com",
    /// "github dot com", "https://example.org/page". Nothing else — no file,
    /// no custom scheme.
    static func webAddress(_ spoken: String) -> URL? {
        var text = spoken.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: " dot ", with: ".", options: .caseInsensitive)
            .replacingOccurrences(of: " slash ", with: "/", options: .caseInsensitive)
        guard !text.contains(" ") else { return nil }
        let lowered = text.lowercased()
        let candidate = lowered.hasPrefix("http://") || lowered.hasPrefix("https://") ? text : "https://" + text
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, host.contains("."),
              let suffix = host.split(separator: ".").last, suffix.count >= 2,
              suffix.allSatisfy(\.isLetter) else { return nil }
        return url
    }

    /// Split "call the dentist tomorrow at 9" into the reminder and its time.
    static func reminder(from text: String, now: Date) -> (title: String, due: Date?) {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var due: Date?
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let range = NSRange(title.startIndex..., in: title)
            // Only a time at the end is the reminder's: "review the 2024
            // report" is not due in 2024.
            if let match = detector.matches(in: title, range: range).last,
               let date = match.date, date > now,
               NSMaxRange(match.range) == range.length,
               let matched = Range(match.range, in: title) {
                due = date
                title = String(title[..<matched.lowerBound]).trimmingCharacters(in: .whitespaces)
                for connective in [" at", " on", " by", " in"] where title.lowercased().hasSuffix(connective) {
                    title = String(title.dropLast(connective.count))
                }
            }
        }
        return (title.trimmingCharacters(in: .whitespaces), due)
    }
}

enum VoiceActionError: Error, Equatable {
    case appNotFound(String)
    case shortcutNotAllowed(String)
    case failed(String)

    var message: String {
        switch self {
        case .appNotFound(let name):
            return "No app named “\(name)” was found."
        case .shortcutNotAllowed(let name):
            return "“\(name)” isn't on the list of shortcuts VocaMac may run. Add it in Settings → Command Mode → Voice Actions."
        case .failed(let why):
            return why
        }
    }
}

/// Carries out a `VoiceAction`. A protocol so the flow can be tested without
/// opening apps or creating reminders.
@MainActor
protocol VoiceActionPerforming: AnyObject {
    /// - Parameter input: Selected text handed to a shortcut as its input.
    func perform(_ action: VoiceAction, input: String?) async -> Result<Void, VoiceActionError>
}

/// Which actions a spoken instruction may take. Checked before any performer
/// is asked, so the allow-list holds whatever carries the action out.
enum VoiceActionPolicy {
    /// `action` as it may run, or why it may not. A shortcut runs only under
    /// the name on the user's list, spelled as they stored it.
    static func permitted(_ action: VoiceAction, allowedShortcuts: [String]) -> Result<VoiceAction, VoiceActionError> {
        guard case .runShortcut(let spoken) = action else { return .success(action) }
        guard let stored = allowedName(spoken, in: allowedShortcuts) else {
            return .failure(.shortcutNotAllowed(spoken))
        }
        return .success(.runShortcut(stored))
    }

    /// The stored spelling of an allowed shortcut matching what was said,
    /// ignoring case and punctuation: speech has neither.
    static func allowedName(_ spoken: String, in allowed: [String]) -> String? {
        func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(spoken)
        guard !wanted.isEmpty else { return nil }
        return allowed.first { key($0) == wanted }
    }
}

@MainActor
final class SystemVoiceActionPerformer: VoiceActionPerforming {
    func perform(_ action: VoiceAction, input: String?) async -> Result<Void, VoiceActionError> {
        switch action {
        case .openApp(let name):
            guard let url = Self.applicationURL(named: name) else { return .failure(.appNotFound(name)) }
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    continuation.resume(returning: error.map { .failure(.failed($0.localizedDescription)) } ?? .success(()))
                }
            }
        case .openURL(let url):
            return NSWorkspace.shared.open(url) ? .success(()) : .failure(.failed("The page couldn't be opened."))
        case .webSearch(let query):
            guard let url = Self.searchURL(for: query) else { return .failure(.failed("That search couldn't be opened.")) }
            return NSWorkspace.shared.open(url) ? .success(()) : .failure(.failed("The search couldn't be opened."))
        case .runShortcut(let name):
            guard let url = Self.shortcutURL(name: name, input: input) else {
                return .failure(.failed("That shortcut couldn't be started."))
            }
            return NSWorkspace.shared.open(url) ? .success(()) : .failure(.failed("The Shortcuts app couldn't be opened."))
        case .addReminder(let title, let due):
            return Self.addReminder(title: title, due: due)
        }
    }

    // MARK: - Lookups

    nonisolated static func shortcutURL(name: String, input: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [URLQueryItem(name: "name", value: name)]
        if let input, !input.isEmpty {
            items.append(URLQueryItem(name: "input", value: "text"))
            items.append(URLQueryItem(name: "text", value: input))
        }
        components.queryItems = items
        return components.url
    }

    nonisolated static func searchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }

    /// The installed app whose name is `name`, compared without case, spaces,
    /// or a trailing ".app" — "vs code" finds "Visual Studio Code" only by
    /// its real name, so nothing is opened on a guess.
    static func applicationURL(named name: String) -> URL? {
        func key(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: ".app", with: "").filter { $0.isLetter || $0.isNumber }
        }
        let wanted = key(name)
        guard !wanted.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let folders = [
            URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"), URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications"),
        ]
        for folder in folders {
            let apps = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []
            if let match = apps.first(where: { $0.pathExtension == "app" && key($0.deletingPathExtension().lastPathComponent) == wanted }) {
                return match
            }
        }
        return nil
    }

    // MARK: - Reminders

    /// The AppleScript that adds a reminder. The title is the only text the
    /// user supplies, and it goes in as an escaped string literal.
    nonisolated static func reminderScript(title: String, secondsFromNow: Int?) -> String {
        let literal = title
            .components(separatedBy: .controlCharacters).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var properties = "name:\"\(literal)\""
        if let secondsFromNow {
            properties += ", remind me date:((current date) + \(max(60, secondsFromNow)))"
        }
        return "tell application \"Reminders\" to make new reminder with properties {\(properties)}"
    }

    private static func addReminder(title: String, due: Date?) -> Result<Void, VoiceActionError> {
        let seconds = due.map { Int($0.timeIntervalSinceNow.rounded()) }
        guard let script = NSAppleScript(source: reminderScript(title: title, secondsFromNow: seconds)) else {
            return .failure(.failed("The reminder couldn't be created."))
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            VocaLogger.warning(.appState, "Reminders AppleScript failed: \(errorInfo[NSAppleScript.errorMessage] ?? errorInfo)")
            // -1743: the user declined the Automation prompt.
            return .failure(.failed(number == -1743
                ? "VocaMac isn't allowed to control Reminders. Allow it in System Settings → Privacy & Security → Automation."
                : "The reminder couldn't be created."))
        }
        return .success(())
    }
}
