// FileDownloader.swift
// VocaMac
//
// Minimal file downloader with real progress reporting, used for model
// archives that engines don't download themselves (sherpa-onnx, cleanup
// GGUFs). Interrupted transfers resume where they stopped.

import CryptoKit
import Foundation
import os
import VocaMacObjC

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

/// Keeps URLSession resume data for interrupted downloads, keyed by source URL.
///
/// Callers download into a staging name that is new on every attempt, so the
/// key is the URL, not the destination. Resume data is a small plist; the
/// partial bytes it points at live in URLSession's own temporary folder. If
/// macOS has purged them, the resume fails and the download starts over.
final class DownloadResumeStore: @unchecked Sendable {

    static let shared = DownloadResumeStore(directory: defaultDirectory)

    private let directory: URL?
    private let lock = NSLock()

    init(directory: URL?) {
        self.directory = directory
    }

    private static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.vocamac.app", isDirectory: true)
            .appendingPathComponent("DownloadResume", isDirectory: true)
    }

    func load(for url: URL) -> Data? {
        guard let file = file(for: url) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return try? Data(contentsOf: file)
    }

    func save(_ data: Data, for url: URL) {
        guard let directory, let file = file(for: url) else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            VocaLogger.warning(.modelManager, "Could not keep resume data for \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func remove(for url: URL) {
        guard let file = file(for: url) else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
    }

    private func file(for url: URL) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(digest).resume")
    }
}

/// Downloads a URL to a destination file, reporting fractional progress.
///
/// A dropped connection no longer throws away what was already transferred:
/// each attempt keeps URLSession's resume data, transient network errors are
/// retried from where they stopped, and a later download of the same URL
/// (after a cancel, a failure, or a relaunch) picks up from there too.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    /// Attempts per call, counting the first. Only transient network errors,
    /// or a resume that the server or cache could not honour, are retried.
    static let maxAttempts = 4

    private let source: URL
    private let destination: URL
    private let resumeStore: DownloadResumeStore
    private let onProgress: (Double) -> Void
    private let progressThrottle = ProgressThrottle()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var isCancelled = false

    /// Guards the continuation and task against the delegate callbacks, which
    /// arrive on the session queue, racing cancellation from the caller.
    private let stateLock = NSLock()

    private init(
        source: URL,
        destination: URL,
        resumeStore: DownloadResumeStore,
        onProgress: @escaping (Double) -> Void
    ) {
        self.source = source
        self.destination = destination
        self.resumeStore = resumeStore
        self.onProgress = onProgress
    }

    /// Download `url` to `destination`, overwriting any existing file.
    /// - Parameter onProgress: Called with values in 0...1. Invoked on a
    ///   background queue; hop to the main actor for UI updates.
    static func download(
        from url: URL,
        to destination: URL,
        resumeStore: DownloadResumeStore = .shared,
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        var attempt = 0
        while true {
            attempt += 1
            let resumeData = resumeStore.load(for: url).flatMap(usableResumeData)
            do {
                try await downloadOnce(
                    from: url,
                    to: destination,
                    resumeData: resumeData,
                    resumeStore: resumeStore,
                    onProgress: onProgress
                )
                resumeStore.remove(for: url)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let newResumeData = (error as? URLError)?.downloadTaskResumeData
                if let newResumeData {
                    resumeStore.save(newResumeData, for: url)
                } else {
                    // Nothing to resume from: start the next attempt over.
                    resumeStore.remove(for: url)
                }
                let decision = retryDecision(
                    after: error,
                    attempt: attempt,
                    resumed: resumeData != nil,
                    hasResumeData: newResumeData != nil
                )
                guard let delay = decision else { throw error }
                VocaLogger.warning(
                    .modelManager,
                    "Download of \(url.lastPathComponent) interrupted (\(error.localizedDescription)); "
                        + (newResumeData != nil ? "resuming" : "retrying")
                        + " in \(Int(delay))s (attempt \(attempt + 1) of \(maxAttempts))"
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Seconds to wait before the next attempt, or nil to give up.
    ///
    /// Transient network errors are retried with a growing delay. A failed
    /// resume (stale resume data, purged partial file, server refusing the
    /// range) is retried once from scratch straight away.
    static func retryDecision(after error: Error, attempt: Int, resumed: Bool, hasResumeData: Bool) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        if isTransient(error) {
            return [1, 3, 8][min(attempt - 1, 2)]
        }
        if resumed && !hasResumeData {
            return 0
        }
        return nil
    }

    /// Network failures that a wait and a retry can get past.
    static func isTransient(_ error: Error) -> Bool {
        if case FileDownloaderError.badResponse(let statusCode) = error {
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func downloadOnce(
        from url: URL,
        to destination: URL,
        resumeData: Data?,
        resumeStore: DownloadResumeStore,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        let downloader = FileDownloader(
            source: url,
            destination: destination,
            resumeStore: resumeStore,
            onProgress: onProgress
        )
        let session = URLSession(
            configuration: .default,
            delegate: downloader,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        if resumeData != nil {
            VocaLogger.info(.modelManager, "Resuming download of \(url.lastPathComponent)")
        }

        // Model archives run to hundreds of megabytes, so a cancelled task
        // must stop the transfer rather than leave it running in the
        // background burning battery and disk.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let task = resumeData.flatMap { resumeTask(in: session, from: $0, for: url, store: resumeStore) }
                    ?? session.downloadTask(with: url)
                downloader.begin(task: task, continuation: continuation)
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    /// Resume data URLSession could plausibly accept: a property list
    /// dictionary. Anything else (a truncated or foreign file) is dropped.
    static func usableResumeData(_ data: Data) -> Data? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return plist is [String: Any] ? data : nil
    }

    /// A task resuming from `data`, or nil to start over. URLSession raises an
    /// Objective-C exception, which Swift cannot catch, on resume data it
    /// can't read.
    private static func resumeTask(
        in session: URLSession,
        from data: Data,
        for url: URL,
        store: DownloadResumeStore
    ) -> URLSessionDownloadTask? {
        var task: URLSessionDownloadTask?
        let exception = VocaObjCExceptionCatcher.catchException {
            task = session.downloadTask(withResumeData: data)
        }
        if let exception {
            VocaLogger.warning(
                .modelManager,
                "Discarding unreadable resume data for \(url.lastPathComponent): \(exception.localizedDescription)"
            )
            store.remove(for: url)
            return nil
        }
        return task
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

    /// Cancel the transfer and fail the awaiting caller. What was already
    /// transferred is kept, so downloading the same model again resumes.
    private func cancel() {
        stateLock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        let continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()

        let source = self.source
        let resumeStore = self.resumeStore
        task?.cancel(byProducingResumeData: { data in
            if let data { resumeStore.save(data, for: source) }
        })
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
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        VocaLogger.info(
            .modelManager,
            "Resumed \(source.lastPathComponent) at \(ByteCountFormatter.string(fromByteCount: fileOffset, countStyle: .file))"
        )
        guard expectedTotalBytes > 0 else { return }
        let progress = Double(fileOffset) / Double(expectedTotalBytes)
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
