// CrashReporter.swift
// VocaMac
//
// Notices that VocaMac crashed last time and offers to report it.
//
// Nothing is sent anywhere. macOS already writes a crash report to
// ~/Library/Logs/DiagnosticReports; on the next launch VocaMac reads the new
// one, and if the user chooses Report, opens a pre-filled GitHub issue in
// the browser for them to read, edit, and submit themselves.

import AppKit
import Foundation

// MARK: - Crash report

/// The parts of a macOS `.ips` crash report worth putting in a bug report.
struct CrashReport: Equatable {
    struct Frame: Equatable {
        var image: String
        var symbol: String?
        var offset: Int

        /// "VocaMac  AppState.startRecording() + 120", or the image offset
        /// when the frame has no symbol.
        var line: String {
            if let symbol {
                return "\(image)  \(symbol) + \(offset)"
            }
            return "\(image)  0x\(String(offset, radix: 16))"
        }
    }

    var appVersion: String?
    var osVersion: String?
    var macModel: String?
    var timestamp: String?
    var exceptionType: String?
    var signal: String?
    /// The Objective-C exception message, or what macOS says ended the process.
    var reason: String?
    var crashedThread: Int?
    var frames: [Frame]
    /// Where an Objective-C exception was thrown, when there was one.
    var exceptionFrames: [Frame]
    /// UUID of the VocaMac binary, so a release's dSYM can symbolicate it.
    var binaryUUID: String?

    /// "EXC_BAD_ACCESS (SIGSEGV)".
    var summary: String {
        switch (exceptionType, signal) {
        case let (type?, signal?): return "\(type) (\(signal))"
        case let (type?, nil): return type
        case let (nil, signal?): return signal
        default: return "Crash"
        }
    }

    /// The first frame in VocaMac's own code, the likeliest place to look.
    var firstAppFrame: Frame? {
        (exceptionFrames + frames).first { $0.image == "VocaMac" && $0.symbol != nil }
    }

    /// Parse the text of an `.ips` file: a one-line JSON header followed by
    /// a JSON body. Nil when it isn't one.
    static func parse(_ text: String) -> CrashReport? {
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        let headerText = text[..<newline]
        let bodyText = text[text.index(after: newline)...]
        guard let header = json(headerText), let body = json(bodyText) else { return nil }

        let images = (body["usedImages"] as? [[String: Any]]) ?? []
        func frames(_ value: Any?) -> [Frame] {
            ((value as? [[String: Any]]) ?? []).prefix(maxFrames).map { frame in
                let index = frame["imageIndex"] as? Int
                let image = index.flatMap { images.indices.contains($0) ? images[$0]["name"] as? String : nil } ?? "???"
                return Frame(
                    image: image,
                    symbol: frame["symbol"] as? String,
                    offset: (frame["symbolLocation"] as? Int) ?? (frame["imageOffset"] as? Int) ?? 0
                )
            }
        }

        let exception = body["exception"] as? [String: Any]
        let termination = body["termination"] as? [String: Any]
        let objcReason = (body["exceptionReason"] as? [String: Any])?["composed_message"] as? String
        let reason = objcReason ?? termination?["indicator"] as? String

        let crashedThread = body["faultingThread"] as? Int
        let threads = (body["threads"] as? [[String: Any]]) ?? []
        let crashed = crashedThread.flatMap { threads.indices.contains($0) ? threads[$0] : nil }
            ?? threads.first { $0["triggered"] as? Bool == true }

        let os = body["osVersion"] as? [String: Any]
        let osVersion = (header["os_version"] as? String)
            ?? [os?["train"] as? String, (os?["build"] as? String).map { "(\($0))" }]
                .compactMap { $0 }.joined(separator: " ")

        return CrashReport(
            appVersion: header["app_version"] as? String,
            osVersion: osVersion.isEmpty ? nil : osVersion,
            macModel: body["modelCode"] as? String,
            timestamp: header["timestamp"] as? String,
            exceptionType: exception?["type"] as? String,
            signal: exception?["signal"] as? String,
            reason: reason.map(redact),
            crashedThread: crashedThread,
            frames: frames(crashed?["frames"]),
            exceptionFrames: frames(body["lastExceptionBacktrace"]),
            binaryUUID: images.first { $0["name"] as? String == "VocaMac" }?["uuid"] as? String
        )
    }

    static let maxFrames = 25

    private static func json(_ text: Substring) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Home-folder paths name the user; keep them out of a public issue.
    static func redact(_ text: String) -> String {
        let redacted = text.replacingOccurrences(
            of: #"/Users/[^/\s]+"#, with: "~", options: .regularExpression
        )
        return redacted.count > 500 ? String(redacted.prefix(500)) + "…" : redacted
    }
}

// MARK: - Issue

/// A pre-filled GitHub issue for a crash, using the bug report form's fields.
enum CrashIssue {
    static let newIssueURL = URL(string: "https://github.com/VocaHQ/vocamac/issues/new")!

    /// Browsers and GitHub start refusing URLs around 8 KB.
    static let maximumURLLength = 7_500

    /// Longest symbol put in a title; Swift generic symbols run to hundreds
    /// of characters.
    static let maximumTitleSymbolLength = 120

    static func title(for report: CrashReport) -> String {
        if let frame = report.firstAppFrame, let symbol = frame.symbol {
            let shown = symbol.count > maximumTitleSymbolLength
                ? String(symbol.prefix(maximumTitleSymbolLength)) + "…"
                : symbol
            return "Crash: \(report.summary) in \(shown)"
        }
        return "Crash: \(report.summary)"
    }

    /// The "Debug logs" field: what crashed and where.
    static func details(for report: CrashReport, frameLimit: Int = CrashReport.maxFrames) -> String {
        var lines = ["Exception: \(report.summary)"]
        if let reason = report.reason { lines.append("Reason: \(reason)") }
        if let uuid = report.binaryUUID { lines.append("VocaMac binary UUID: \(uuid)") }
        if !report.exceptionFrames.isEmpty {
            lines.append("")
            lines.append("Exception backtrace:")
            lines += numbered(report.exceptionFrames.prefix(frameLimit))
        }
        if !report.frames.isEmpty {
            lines.append("")
            lines.append("Crashed thread\(report.crashedThread.map { " \($0)" } ?? ""):")
            lines += numbered(report.frames.prefix(frameLimit))
        }
        return lines.joined(separator: "\n")
    }

    static func url(for report: CrashReport) -> URL {
        // Drop frames until the URL fits; the top of each stack matters most.
        for limit in stride(from: CrashReport.maxFrames, through: 0, by: -5) {
            if let url = url(for: report, frameLimit: limit),
               url.absoluteString.count <= maximumURLLength {
                return url
            }
        }
        // Even with no frames it didn't fit (a very long reason): the form
        // and a short title, and the user attaches the file.
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "title", value: "Crash: \(report.summary)"),
        ]
        return components?.url ?? newIssueURL
    }

    private static func url(for report: CrashReport, frameLimit: Int) -> URL? {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)
        var mac = report.osVersion ?? ""
        if let model = report.macModel { mac += mac.isEmpty ? model : ", \(model)" }
        var items = [
            URLQueryItem(name: "template", value: "bug_report.yml"),
            URLQueryItem(name: "title", value: title(for: report)),
            URLQueryItem(
                name: "what-happened",
                value: "VocaMac quit unexpectedly (\(report.summary))"
                    + (report.timestamp.map { " at \($0)" } ?? "")
                    + ".\n\nWhat I was doing when it happened: "
            ),
            URLQueryItem(name: "logs", value: details(for: report, frameLimit: frameLimit)),
        ]
        if let version = report.appVersion { items.append(URLQueryItem(name: "version", value: version)) }
        if !mac.isEmpty { items.append(URLQueryItem(name: "macos", value: mac)) }
        components?.queryItems = items
        return components?.url
    }

    private static func numbered(_ frames: ArraySlice<CrashReport.Frame>) -> [String] {
        frames.enumerated().map { index, frame in
            "\(String(index).padding(toLength: 3, withPad: " ", startingAt: 0))\(frame.line)"
        }
    }
}

// MARK: - Finding new reports

/// A crash report VocaMac hasn't offered to report yet.
struct PendingCrashReport: Equatable {
    var fileURL: URL
    var modified: Date
    var report: CrashReport
}

/// Looks for crash reports macOS wrote for VocaMac since the last one shown.
/// Unchecked: its only state is `UserDefaults` and `FileManager`, both safe
/// to use from any thread.
final class CrashReportFinder: @unchecked Sendable {
    static let lastSeenKey = "vocamac.crashReports.lastSeen"

    private let directory: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager

    init(
        directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.defaults = defaults
        self.fileManager = fileManager
    }

    /// Whether `name` is a crash report for this app. macOS names them
    /// "VocaMac-2026-10-06-120000.ips" (with a "-1" suffix for a second one
    /// in the same second).
    static func isVocaMacReport(_ name: String) -> Bool {
        name.hasPrefix("VocaMac-") && name.hasSuffix(".ips")
    }

    /// The newest unseen VocaMac crash report, or nil.
    ///
    /// The first time this runs there is no baseline, so it records one and
    /// reports nothing: crashes from before this feature existed aren't news.
    func newestUnseenReport(now: Date = Date()) -> PendingCrashReport? {
        guard let lastSeen = defaults.object(forKey: Self.lastSeenKey) as? Date else {
            defaults.set(now, forKey: Self.lastSeenKey)
            return nil
        }
        let files = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = files.compactMap { url -> (URL, Date)? in
            guard Self.isVocaMacReport(url.lastPathComponent),
                  let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate,
                  modified > lastSeen else { return nil }
            return (url, modified)
        }
        for (url, modified) in candidates.sorted(by: { $0.1 > $1.1 }) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let report = CrashReport.parse(text) else { continue }
            return PendingCrashReport(fileURL: url, modified: modified, report: report)
        }
        // Unreadable files aren't worth asking about again.
        if let newest = candidates.map(\.1).max() { markSeen(through: newest) }
        return nil
    }

    /// Don't offer this report, or any older one, again.
    func markSeen(through date: Date) {
        let current = defaults.object(forKey: Self.lastSeenKey) as? Date ?? .distantPast
        defaults.set(max(current, date), forKey: Self.lastSeenKey)
    }
}
