// UncheckedSendableBox.swift
// VocaMac

import Foundation

/// Carries a value into a `@Sendable` closure that the compiler can't prove
/// is used safely. Each use says why it is: usually that the closure runs
/// synchronously (an AVAudioConverter input block), or that the value is
/// only handed on and never shared.
///
/// A box rather than `nonisolated(unsafe)`: SDKs disagree on which types are
/// Sendable (Xcode 27 marks some AVFAudio and WhisperKit types that Xcode 26
/// doesn't), and `nonisolated(unsafe)` on an already-Sendable value is itself
/// a warning.
final class UncheckedSendableBox<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
