// Logger.swift
// VocaMac
//
// System-wide logging framework with os.Logger integration,
// persistent file logging, and automatic log rotation.

import Foundation
import os
import Darwin

/// Bounded, cross-process-safe storage for VocaMac's rolling text logs.
enum LogFileStore {
    static let activeName = "vocamac.log"
    static let lockName = ".vocamac.lock"

    static func withExclusiveLock<T>(in directory: URL, _ body: () throws -> T) rethrows -> T {
        let lockURL = directory.appendingPathComponent(lockName)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return try body() }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        flock(descriptor, LOCK_EX)
        return try body()
    }

    static func rotate(
        in directory: URL,
        maxRotatedFiles: Int,
        maximumFileSize: Int? = nil,
        fileManager: FileManager = .default
    ) throws {
        guard maxRotatedFiles > 0 else { return }
        let oldest = directory.appendingPathComponent("vocamac.\(maxRotatedFiles).log")
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        if maxRotatedFiles > 1 {
            for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
                let source = directory.appendingPathComponent("vocamac.\(index).log")
                let destination = directory.appendingPathComponent("vocamac.\(index + 1).log")
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        }
        let active = directory.appendingPathComponent(activeName)
        if fileManager.fileExists(atPath: active.path) {
            let rotated = directory.appendingPathComponent("vocamac.1.log")
            try fileManager.moveItem(at: active, to: rotated)
            if let maximumFileSize {
                try trimToTail(at: rotated, maximumBytes: maximumFileSize)
            }
        }
    }

    /// Keep a legacy oversized log bounded while preserving its newest entries.
    static func trimToTail(at url: URL, maximumBytes: Int) throws {
        guard maximumBytes > 0 else {
            try Data().write(to: url, options: .atomic)
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > maximumBytes else { return }

        // Inspect the preceding byte so a cutoff at a complete line does not
        // discard that line. Only drop a partial leading entry.
        try handle.seek(toOffset: size - UInt64(maximumBytes) - 1)
        let precedingByte = try handle.read(upToCount: 1)?.first
        var tail = try handle.readToEnd() ?? Data()
        if precedingByte != 0x0A, let newline = tail.firstIndex(of: 0x0A) {
            tail.removeSubrange(tail.startIndex...newline)
        } else if precedingByte != 0x0A {
            // No complete entry fits; avoid writing a partial UTF-8 sequence.
            tail.removeAll()
        }
        try tail.write(to: url, options: .atomic)
    }

    /// Read only enough of a file's tail to satisfy `count` complete lines.
    static func tailLines(at url: URL, count: Int, chunkSize: Int = 64 * 1024) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        var offset = size
        var data = Data()
        while offset > 0 {
            let bytes = min(UInt64(chunkSize), offset)
            offset -= bytes
            do {
                try handle.seek(toOffset: offset)
                if let chunk = try handle.read(upToCount: Int(bytes)) {
                    data.insert(contentsOf: chunk, at: 0)
                }
            } catch {
                return []
            }
            if data.reduce(into: 0, { $0 += $1 == 0x0A ? 1 : 0 }) > count {
                break
            }
        }

        // If the read began mid-file, discard the partial leading line.
        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(count)
            .map(String.init)
    }

    static func lineCount(at url: URL, chunkSize: Int = 64 * 1024) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        var count = 0
        while true {
            guard let data = try? handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            count += data.reduce(into: 0) { $0 += $1 == 0x0A ? 1 : 0 }
        }
        return count
    }
}

/// Log categories for different services and components
enum LogCategory: String {
    case appState = "AppState"
    case audioEngine = "AudioEngine"
    case whisperService = "WhisperService"
    case parakeetService = "ParakeetService"
    case appleSpeechService = "AppleSpeechService"
    case sherpaService = "SherpaService"
    case hotKeyManager = "HotKeyManager"
    case modelManager = "ModelManager"
    case soundManager = "SoundManager"
    case textInjector = "TextInjector"
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
        self.logFileURL = logDirectory.appendingPathComponent(LogFileStore.activeName)
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
        let logger = VocaLogger.shared
        return LogFileStore.withExclusiveLock(in: logger.logDirectory) {
            LogFileStore.lineCount(at: logger.logFileURL)
        }
    }

    /// Clear all log entries from the current log file
    static func clearLogs() {
        let logger = VocaLogger.shared
        logger.fileQueue.sync {
            LogFileStore.withExclusiveLock(in: logger.logDirectory) {
                try? Data().write(to: logger.logFileURL)
                for index in 1...logger.maxRotatedFiles {
                    try? FileManager.default.removeItem(
                        at: logger.logDirectory.appendingPathComponent("vocamac.\(index).log")
                    )
                }
            }
            logger.bytesWrittenSinceLastCheck = 0
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
        LogFileStore.withExclusiveLock(in: logDirectory) {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
            }
            checkAndRotateIfNeeded()
        }
    }

    private func writeToFile(_ data: Data?) {
        guard let data else { return }
        LogFileStore.withExclusiveLock(in: logDirectory) {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: logFileURL.path) else { return }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                bytesWrittenSinceLastCheck += data.count
                if bytesWrittenSinceLastCheck >= rotationCheckInterval {
                    bytesWrittenSinceLastCheck = 0
                    checkAndRotateIfNeeded()
                }
            } catch {
                osLogger.error("Log write failed: \(error.localizedDescription)")
            }
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
        do {
            try LogFileStore.rotate(
                in: logDirectory,
                maxRotatedFiles: maxRotatedFiles,
                maximumFileSize: logMaxSize
            )
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        } catch {
            osLogger.error("Log rotation failed: \(error.localizedDescription)")
            return
        }
        bytesWrittenSinceLastCheck = 0
    }

    private func cleanupOrphanedRotatedFiles() {
        LogFileStore.withExclusiveLock(in: logDirectory) {
            let fileManager = FileManager.default
            let files = (try? fileManager.contentsOfDirectory(
                at: logDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "log", name.hasPrefix("vocamac."),
                      let index = Int(name.dropFirst("vocamac.".count)),
                      index > maxRotatedFiles else {
                    continue
                }
                try? fileManager.removeItem(at: file)
            }
        }
    }

    private func getLastLines(_ count: Int) -> [String] {
        guard count > 0 else { return [] }
        return LogFileStore.withExclusiveLock(in: logDirectory) {
            var result = LogFileStore.tailLines(at: logFileURL, count: count)
            for index in 1...maxRotatedFiles where result.count < count {
                let older = LogFileStore.tailLines(
                    at: logDirectory.appendingPathComponent("vocamac.\(index).log"),
                    count: count - result.count
                )
                result.insert(contentsOf: older, at: 0)
            }
            return Array(result.suffix(count))
        }
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
