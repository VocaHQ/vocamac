// ShortcutsLibrary.swift
// VocaMac
//
// The names of the user's Shortcuts, so a voice action can tell when an
// allowed shortcut no longer exists (renamed or deleted). Opening a
// `shortcuts://run-shortcut` URL succeeds either way: only the Shortcuts app
// shows the error, and VocaMac reported the action as done.

import Foundation

enum ShortcutsLibrary {
    private static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// The user's shortcut names, or nil when they can't be read: the App
    /// Store build (no launching programs outside the bundle), the tool
    /// missing, an error, or no answer within `timeout`. Callers then run the
    /// shortcut as before rather than refuse it.
    static func installedNames(timeout: TimeInterval = 2) async -> [String]? {
#if APP_STORE
        return nil
#else
        guard FileManager.default.isExecutableFile(atPath: tool.path) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runList(timeout: timeout))
            }
        }
#endif
    }

    /// The installed spelling of `name`: an exact match first, then one that
    /// differs only in case. Nil when no shortcut has that name.
    static func installedName(matching name: String, in installed: [String]) -> String? {
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let exact = installed.first(where: { $0 == wanted }) { return exact }
        return installed.first { $0.compare(wanted, options: .caseInsensitive) == .orderedSame }
    }

    /// Splits `shortcuts list` output into names.
    static func names(fromListOutput output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

#if !APP_STORE
    /// Runs `shortcuts list` on the calling (background) thread.
    private static func runList(timeout: TimeInterval) -> [String]? {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            VocaLogger.warning(.general, "Couldn't list Shortcuts: \(error.localizedDescription)")
            return nil
        }
        // Only terminated from the timer; Process is thread-safe for that.
        let box = UncheckedSendableBox(process)
        let timer = DispatchWorkItem {
            if box.value.isRunning { box.value.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else {
            VocaLogger.warning(.general, "Couldn't list Shortcuts (status \(process.terminationStatus))")
            return nil
        }
        return names(fromListOutput: text)
    }
#endif
}
