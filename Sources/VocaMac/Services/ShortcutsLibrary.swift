// ShortcutsLibrary.swift
// VocaMac
//
// The names of the user's Shortcuts, so a voice action can tell when an
// allowed shortcut no longer exists (renamed or deleted). Opening a
// `shortcuts://run-shortcut` URL succeeds either way: only the Shortcuts app
// shows the error, and VocaMac reported the action as done.

import Foundation
import os

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
        return await names(within: timeout) { runList(timeout: timeout) }
#endif
    }

    /// Runs `list` on a background thread and answers with its result, or
    /// nil at `deadline` whichever comes first. The deadline holds even if
    /// `list` never returns (a child that ignores termination): the caller
    /// is never kept waiting past it.
    static func names(
        within deadline: TimeInterval,
        list: @escaping @Sendable () -> [String]?
    ) async -> [String]? {
        await withCheckedContinuation { continuation in
            // Resumed exactly once, by whichever side gets here first.
            let pending = OSAllocatedUnfairLock<CheckedContinuation<[String]?, Never>?>(initialState: continuation)
            let finish: @Sendable ([String]?) -> Void = { names in
                pending.withLock { pending in
                    pending?.resume(returning: names)
                    pending = nil
                }
            }
            DispatchQueue.global(qos: .userInitiated).async { finish(list()) }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                finish(nil)
            }
        }
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
        // Only stopped from the timer; Process is thread-safe for that. A
        // child that ignores SIGTERM is killed a second later, so this thread
        // (already abandoned by `names(within:)`) doesn't wait on it forever.
        let box = UncheckedSendableBox(process)
        let timer = DispatchWorkItem {
            guard box.value.isRunning else { return }
            box.value.terminate()
            let pid = box.value.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if box.value.isRunning { kill(pid, SIGKILL) }
            }
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
