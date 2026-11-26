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

extension AudioEngine {
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
        let hardwareRate = inputNode.inputFormat(forBus: 0).sampleRate
        let clientRate = inputNode.outputFormat(forBus: 0).sampleRate
        guard needsClientRateAlignment(hardwareRate: hardwareRate, clientRate: clientRate),
              let audioUnit = inputNode.audioUnit else { return }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // Element 1 is the input side of the I/O unit; its output scope is
        // the format the engine (and our tap) receives.
        guard AudioUnitGetProperty(
            audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, &size
        ) == noErr else {
            VocaLogger.warning(.audioEngine, "Could not read the input tap format to match the device rate")
            return
        }
        format.mSampleRate = hardwareRate
        let status = AudioUnitSetProperty(
            audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &format, size
        )
        if status == noErr {
            VocaLogger.info(.audioEngine, "Input tap format moved from \(Int(clientRate))Hz to the device's \(Int(hardwareRate))Hz")
        } else {
            VocaLogger.warning(.audioEngine, "Could not set the input tap format to \(Int(hardwareRate))Hz (status \(status))")
        }
    }
}
