// LoadSerializer.swift
// VocaMac
//
// Runs async operations one at a time, in the order they were requested.

import Foundation

/// Serializes async work so a second request waits for the first to finish.
///
/// Model loading and transcription both touch the active engine. Without a
/// shared queue, a hotkey mid-switch can decode against an engine that load
/// just unloaded, and two overlapping loads can leave more than one model
/// resident. Both paths share this actor so only one runs at a time.
actor LoadSerializer {

    /// The most recently queued operation, used to chain the next one behind it.
    private var tail: Task<Void, Never>?

    /// Run `operation` after every operation queued before it has settled.
    ///
    /// A failure in one operation does not prevent later ones from running;
    /// the error is delivered to whoever queued that operation.
    func run<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail

        let task = Task<Result<T, Error>, Never> {
            await previous?.value
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }

        // Chain the next caller behind this one, discarding the result type so
        // a thrown error cannot cancel the queue.
        tail = Task { _ = await task.value }

        switch await task.value {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        }
    }
}
