// LoggerTests.swift
// VocaMac
//
// Tests for VocaLogger, LogCategory, and LogLevel.

import XCTest
@testable import VocaMac

// MARK: - LogCategory Tests

final class LogCategoryTests: XCTestCase {

    func testAllCategoriesHaveRawValues() {
        let categories: [LogCategory] = [
            .appState, .audioEngine, .whisperService, .parakeetService,
            .appleSpeechService, .sherpaService, .hotKeyManager, .modelManager,
            .soundManager, .textInjector, .cursorOverlay, .onboarding, .general
        ]

        for category in categories {
            XCTAssertFalse(category.rawValue.isEmpty,
                          "LogCategory.\(category) should have a non-empty raw value")
        }
    }

    func testCategoryRawValuesAreCapitalized() {
        // Convention: category raw values should start with an uppercase letter
        let categories: [LogCategory] = [
            .appState, .audioEngine, .whisperService, .parakeetService,
            .appleSpeechService, .sherpaService, .hotKeyManager, .modelManager,
            .soundManager, .textInjector, .cursorOverlay, .onboarding, .general
        ]

        for category in categories {
            let first = category.rawValue.first!
            XCTAssertTrue(first.isUppercase,
                         "LogCategory.\(category) raw value '\(category.rawValue)' should start with uppercase")
        }
    }

    func testCategoryCount() {
        // Ensure we're testing all categories — update this if new ones are added
        let expectedCount = 13
        let categories: [LogCategory] = [
            .appState, .audioEngine, .whisperService, .parakeetService,
            .appleSpeechService, .sherpaService, .hotKeyManager, .modelManager,
            .soundManager, .textInjector, .cursorOverlay, .onboarding, .general
        ]
        XCTAssertEqual(categories.count, expectedCount)
    }
}

// MARK: - LogLevel Tests

final class LogLevelTests: XCTestCase {

    func testLogLevelRawValues() {
        XCTAssertEqual(LogLevel.debug.rawValue, "DEBUG")
        XCTAssertEqual(LogLevel.info.rawValue, "INFO")
        XCTAssertEqual(LogLevel.warning.rawValue, "WARNING")
        XCTAssertEqual(LogLevel.error.rawValue, "ERROR")
    }

    func testLogLevelCount() {
        let levels: [LogLevel] = [.debug, .info, .warning, .error]
        XCTAssertEqual(levels.count, 4)
    }

    func testLogLevelsAreDistinct() {
        let levels: [LogLevel] = [.debug, .info, .warning, .error]
        let unique = Set(levels.map { $0.rawValue })
        XCTAssertEqual(unique.count, 4, "All log levels should have unique raw values")
    }
}

// MARK: - VocaLogger Tests

final class VocaLoggerTests: XCTestCase {

    func testTrimPreservesCompleteLineAtExactCutoff() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("old\nनमस्ते\n".utf8).write(to: file)
        try LogFileStore.trimToTail(at: file, maximumBytes: Data("नमस्ते\n".utf8).count)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "नमस्ते\n")
    }

    func testTrimDoesNotKeepPartialUnicodeEntry() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("नमस्ते".utf8).write(to: file)
        try LogFileStore.trimToTail(at: file, maximumBytes: 2)
        XCTAssertEqual(try Data(contentsOf: file), Data())
    }

    func testRotationReplacesFullBackupSetAndPreservesOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, contents) in [
            ("vocamac.log", "current"),
            ("vocamac.1.log", "one"),
            ("vocamac.2.log", "two"),
            ("vocamac.3.log", "three"),
        ] {
            try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
        }

        try LogFileStore.rotate(in: directory, maxRotatedFiles: 3)

        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("vocamac.1.log")), "current")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("vocamac.2.log")), "one")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("vocamac.3.log")), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocamac.log").path))
    }

    func testTailReaderHandlesLargeFileAndUnicodeBoundary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = (0..<20_000).map { "line-\($0)-नमस्ते" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(LogFileStore.tailLines(at: file, count: 3), Array(lines.suffix(3)))
        XCTAssertEqual(LogFileStore.lineCount(at: file), lines.count)
        XCTAssertEqual(LogFileStore.tailLines(at: file, count: 0), [])
    }

    func testRotationBoundsLegacyOversizedLog() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lines = (0..<100).map { "entry-\($0)-with-padding" }
        try (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent(LogFileStore.activeName),
            atomically: true,
            encoding: .utf8
        )

        try LogFileStore.rotate(in: directory, maxRotatedFiles: 3, maximumFileSize: 256)

        let rotated = directory.appendingPathComponent("vocamac.1.log")
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: rotated.path)[.size] as? Int
        )
        XCTAssertLessThanOrEqual(size, 256)
        XCTAssertEqual(LogFileStore.tailLines(at: rotated, count: 1), [try XCTUnwrap(lines.last)])
    }

    func testLogFileURLIsValid() {
        let url = VocaLogger.logFileURL()
        XCTAssertFalse(url.path.isEmpty, "Log file URL should not be empty")
        XCTAssertTrue(url.path.contains("VocaMac"), "Log path should contain app name")
        XCTAssertTrue(url.path.hasSuffix(".log"), "Log file should have .log extension")
    }

    func testLogDirectoryIsValid() {
        let url = VocaLogger.logDirectory()
        XCTAssertFalse(url.path.isEmpty, "Log directory URL should not be empty")
        XCTAssertTrue(url.path.contains("VocaMac"), "Log directory should contain app name")
        XCTAssertTrue(url.path.contains("logs"), "Log directory should contain 'logs'")
    }

    func testLogEntryCountIsNonNegative() {
        let count = VocaLogger.logEntryCount
        XCTAssertGreaterThanOrEqual(count, 0, "Log entry count should never be negative")
    }

    func testSetLogLevel() {
        // Should not crash when setting any log level
        VocaLogger.setLogLevel(.debug)
        VocaLogger.setLogLevel(.info)
        VocaLogger.setLogLevel(.warning)
        VocaLogger.setLogLevel(.error)

        // Reset to default
        VocaLogger.setLogLevel(.info)
    }

    func testLoggingAtAllLevels() {
        // Should not crash when logging at any level with any category
        VocaLogger.debug(.general, "Test debug message")
        VocaLogger.info(.general, "Test info message")
        VocaLogger.warning(.general, "Test warning message")
        VocaLogger.error(.general, "Test error message")
    }

    func testLoggingWithDifferentCategories() {
        VocaLogger.info(.appState, "Test appState log")
        VocaLogger.info(.audioEngine, "Test audioEngine log")
        VocaLogger.info(.whisperService, "Test whisperService log")
        VocaLogger.info(.hotKeyManager, "Test hotKeyManager log")
        VocaLogger.info(.general, "Test general log")
    }

    func testReadLastLinesReturnsArray() {
        let lines = VocaLogger.readLastLines(10)
        XCTAssertTrue(lines is [String], "readLastLines should return an array of strings")
    }

    func testReadLastLinesRespectCount() {
        let lines = VocaLogger.readLastLines(5)
        XCTAssertLessThanOrEqual(lines.count, 5 + 50,
                                 "readLastLines should not return dramatically more than requested")
    }

    func testExportLogsContainsHeader() {
        let exported = VocaLogger.exportLogs(lastLines: 10)
        XCTAssertTrue(exported.contains("VocaMac Debug Log Export"),
                     "Exported logs should contain the header")
        XCTAssertTrue(exported.contains("Device:"),
                     "Exported logs should contain device info")
    }

    func testExportLogsContainsSystemInfo() {
        let exported = VocaLogger.exportLogs(lastLines: 5)
        XCTAssertTrue(exported.contains("Architecture:"),
                     "Exported logs should include architecture")
        XCTAssertTrue(exported.contains("RAM:"),
                     "Exported logs should include RAM info")
        XCTAssertTrue(exported.contains("CPU Cores:"),
                     "Exported logs should include CPU core count")
    }

    func testLogLevelFilteringDebugShowsAll() {
        // When log level is debug, all messages should be logged
        VocaLogger.setLogLevel(.debug)
        let countBefore = VocaLogger.logEntryCount

        VocaLogger.debug(.general, "test-debug-\(UUID().uuidString)")
        VocaLogger.info(.general, "test-info-\(UUID().uuidString)")
        VocaLogger.warning(.general, "test-warning-\(UUID().uuidString)")
        VocaLogger.error(.general, "test-error-\(UUID().uuidString)")

        // Allow file write to complete
        Thread.sleep(forTimeInterval: 0.2)

        let countAfter = VocaLogger.logEntryCount
        XCTAssertGreaterThanOrEqual(countAfter, countBefore + 4,
                                    "All 4 log levels should produce entries at debug level")

        // Reset
        VocaLogger.setLogLevel(.info)
    }

    func testLogLevelFilteringErrorHidesLower() {
        VocaLogger.setLogLevel(.error)
        let countBefore = VocaLogger.logEntryCount

        let marker = UUID().uuidString
        VocaLogger.debug(.general, "should-not-appear-\(marker)")
        VocaLogger.info(.general, "should-not-appear-\(marker)")
        VocaLogger.warning(.general, "should-not-appear-\(marker)")

        Thread.sleep(forTimeInterval: 0.2)

        let countAfterLower = VocaLogger.logEntryCount

        VocaLogger.error(.general, "should-appear-\(marker)")

        Thread.sleep(forTimeInterval: 0.2)

        let countAfterError = VocaLogger.logEntryCount

        // Debug, info, warning should have been filtered
        XCTAssertEqual(countAfterLower, countBefore,
                      "Debug/info/warning messages should be filtered at error level")
        XCTAssertEqual(countAfterError, countBefore + 1,
                      "Error message should be logged at error level")

        // Reset
        VocaLogger.setLogLevel(.info)
    }
}
