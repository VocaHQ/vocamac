// ToolProcess.swift
// VocaMac
//
// Runs a system tool (tar, hdiutil, ditto) to completion from async code.
// Not in the App Store build, which can't start programs outside its bundle.

#if !APP_STORE
import Foundation

enum ToolProcess {

    /// How a tool run ended.
    struct Outcome: Sendable {
        let status: Int32
        /// What the tool wrote to standard error, trimmed.
        let errorOutput: String

        /// The error output, or "<tool> exited with <status>" when it wrote none.
        func failureReason(tool: String) -> String {
            errorOutput.isEmpty
                ? "\(URL(fileURLWithPath: tool).lastPathComponent) exited with \(status)"
                : errorOutput
        }
    }

    /// Run `tool` and wait for it to exit.
    ///
    /// Waits on the termination handler rather than `waitUntilExit`, which
    /// can miss the exit when called from a concurrency thread and block
    /// forever. Standard error goes to a file, so a chatty tool can't fill a
    /// pipe and stall. Cancelling the calling task terminates the tool and
    /// throws `CancellationError`.
    static func run(_ tool: String, _ arguments: [String]) async throws -> Outcome {
        try Task.checkCancellation()
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocaMac-tool-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        let errors = try FileHandle(forWritingTo: errorFile)
        defer { try? errors.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let handle = ProcessHandle(process)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                    // Cancelled before launch: the handler found nothing to stop.
                    if Task.isCancelled { handle.terminate() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }
        try Task.checkCancellation()

        let message = (try? String(contentsOf: errorFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Outcome(status: status, errorOutput: message)
    }
}

/// Lets the cancellation handler, which may run on any thread, stop the tool.
///
/// @unchecked Sendable: the wrapped `Process` is only read here, and
/// `terminate()` just signals the child; it is safe to call from any thread,
/// including before launch (a no-op) or after exit.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }
}
#endif
