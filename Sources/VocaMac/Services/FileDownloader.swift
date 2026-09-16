// FileDownloader.swift
// VocaMac
//
// Minimal file downloader with real progress reporting, used for model
// archives that engines don't download themselves (sherpa-onnx).

import Foundation
import os

/// Drops progress updates that arrive faster than the UI can use them.
///
/// URLSession reports every write, often hundreds of times a second, and each
/// report that reaches the main actor re-renders every view observing the
/// download. The first value and completion always pass.
final class ProgressThrottle: @unchecked Sendable {
    private struct State {
        var lastValue: Double?
        var lastTime: TimeInterval = 0
    }

    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        minimumInterval: TimeInterval = 0.1,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
    }

    /// Whether `progress` should be forwarded: the first value, completion,
    /// or a changed value at least `minimumInterval` after the last one sent.
    func shouldDeliver(_ progress: Double) -> Bool {
        let time = now()
        return state.withLock { state in
            if let last = state.lastValue {
                // Nothing after completion: a late tick would move a
                // finished bar backwards.
                guard last < 1.0 else { return false }
                let completes = progress >= 1.0
                let due = progress != last && time - state.lastTime >= minimumInterval
                guard completes || due else { return false }
            }
            state.lastValue = progress
            state.lastTime = time
            return true
        }
    }

    /// Wrap a progress handler so only throttled values reach it.
    static func wrap(
        _ handler: @escaping (Double) -> Void,
        throttle: ProgressThrottle = ProgressThrottle()
    ) -> (Double) -> Void {
        { progress in
            if throttle.shouldDeliver(progress) { handler(progress) }
        }
    }
}

enum FileDownloaderError: LocalizedError {
    case badResponse(statusCode: Int)
    case moveFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let statusCode):
            return "Server returned HTTP \(statusCode)."
        case .moveFailed(let reason):
            return "Could not store the downloaded file: \(reason)"
        }
    }
}

/// Downloads a URL to a destination file, reporting fractional progress.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let onProgress: (Double) -> Void
    private let progressThrottle = ProgressThrottle()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    /// Guards the continuation and task against the delegate callbacks, which
    /// arrive on the session queue, racing cancellation from the caller.
    private let stateLock = NSLock()

    private init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    /// Download `url` to `destination`, overwriting any existing file.
    /// - Parameter onProgress: Called with values in 0...1. Invoked on a
    ///   background queue; hop to the main actor for UI updates.
    static func download(
        from url: URL,
        to destination: URL,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        let downloader = FileDownloader(destination: destination, onProgress: onProgress)
        let session = URLSession(
            configuration: .default,
            delegate: downloader,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        // Model archives run to hundreds of megabytes, so a cancelled task
        // must stop the transfer rather than leave it running in the
        // background burning battery and disk.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = session.downloadTask(with: url)
                downloader.begin(task: task, continuation: continuation)
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    /// Store the in-flight task and continuation, or cancel immediately if
    /// cancellation already arrived.
    private func begin(task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
        stateLock.lock()
        if isCancelled {
            stateLock.unlock()
            // Cancel the suspended task; finishTasksAndInvalidate alone would
            // wait for it rather than drop it.
            task.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        self.task = task
        stateLock.unlock()
        task.resume()
    }

    /// Cancel the transfer and fail the awaiting caller.
    private func cancel() {
        stateLock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        let continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()

        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard progressThrottle.shouldDeliver(progress) else { return }
        onProgress(progress)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(with: FileDownloaderError.badResponse(statusCode: response.statusCode))
            return
        }

        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            finish(with: nil)
        } catch {
            finish(with: FileDownloaderError.moveFailed(reason: error.localizedDescription))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(with: error)
        }
    }

    private func finish(with error: Error?) {
        stateLock.lock()
        guard let continuation else {
            stateLock.unlock()
            return
        }
        self.continuation = nil
        self.task = nil
        stateLock.unlock()

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
