// HistoryAudioPlayer.swift
// VocaMac
//
// Plays back the audio saved with a history entry, one recording at a time.

import AVFoundation
import Foundation

/// Plays one history recording at a time.
@MainActor
final class HistoryAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = HistoryAudioPlayer()

    @Published private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    /// Plays `url`, or stops it when it is the recording already playing.
    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            // Only show “Stop audio” once playback has really started.
            guard player.play() else {
                VocaLogger.warning(.history, "Could not start playing recording")
                return
            }
            self.player = player
            playingURL = url
        } catch {
            VocaLogger.warning(.history, "Could not play recording: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        Task { @MainActor in self.stop(ifPlaying: finished) }
    }

    /// A damaged recording stops mid-way without finishing; reset so the
    /// row doesn't stay on “Stop audio”.
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        let message = error?.localizedDescription ?? "unknown error"
        Task { @MainActor in
            VocaLogger.warning(.history, "Recording stopped on a decode error: \(message)")
            self.stop(ifPlaying: failed)
        }
    }

    /// Stops only if `player` is still the one playing, so a late callback
    /// from an earlier recording can't stop the next one.
    private func stop(ifPlaying player: ObjectIdentifier) {
        guard let current = self.player, ObjectIdentifier(current) == player else { return }
        stop()
    }
}
