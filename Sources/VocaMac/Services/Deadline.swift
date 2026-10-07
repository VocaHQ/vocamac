// Deadline.swift
// VocaMac
//
// Bounds how long an engine call may take, even when the call never returns.

import Foundation
import os

/// Runs an operation that may never return and stops waiting for it.
///
/// A CoreML compile under memory pressure, or a decode stuck in the Neural
/// Engine, does not check for cancellation. Awaited directly, such a call
/// holds the engine queue (`LoadSerializer`) for the life of the process and
/// every later dictation waits behind it. `Deadline.run` runs the operation
/// in its own task and returns as soon as either the operation finishes or the
/// deadline passes. On a deadline the operation is cancelled and left to
/// finish (or not) on its own; the caller must treat whatever it was using as
/// lost — for an engine, drop the loaded model so the next use loads afresh.
///
/// Unlike a task group, which always waits for its children, this never
/// waits for an operation that ignores cancellation.
enum Deadline {

    /// The operation did not finish in time.
    struct Exceeded: LocalizedError, Equatable {
        let operation: String
        let seconds: TimeInterval

        var errorDescription: String? {
            "\(operation) did not finish within \(Int(seconds.rounded())) seconds"
        }
    }

    /// The caller was cancelled and the operation did not stop within the
    /// grace period, so it was left running.
    struct Abandoned: LocalizedError, Equatable {
        let operation: String

        var errorDescription: String? {
            "\(operation) stopped responding"
        }
    }

    /// Time allowed for decoding `audioSeconds` of audio, generous enough
    /// that a slow Mac with a large model and every retry never reaches it.
    static func decodeSeconds(audioSeconds: Double) -> TimeInterval {
        max(60, 30 + 3 * audioSeconds)
    }

    /// Run `operation`, giving up after `seconds`.
    ///
    /// - Parameters:
    ///   - seconds: Time allowed, from now. `.infinity` never expires.
    ///   - abandonAfterCancel: When the caller is cancelled, wait this long for
    ///     the operation to stop, then throw `Abandoned` without it.
    ///     Nil waits for the operation however long it takes, which keeps a
    ///     cooperative operation's cleanup ahead of whatever runs next.
    ///   - operation: A name for logs and the error message.
    static func run<T: Sendable>(
        seconds: TimeInterval,
        abandonAfterCancel: TimeInterval? = nil,
        operation name: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = Gate<T>()
        let work = Task { try await operation() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                Task {
                    let result = await work.result
                    gate.resume(with: result)
                }
                if seconds.isFinite {
                    let timer = Task {
                        try await Task.sleep(nanoseconds: nanoseconds(seconds))
                        if gate.resume(with: .failure(Exceeded(operation: name, seconds: seconds))) {
                            VocaLogger.error(.general, "\(name) did not finish within \(Int(seconds.rounded())) s; giving up on it")
                            work.cancel()
                        }
                    }
                    gate.onSettle { timer.cancel() }
                }
            }
        } onCancel: {
            work.cancel()
            guard let grace = abandonAfterCancel else { return }
            Task {
                try? await Task.sleep(nanoseconds: nanoseconds(grace))
                if gate.resume(with: .failure(Abandoned(operation: name))) {
                    VocaLogger.error(.general, "\(name) ignored cancellation for \(grace) s; continuing without it")
                }
            }
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000)
    }

    /// Resumes a continuation once, from whichever side settles first. A
    /// resume that arrives before the continuation is installed is kept and
    /// delivered on install.
    private final class Gate<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, Error>?
            var pending: Result<T, Error>?
            var settled = false
            var onSettle: [@Sendable () -> Void] = []
        }

        private let state = OSAllocatedUnfairLock(uncheckedState: State())

        func install(_ continuation: CheckedContinuation<T, Error>) {
            let pending: Result<T, Error>? = state.withLockUnchecked { state in
                guard let pending = state.pending else {
                    state.continuation = continuation
                    return nil
                }
                state.pending = nil
                return pending
            }
            if let pending { continuation.resume(with: pending) }
        }

        func onSettle(_ action: @escaping @Sendable () -> Void) {
            let runNow = state.withLockUnchecked { state -> Bool in
                guard !state.settled else { return true }
                state.onSettle.append(action)
                return false
            }
            if runNow { action() }
        }

        /// Returns true when this call settled the gate.
        @discardableResult
        func resume(with result: Result<T, Error>) -> Bool {
            let (continuation, actions, won) = state.withLockUnchecked { state -> (CheckedContinuation<T, Error>?, [@Sendable () -> Void], Bool) in
                guard !state.settled else { return (nil, [], false) }
                state.settled = true
                let actions = state.onSettle
                state.onSettle = []
                guard let continuation = state.continuation else {
                    state.pending = result
                    return (nil, actions, true)
                }
                state.continuation = nil
                return (continuation, actions, true)
            }
            continuation?.resume(with: result)
            actions.forEach { $0() }
            return won
        }
    }
}
