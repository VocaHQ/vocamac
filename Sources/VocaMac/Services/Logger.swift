// Logger.swift
// VocaMac
//
// System-wide logging framework with os.Logger integration,
// persistent file logging, and automatic log rotation.

import Foundation
import os

/// Log categories for different services and components
enum LogCategory: String {
    case appState = "AppState"
    case audioEngine = "AudioEngine"
    case whisperService = "WhisperService"
    case hotKeyManager = "HotKeyManager"
    case modelManager = "ModelManager"
    case soundManager = "SoundManager"
    case textInjector = "TextInjector"
    case textPostProcessor = "TextPostProcessor"
    case cursorOverlay = "CursorOverlay"
    case updateChecker = "UpdateChecker"
    case onboarding = "Onboarding"
    case general = "General"
}

/// Log levels for filtering and categorization
enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

/// Unified logging framework for VocaMac
/// Combines os.Logger (Console.app integration) with persistent file logging
/// with automatic size-based rotation.
final class VocaLogger {
    // MARK: - Singleton

    static let shared = VocaLogger()

    // MARK: - Properties

    private let logDirectory: URL
    private let logFileURL: URL
    private let fileQueue = DispatchQueue(label: "com.vocamac.logger.file", attributes: .initiallyInactive)
    private let osLogger: os.Logger
    private var logFileHandle: FileHandle?
    private let logMaxSize = 1_000_000
    private let maxRotatedFiles = 3
    private var currentLogLevel: LogLevel = .info
    private var bytesWrittenSinceLastCheck: Int = 0
    private let rotationCheckInterval = 10_000
    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Initialization

    private init() {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.logDirectory = appSupportURL.appendingPathComponent("VocaMac/logs", isDirectory: true)
        self.logFileURL = logDirectory.appendingPathComponent("vocamac.log")
        self.osLogger = os.Logger(subsystem: "com.vocamac", category: "general")

        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true, attributes: nil)

        fileQueue.activate()

        fileQueue.async {
            self.cleanupOrphanedRotatedFiles()
            self.setupLogFile()
        }
    }

    // MARK: - Public API

    /// Set the global log level for file and console output
    static func setLogLevel(_ level: LogLevel) {
        VocaLogger.shared.currentLogLevel = level
    }

    /// Log a debug message
    static func debug(_ category: LogCategory, _ message: String) {
        VocaLogger.shared.log(message, level: .debug, category: category)
    }

    /// Log an info message
    static func info(_ category: LogCategory, _ message: String) {
        VocaLogger.shared.log(message, level: .info, category: category)
    }

    /// Log a warning message
    static func warning(_ category: LogCategory, _ message: String) {
        VocaLogger.shared.log(message, level: .warning, category: category)
    }

    /// Log an error message
    static func error(_ category: LogCategory, _ message: String) {
        VocaLogger.shared.log(message, level: .error, category: category)
    }

    /// Get the URL of the active log file
    static func logFileURL() -> URL {
        VocaLogger.shared.logFileURL
    }

    /// Get the log directory URL
    static func logDirectory() -> URL {
        VocaLogger.shared.logDirectory
    }

    /// Get the approximate number of log entries in the current log file
    static var logEntryCount: Int {
        guard let content = try? String(contentsOf: VocaLogger.shared.logFileURL, encoding: .utf8) else {
            return 0
        }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
    }

    /// Clear all log entries from the current log file
    static func clearLogs() {
        try? "".write(to: VocaLogger.shared.logFileURL, atomically: true, encoding: .utf8)
        VocaLogger.shared.fileQueue.async {
            VocaLogger.shared.bytesWrittenSinceLastCheck = 0
            VocaLogger.shared.logFileHandle?.seekToEndOfFile()
        }
        VocaLogger.info(.general, "Logs cleared")
    }

    /// Read the last N lines from the log file
    static func readLastLines(_ count: Int = 500) -> [String] {
        VocaLogger.shared.getLastLines(count)
    }

    /// Export logs as a formatted string with system info header
    static func exportLogs(lastLines: Int = 500) -> String {
        VocaLogger.shared.formatExportedLogs(lastLines: lastLines)
    }

    // MARK: - Private Methods

    private func log(_ message: String, level: LogLevel, category: LogCategory) {
        guard shouldLog(level: level) else { return }

        let timestamp = dateFormatter.string(from: Date())
        let formattedMessage = "[\(timestamp)] [\(level.rawValue)] [\(category.rawValue)] \(message)"

        let osLogType: OSLogType = level == .error ? .error : (level == .warning ? .default : .info)
        osLogger.log(level: osLogType, "\(formattedMessage)")

        let data = (formattedMessage + "\n").data(using: .utf8)
        fileQueue.async {
            self.writeToFile(data)
        }
    }

    private func shouldLog(level: LogLevel) -> Bool {
        switch (currentLogLevel, level) {
        case (.debug, _):
            return true
        case (.info, .debug):
            return false
        case (.info, _):
            return true
        case (.warning, .debug), (.warning, .info):
            return false
        case (.warning, _):
            return true
        case (.error, .error):
            return true
        case (.error, _):
            return false
        }
    }

    private func setupLogFile() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }

        logFileHandle = FileHandle(forWritingAtPath: logFileURL.path)
        logFileHandle?.seekToEndOfFile()

        checkAndRotateIfNeeded()
    }

    private func writeToFile(_ data: Data?) {
        guard let data, let handle = logFileHandle else { return }

        handle.write(data)
        bytesWrittenSinceLastCheck += data.count

        if bytesWrittenSinceLastCheck >= rotationCheckInterval {
            bytesWrittenSinceLastCheck = 0
            checkAndRotateIfNeeded()
        }
    }

    private func checkAndRotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? Int else {
            return
        }

        if size > logMaxSize {
            performRotation()
        }
    }

    private func performRotation() {
        logFileHandle?.closeFile()
        logFileHandle = nil

        for i in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
            let oldURL = logDirectory.appendingPathComponent("vocamac.\(i).log")
            let newURL = logDirectory.appendingPathComponent("vocamac.\(i + 1).log")

            if FileManager.default.fileExists(atPath: oldURL.path) {
                do {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                } catch {
                    osLogger.error("Log rotation: failed to move \(oldURL.lastPathComponent) to \(newURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        let rotatedURL = logDirectory.appendingPathComponent("vocamac.1.log")
        do {
            try FileManager.default.moveItem(at: logFileURL, to: rotatedURL)
        } catch {
            osLogger.error("Log rotation: failed to rotate current log: \(error.localizedDescription)")
            logFileHandle = FileHandle(forWritingAtPath: logFileURL.path)
            logFileHandle?.seekToEndOfFile()
            return
        }

        let oldestURL = logDirectory.appendingPathComponent("vocamac.\(maxRotatedFiles + 1).log")
        try? FileManager.default.removeItem(at: oldestURL)

        bytesWrittenSinceLastCheck = 0
        setupLogFile()
    }

    private func cleanupOrphanedRotatedFiles() {
        let fm = FileManager.default
        for i in (maxRotatedFiles + 1)...100 {
            let url = logDirectory.appendingPathComponent("vocamac.\(i).log")
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            } else {
                break
            }
        }
    }

    private func getLastLines(_ count: Int) -> [String] {
        var allLines: [String] = []

        if let currentContent = try? String(contentsOf: logFileURL, encoding: .utf8) {
            allLines.append(contentsOf: currentContent.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        }

        for i in 1...maxRotatedFiles {
            let rotatedURL = logDirectory.appendingPathComponent("vocamac.\(i).log")
            if let content = try? String(contentsOf: rotatedURL, encoding: .utf8) {
                allLines.insert(contentsOf: content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).reversed(), at: 0)
            }
        }

        return Array(allLines.suffix(count))
    }

    private func formatExportedLogs(lastLines: Int = 500) -> String {
        var result = ""

        result += "=== VocaMac Debug Log Export ===\n"
        result += "Generated: \(dateFormatter.string(from: Date()))\n"

        let capabilities = SystemInfo.detect()
        result += "Device: \(capabilities.processorName)\n"
        result += "Architecture: \(capabilities.isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)")\n"
        result += "RAM: \(capabilities.physicalMemoryGB) GB\n"
        result += "CPU Cores: \(capabilities.coreCount)\n"

        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            result += "App Version: \(appVersion)\n"
        }

        result += "================================\n\n"

        let lines = getLastLines(lastLines)
        for line in lines {
            if !line.isEmpty {
                result += line + "\n"
            }
        }

        return result
    }
}
