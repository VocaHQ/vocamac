// SoundManager.swift
// VocaMac
//
// Plays bundled start/stop dictation cues for the selected tone.

import Foundation
import AppKit

final class SoundManager: NSObject, NSSoundDelegate, @unchecked Sendable {

    // MARK: - Properties

    /// Volume for sound effects (0.0 to 1.0)
    var volume: Float = 0.5

    /// Test hook. When set, playback uses this tone instead of the saved preference.
    var toneOverride: DictationTone?

    /// Queue used because NSSound can block while Core Audio wakes or fails.
    private let soundQueue = DispatchQueue(label: "com.vocamac.sound-playback", qos: .utility)

    /// Lock for thread-safe access to continuation, cache, and retained sounds.
    private let continuationLock = NSLock()

    /// Continuation for async sound playback completion
    private var soundCompletionContinuation: CheckedContinuation<Void, Never>?

    /// Keeps in-flight `NSSound` instances alive until they finish.
    private var activeSounds: [NSSound] = []

    /// Cached WAV bytes keyed by `tone-cue`.
    private var wavCache: [String: Data] = [:]

    private var currentTone: DictationTone {
        if let toneOverride { return toneOverride }
        let stored = UserDefaults.standard.string(forKey: PreferenceKey.dictationTone)
        return DictationTone.resolved(stored: stored)
    }

    // MARK: - Public API

    /// Play the recording-started sound (synchronous, fire-and-forget)
    func playStartSound() {
        playCue(.start)
    }

    /// Play the recording-started sound and wait for completion
    /// Ensures the sound finishes before returning, preventing mic capture of the sound.
    func playStartSoundAsync() async {
        await playCueAsync(.start)
    }

    /// Play the recording-stopped sound (synchronous, fire-and-forget)
    func playStopSound() {
        playCue(.stop)
    }

    /// Play the recording-stopped sound and wait for completion
    func playStopSoundAsync() async {
        await playCueAsync(.stop)
    }

    // MARK: - Private

    private func wavData(for kind: DictationCueKind) -> Data? {
        let tone = currentTone
        guard tone.playsCues else { return nil }
        let key = "\(tone.rawValue)-\(kind.rawValue)"
        continuationLock.lock()
        if let cached = wavCache[key] {
            continuationLock.unlock()
            return cached
        }
        continuationLock.unlock()

        guard let data = tone.audioData(for: kind) else {
            VocaLogger.warning(.soundManager, "Missing bundled dictation tone: \(tone.rawValue) \(kind.rawValue)")
            return nil
        }
        continuationLock.lock()
        wavCache[key] = data
        continuationLock.unlock()
        return data
    }

    private func playCue(_ kind: DictationCueKind) {
        guard let data = wavData(for: kind) else { return }
        let volume = self.volume

        soundQueue.async { [weak self] in
            guard let self else { return }
            guard let sound = NSSound(data: data) else {
                VocaLogger.warning(.soundManager, "Could not load dictation tone: \(self.currentTone.rawValue) \(kind.rawValue)")
                return
            }

            sound.volume = volume
            sound.delegate = self
            self.retain(sound)
            if !sound.play() {
                VocaLogger.warning(.soundManager, "Could not play dictation tone: \(self.currentTone.rawValue) \(kind.rawValue)")
                self.release(sound)
            }
        }
    }

    private func playCueAsync(_ kind: DictationCueKind) async {
        guard let data = wavData(for: kind) else { return }
        guard let sound = NSSound(data: data) else {
            VocaLogger.warning(.soundManager, "Could not load dictation tone: \(currentTone.rawValue) \(kind.rawValue)")
            return
        }

        sound.volume = volume
        sound.delegate = self
        retain(sound)

        return await withCheckedContinuation { continuation in
            continuationLock.lock()
            soundCompletionContinuation = continuation
            continuationLock.unlock()

            if !sound.play() {
                VocaLogger.warning(.soundManager, "Could not play dictation tone: \(currentTone.rawValue) \(kind.rawValue)")
                release(sound)
                continuationLock.lock()
                soundCompletionContinuation?.resume()
                soundCompletionContinuation = nil
                continuationLock.unlock()
                return
            }

            // Timeout after 1 second to prevent stuck sounds from blocking
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.continuationLock.lock()
                if self.soundCompletionContinuation != nil {
                    VocaLogger.warning(.soundManager, "Sound playback timeout for: \(kind.rawValue)")
                    self.soundCompletionContinuation?.resume()
                    self.soundCompletionContinuation = nil
                }
                self.continuationLock.unlock()
            }
        }
    }

    private func retain(_ sound: NSSound) {
        continuationLock.lock()
        activeSounds.append(sound)
        continuationLock.unlock()
    }

    private func release(_ sound: NSSound) {
        continuationLock.lock()
        activeSounds.removeAll { $0 === sound }
        continuationLock.unlock()
    }

    // MARK: - NSSoundDelegate

    nonisolated func sound(_ sound: NSSound, didFinishPlaying FinishedPlaying: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.release(sound)
            self.continuationLock.lock()
            if let continuation = self.soundCompletionContinuation {
                continuation.resume()
                self.soundCompletionContinuation = nil
            }
            self.continuationLock.unlock()
        }
    }
}

// MARK: - SoundPlaying Conformance

extension SoundManager: SoundPlaying {}
