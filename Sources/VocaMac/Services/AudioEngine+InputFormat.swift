// AudioEngine+InputFormat.swift
// VocaMac
//
// Keeps the input node's tap format at the sample rate of the device it now
// records from.
//
// When the input unit is pointed at another device (a chosen microphone, or a
// route change), the hardware side of AVAudioInputNode moves to the new
// device's rate but its output (tap) format keeps the old device's rate, even
// across `engine.reset()`. The input unit can't convert sample rates, so
// `engine.start()` then fails with kAudioUnitErr_FormatNotSupported (-10868).
// Typical case: a Bluetooth headset (16 or 24 kHz in a call profile) is the
// system input and a USB or built-in mic (44.1 or 48 kHz) is chosen in VocaMac.

import AudioToolbox
import AVFoundation

/// Reads and writes an audio unit's stream format, so the alignment below
/// can be tested without hardware.
struct AudioUnitStreamFormatAccess {
    var read: (_ scope: AudioUnitScope, _ element: AudioUnitElement) -> AudioStreamBasicDescription?
    var write: (_ format: AudioStreamBasicDescription, _ scope: AudioUnitScope, _ element: AudioUnitElement) -> OSStatus

    /// The real property calls on `audioUnit`.
    static func live(_ audioUnit: AudioUnit) -> AudioUnitStreamFormatAccess {
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioUnitStreamFormatAccess(
            read: { scope, element in
                var format = AudioStreamBasicDescription()
                var readSize = size
                let status = AudioUnitGetProperty(
                    audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &format, &readSize
                )
                return status == noErr ? format : nil
            },
            write: { format, scope, element in
                var format = format
                return AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, scope, element, &format, size)
            }
        )
    }
}

extension AudioEngine {
    /// Element 1 is the input side of an I/O unit; its output scope is the
    /// format the engine, and our tap, receives.
    static let inputClientScope = kAudioUnitScope_Output
    static let inputElement: AudioUnitElement = 1

    /// Whether the tap-side rate differs from the device's and must be moved.
    static func needsClientRateAlignment(hardwareRate: Double, clientRate: Double) -> Bool {
        guard hardwareRate.isFinite, hardwareRate > 0 else { return false }
        return hardwareRate != clientRate
    }

    /// Sets the input node's output (tap-side) sample rate to the hardware
    /// rate, keeping the rest of the client format. Call after the input route
    /// is configured and before the tap's format is read.
    /// Must be called on `lifecycleQueue` with no tap installed.
    static func alignInputClientRate(of inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else { return }
        alignInputClientRate(
            hardwareRate: inputNode.inputFormat(forBus: 0).sampleRate,
            clientRate: inputNode.outputFormat(forBus: 0).sampleRate,
            access: .live(audioUnit)
        )
    }

    /// The format write behind `alignInputClientRate(of:)`.
    /// - Returns: Whether a new format was written.
    @discardableResult
    static func alignInputClientRate(
        hardwareRate: Double,
        clientRate: Double,
        access: AudioUnitStreamFormatAccess
    ) -> Bool {
        guard needsClientRateAlignment(hardwareRate: hardwareRate, clientRate: clientRate) else { return false }
        guard var format = access.read(inputClientScope, inputElement) else {
            VocaLogger.warning(.audioEngine, "Could not read the input tap format to match the device rate")
            return false
        }
        format.mSampleRate = hardwareRate
        let status = access.write(format, inputClientScope, inputElement)
        guard status == noErr else {
            VocaLogger.warning(.audioEngine, "Could not set the input tap format to \(Int(hardwareRate))Hz (status \(status))")
            return false
        }
        VocaLogger.info(.audioEngine, "Input tap format moved from \(Int(clientRate))Hz to the device's \(Int(hardwareRate))Hz")
        return true
    }
}
