// AutoPauseMonitorTests.swift
// VocaMac Tests

import XCTest
@testable import VocaMac

@MainActor
final class AutoPauseMonitorTests: XCTestCase {

    func testNormalizeProcessName() {
        XCTAssertEqual(AutoPauseMatching.normalizeProcessName("  Foo.exe "), "foo")
        XCTAssertEqual(AutoPauseMatching.normalizeProcessName("/usr/bin/Game"), "game")
        XCTAssertEqual(AutoPauseMatching.normalizeProcessName(""), "")
    }

    func testEmptyConfiguredListNeverMatches() {
        let running = [
            RunningAppSnapshot(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", processName: "Xcode")
        ]
        XCTAssertFalse(
            AutoPauseMatching.anyConfiguredAppRunning(configured: [], running: running)
        )
    }

    func testMatchByBundleIdentifier() {
        let configured = [
            AutoPauseAppEntry(
                id: "com.valvesoftware.steam",
                displayName: "Steam",
                bundleIdentifier: "com.valvesoftware.steam",
                processName: "steam_osx"
            )
        ]
        let running = [
            RunningAppSnapshot(
                displayName: "Steam",
                bundleIdentifier: "com.valvesoftware.steam",
                processName: "steam_osx"
            )
        ]
        XCTAssertTrue(AutoPauseMatching.anyConfiguredAppRunning(configured: configured, running: running))
    }

    func testMatchByProcessName() {
        let configured = [
            AutoPauseAppEntry(
                id: "demo_game",
                displayName: "demo_game",
                bundleIdentifier: nil,
                processName: "demo_game"
            )
        ]
        let running = [
            RunningAppSnapshot(displayName: "demo_game", bundleIdentifier: nil, processName: "demo_game")
        ]
        XCTAssertTrue(AutoPauseMatching.anyConfiguredAppRunning(configured: configured, running: running))
    }

    func testNoMatchWhenDifferentApps() {
        let configured = [
            AutoPauseAppEntry(id: "com.a", displayName: "A", bundleIdentifier: "com.a", processName: "A")
        ]
        let running = [
            RunningAppSnapshot(displayName: "B", bundleIdentifier: "com.b", processName: "B")
        ]
        XCTAssertFalse(AutoPauseMatching.anyConfiguredAppRunning(configured: configured, running: running))
    }

    func testMonitorTransitionCallbacks() {
        var paused = false
        var pauseCount = 0
        var resumeCount = 0
        var snapshot: [RunningAppSnapshot] = []

        let entry = AutoPauseAppEntry(
            id: "com.test.game",
            displayName: "Game",
            bundleIdentifier: "com.test.game",
            processName: "Game"
        )

        let monitor = AutoPauseMonitor(
            getConfig: { (true, [entry], 5) },
            processSnapshot: { snapshot },
            onPause: {
                paused = true
                pauseCount += 1
            },
            onResume: {
                paused = false
                resumeCount += 1
            }
        )

        XCTAssertFalse(monitor.checkOnce())
        XCTAssertFalse(monitor.isPaused)

        snapshot = [
            RunningAppSnapshot(displayName: "Game", bundleIdentifier: "com.test.game", processName: "Game")
        ]
        XCTAssertTrue(monitor.checkOnce())
        XCTAssertTrue(monitor.isPaused)
        XCTAssertEqual(pauseCount, 1)

        // Second poll while still matching must not re-fire onPause
        XCTAssertTrue(monitor.checkOnce())
        XCTAssertEqual(pauseCount, 1)

        snapshot = []
        XCTAssertFalse(monitor.checkOnce())
        XCTAssertFalse(monitor.isPaused)
        XCTAssertEqual(resumeCount, 1)
        XCTAssertFalse(paused)
    }

    func testDisabledClearsPause() {
        var resumeCount = 0
        var enabled = true
        let entry = AutoPauseAppEntry(
            id: "com.test.game",
            displayName: "Game",
            bundleIdentifier: "com.test.game",
            processName: "Game"
        )
        let snapshot = [
            RunningAppSnapshot(displayName: "Game", bundleIdentifier: "com.test.game", processName: "Game")
        ]

        let monitor = AutoPauseMonitor(
            getConfig: { (enabled, [entry], 5) },
            processSnapshot: { snapshot },
            onPause: {},
            onResume: { resumeCount += 1 }
        )

        XCTAssertTrue(monitor.checkOnce())
        XCTAssertTrue(monitor.isPaused)

        enabled = false
        XCTAssertFalse(monitor.checkOnce())
        XCTAssertFalse(monitor.isPaused)
        XCTAssertEqual(resumeCount, 1)
    }

    func testClampPollInterval() {
        XCTAssertEqual(AutoPauseMonitor.clampPollInterval(0.5), 1)
        XCTAssertEqual(AutoPauseMonitor.clampPollInterval(5), 5)
        XCTAssertEqual(AutoPauseMonitor.clampPollInterval(120), 60)
    }
}
