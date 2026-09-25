// AudioFileLoader.swift
// VocaMac
//
// Validates and normalizes an audio file for all transcription engines.

import AVFoundation
import Foundation

/// Normalized PCM input expected by VocaMac's transcription services.
struct LoadedAudioFile: Equatable {
    let samples: [Float]
    let durationSeconds: Double
}

/// Audio-loading seam used by headless transcription tests.
protocol AudioFileLoading {
    func loadAudio(at url: URL) throws -> LoadedAudioFile
}

/// Loads regular audio files as mono, 16 kHz, Float32 PCM.
final class AudioFileLoader: AudioFileLoading {
    static let sampleRate = 16_000.0
    static let maximumFileSizeBytes: Int64 = 500 * 1_024 * 1_024
    static let maximumDurationSeconds = 30 * 60.0

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadAudio(at url: URL) throws -> LoadedAudioFile {
        let standardizedURL = url.standardizedFileURL
        guard fileManager.fileExists(atPath: standardizedURL.path) else {
            throw CLIError(.invalidAudio, "Audio file does not exist: \(standardizedURL.path)")
        }

        let values: URLResourceValues
        do {
            values = try standardizedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw CLIError(.invalidAudio, "Could not inspect the audio file.")
        }
        guard values.isRegularFile == true else {
            throw CLIError(.invalidAudio, "Audio path must refer to a regular file.")
        }
        if let fileSize = values.fileSize, Int64(fileSize) > Self.maximumFileSizeBytes {
            throw CLIError(.invalidAudio, "Audio file exceeds the 500 MB limit.")
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(
                forReading: standardizedURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw CLIError(.invalidAudio, "Audio file is unreadable or has an unsupported format.")
        }

        let sourceFormat = audioFile.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0, audioFile.length > 0 else {
            throw CLIError(.invalidAudio, "Audio file is empty.")
        }

        let sourceDuration = Double(audioFile.length) / sourceFormat.sampleRate
        guard sourceDuration.isFinite, sourceDuration <= Self.maximumDurationSeconds else {
            throw CLIError(.invalidAudio, "Audio duration exceeds the 30 minute limit.")
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw CLIError(.invalidAudio, "Audio could not be converted to 16 kHz mono PCM.")
        }

        let samples = try convert(
            audioFile: audioFile,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            converter: converter
        )
        guard !samples.isEmpty else {
            throw CLIError(.invalidAudio, "Audio file contains no samples.")
        }
        guard samples.allSatisfy(\.isFinite) else {
            throw CLIError(.invalidAudio, "Audio file contains invalid samples.")
        }
        guard samples.contains(where: { abs($0) > 0.000_000_1 }) else {
            throw CLIError(.invalidAudio, "Audio file is silent.")
        }

        return LoadedAudioFile(
            samples: samples,
            durationSeconds: Double(samples.count) / Self.sampleRate
        )
    }

    /// Stream through AVAudioConverter so large-but-valid source files are not
    /// first decoded into a second full-size in-memory source buffer.
    private func convert(
        audioFile: AVAudioFile,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter
    ) throws -> [Float] {
        let outputCapacity: AVAudioFrameCount = 16_384
        var samples: [Float] = []
        samples.reserveCapacity(Int(min(
            Double(Int.max),
            (Double(audioFile.length) / sourceFormat.sampleRate * Self.sampleRate).rounded(.up)
        )))

        var readFailure: Error?
        var zeroLengthPasses = 0

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputCapacity
            ) else {
                throw CLIError(.invalidAudio, "Could not allocate an audio conversion buffer.")
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { requestedFrames, inputStatus in
                guard audioFile.framePosition < audioFile.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: requestedFrames
                ) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                do {
                    try audioFile.read(into: inputBuffer, frameCount: requestedFrames)
                } catch {
                    readFailure = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }

                guard inputBuffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }

            if let readFailure {
                throw CLIError(.invalidAudio, "Audio file could not be read: \(readFailure.localizedDescription)")
            }
            if let conversionError {
                throw CLIError(.invalidAudio, "Audio conversion failed: \(conversionError.localizedDescription)")
            }

            if outputBuffer.frameLength > 0,
               let channel = outputBuffer.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(outputBuffer.frameLength)
                ))
                zeroLengthPasses = 0
            } else {
                zeroLengthPasses += 1
            }

            if status == .endOfStream { break }
            if status == .error {
                throw CLIError(.invalidAudio, "Audio conversion failed.")
            }
            guard zeroLengthPasses < 3 else {
                throw CLIError(.invalidAudio, "Audio conversion produced no samples.")
            }
        }

        return samples
    }
}
