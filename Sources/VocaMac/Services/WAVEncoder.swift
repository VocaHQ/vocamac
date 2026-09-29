// WAVEncoder.swift
// VocaMac
//
// The canonical WAV container the app's 16 kHz mono Float samples are put in
// wherever audio leaves memory as a file: failure dumps, history keeps, and
// uploads to a remote speech endpoint.

import Foundation

enum WAVEncoder {

    /// 16-bit mono PCM in a canonical 44-byte WAV container.
    static func pcm16Mono(from samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataBytes)

        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                                  // PCM header size
        append(UInt16(1))                                   // PCM
        append(UInt16(1))                                   // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * bytesPerSample))         // byte rate
        append(UInt16(bytesPerSample))                      // block align
        append(UInt16(16))                                  // bits per sample

        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        let headerBytes = data.count
        data.count = headerBytes + dataBytes
        data.withUnsafeMutableBytes { raw in
            let body = UnsafeMutableRawBufferPointer(rebasing: raw[headerBytes...])
            for (index, sample) in samples.enumerated() {
                let value = Int16(max(-1, min(1, sample)) * 32_767).littleEndian
                body.storeBytes(of: value, toByteOffset: index * bytesPerSample, as: Int16.self)
            }
        }
        return data
    }
}
