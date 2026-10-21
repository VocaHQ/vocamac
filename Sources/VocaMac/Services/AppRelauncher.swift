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
    ///   then keeps running. The App Store build only learns that later, so it
    ///   returns `true` and reports a failure in an alert instead.
    @discardableResult
    static func relaunch() -> Bool {
#if APP_STORE
        // The sandbox can't run /usr/bin/open; ask Launch Services instead.
        // It answers later, so this one quits only once the new one started.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--restarted"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            Task { @MainActor in
                if let error {
                    VocaLogger.error(.general, "Couldn't relaunch VocaMac: \(error.localizedDescription)")
                    let alert = NSAlert()
                    alert.messageText = "VocaMac couldn't reopen itself"
                    alert.informativeText = "Quit it from the menu bar and open it again."
                    alert.runModal()
                    return
                }
                VocaLogger.info(.general, "Relaunching VocaMac")
                try? await Task.sleep(for: .milliseconds(500))
                NSApplication.shared.terminate(nil)
            }
        }
        return true
#else
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
#endif
    }
}
