// FailedAudioDump.swift
// VocaMac
//
// Saves the audio behind a transcription that came back empty, so a failure
// that only happens with a real microphone can be replayed through
// `--transcribe-file` and debugged offline.

import Foundation

/// Writes the samples behind an empty transcription to a WAV file.
///
/// Off unless the user turns it on, because it puts recorded speech on disk:
///
///     defaults write com.vocamac.app vocamac.debug.saveFailedAudio -bool true
enum FailedAudioDump {

    static let preferenceKey = "vocamac.debug.saveFailedAudio"

    /// Most recordings kept before the oldest are removed.
    static let maximumFiles = 20

    static var directory: URL {
        VocaLogger.logDirectory().appendingPathComponent("failed-audio", isDirectory: true)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: preferenceKey)
    }

    /// Build a dump filename that cannot collide within the same second.
    static func makeFilename(
        model: String,
        date: Date = Date(),
        uniqueID: String = UUID().uuidString
    ) -> String {
        let stamp = ISO8601DateFormatter.dumpFormatter.string(from: date)
        let token = String(uniqueID.replacingOccurrences(of: "-", with: "").prefix(8))
        let safeModel = model
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return "\(stamp)-\(token)-\(safeModel).wav"
    }

    /// Save `samples` if the user asked for dumps. Returns the file written.
    @discardableResult
    static func save(_ samples: [Float], model: String, sampleRate: Int = 16_000) -> URL? {
        guard isEnabled, !samples.isEmpty else { return nil }

        let url = directory.appendingPathComponent(makeFilename(model: model))

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try wavData(from: samples, sampleRate: sampleRate).write(to: url)
            pruneOldest()
            VocaLogger.info(.sherpaService, "Saved the failed recording to \(url.path)")
            return url
        } catch {
            VocaLogger.error(.sherpaService, "Could not save the failed recording: \(error)")
            return nil
        }
    }

    /// 16-bit mono PCM in a canonical 44-byte WAV container; see `WAVEncoder`.
    static func wavData(from samples: [Float], sampleRate: Int) -> Data {
        WAVEncoder.pcm16Mono(from: samples, sampleRate: sampleRate)
    }

    /// Keep the newest `maximumFiles` dumps so this cannot fill the disk.
    private static func pruneOldest() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let sorted = files
            .filter { $0.pathExtension == "wav" }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                return (leftDate ?? .distantPast) > (rightDate ?? .distantPast)
            }

        for file in sorted.dropFirst(maximumFiles) {
            try? fileManager.removeItem(at: file)
        }
    }
}

private extension ISO8601DateFormatter {
    /// Colons are legal in HFS+ paths but confuse shell completion and tools.
    static let dumpFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = .current
        return formatter
    }()
}
