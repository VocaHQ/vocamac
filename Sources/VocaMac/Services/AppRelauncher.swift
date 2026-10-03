// AppRelauncher.swift
// VocaMac
//
// Quits VocaMac and opens it again.

import AppKit

/// Quits VocaMac and opens a fresh copy.
///
/// macOS applies some privacy grants only to a process started after the
/// grant: Input Monitoring always, Accessibility sometimes. Onboarding resumes
/// on the step it was on, because `OnboardingView` saves its step as it moves.
@MainActor
enum AppRelauncher {

    /// Start a new instance, then quit this one. The new instance also ends
    /// this one on launch (`ensureSingleInstance`), so the two never both
    /// hold the hotkey for long.
    ///
    /// - Returns: `false` when the new instance couldn't be started; this one
    ///   then keeps running.
    @discardableResult
    static func relaunch() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath, "--args", "--restarted"]
        do {
            try task.run()
        } catch {
            VocaLogger.error(.general, "Couldn't relaunch VocaMac: \(error.localizedDescription)")
            return false
        }

        VocaLogger.info(.general, "Relaunching VocaMac")
        Task { @MainActor in
            // Give the new instance a moment to start.
            try? await Task.sleep(for: .milliseconds(500))
            NSApplication.shared.terminate(nil)
        }
        return true
    }
}
