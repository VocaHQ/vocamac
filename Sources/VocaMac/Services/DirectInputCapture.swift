// DirectInputCapture.swift
// VocaMac
//
// Records one chosen input device through its own input-only HAL unit,
// without AVAudioEngine.
//
// AVAudioEngine binds its I/O unit to the system's default devices the moment
// its input node is created. When AirPods (or another headset) are the system
// input and output, that alone builds a Core Audio aggregate of the headset's
// input and output and switches it into its call profile: the audio route
// churns for a second or two, playback on the headset drops to call quality,
// and a recording started meanwhile fails (-10868, or no input stream). A
// standalone HAL unit pointed at the chosen device before it is initialized
// never touches the system devices.

import AudioToolbox
import AVFoundation
import CoreAudio

/// Captures from one input device and hands buffers of about 85 ms to
/// `onBuffer`, the size AVAudioEngine's tap delivers (`InputChunker`).
///
/// `onBuffer` runs on the device's I/O thread with a buffer that is reused for
/// the next chunk: it must finish with the buffer before returning.
final class DirectInputCapture: @unchecked Sendable {
    // @unchecked Sendable: `unit`, `buffer` and `format` are set in `init` and
    // only read afterwards; start/stop are called from AudioEngine's serial
    // `lifecycleQueue`. The render callback is the only writer of `buffer`
    // and `chunker` while running; `start` resets `chunker` before the unit
    // runs.
    let deviceID: AudioDeviceID
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    private let chunker: InputChunker
    private let onBuffer: (AVAudioPCMBuffer, AVAudioFormat) -> Void
    private(set) var isRunning = false

    /// Sets up an input-only unit on `deviceID` in the device's own sample
    /// rate and channel count (Float32, non-interleaved). Nil when Core Audio
    /// refuses any step; the reason is logged.
    init?(deviceID: AudioDeviceID, onBuffer: @escaping (AVAudioPCMBuffer, AVAudioFormat) -> Void) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        var created: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &created) == noErr,
              let unit = created else {
            VocaLogger.warning(.audioEngine, "Direct capture: couldn't create an input unit")
            return nil
        }
        func fail(_ step: String, _ status: OSStatus) -> Bool {
            guard status != noErr else { return false }
            VocaLogger.warning(.audioEngine, "Direct capture: \(step) failed (status \(status))")
            AudioComponentInstanceDispose(unit)
            return true
        }

        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        if fail("enable input", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize
        )) { return nil }
        if fail("disable output", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize
        )) { return nil }
        var device = deviceID
        if fail("select device", AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )) { return nil }

        var hardware = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if fail("read device format", AudioUnitGetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize
        )) { return nil }
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate,
                channels: AVAudioChannelCount(hardware.mChannelsPerFrame), interleaved: false
              ) else {
            VocaLogger.warning(.audioEngine, "Direct capture: the device reports no usable format")
            AudioComponentInstanceDispose(unit)
            return nil
        }
        // The client side gets the device's own rate: a HAL input unit can't
        // convert sample rates.
        var client = format.streamDescription.pointee
        if fail("set client format", AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, formatSize
        )) { return nil }

        var maxFrames: UInt32 = 0
        var maxFramesSize = UInt32(MemoryLayout<UInt32>.size)
        AudioUnitGetProperty(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &maxFramesSize
        )
        let renderCapacity = max(maxFrames, 4_096)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: renderCapacity),
              let chunker = InputChunker(format: format, maxPieceFrames: renderCapacity) else {
            AudioComponentInstanceDispose(unit)
            return nil
        }

        self.deviceID = deviceID
        self.format = format
        self.unit = unit
        self.buffer = buffer
        self.chunker = chunker
        self.onBuffer = onBuffer
        // From here `self` owns the unit, and a failed init runs `deinit`,
        // which disposes it: don't dispose it here as well.

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frameCount, _ in
                Unmanaged<DirectInputCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let callbackStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard callbackStatus == noErr else {
            VocaLogger.warning(.audioEngine, "Direct capture: set input callback failed (status \(callbackStatus))")
            return nil
        }
        let initializeStatus = AudioUnitInitialize(unit)
        guard initializeStatus == noErr else {
            VocaLogger.warning(.audioEngine, "Direct capture: initialize failed (status \(initializeStatus))")
            return nil
        }
    }

    deinit {
        if isRunning { AudioOutputUnitStop(unit) }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Starts the device's input stream. Must be called on AudioEngine's `lifecycleQueue`.
    func start() -> OSStatus {
        guard !isRunning else { return noErr }
        chunker.reset()
        let status = AudioOutputUnitStart(unit)
        isRunning = status == noErr
        return status
    }

    /// Stops the input stream; no callback runs after this returns.
    /// Must be called on AudioEngine's `lifecycleQueue`.
    func stop() {
        guard isRunning else { return }
        AudioOutputUnitStop(unit)
        isRunning = false
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timeStamp: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frameCount
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, buffer.mutableAudioBufferList)
        if status == noErr {
            chunker.append(buffer) { onBuffer($0, format) }
        }
        return status
    }
}

// MARK: - Chunking

/// Gathers the small buffers a HAL unit delivers (often 512 frames, ~11 ms)
/// into chunks of about 85 ms, what AVAudioEngine's 4,096-frame tap delivers
/// at 48 kHz. `SilenceDetector` adapts its noise floor once per buffer, tuned
/// for that size: fed eight times as many buffers it adapts eight times as
/// fast, and hands-free dictation stops on quiet speech.
final class InputChunker {
    /// About 85 ms: 4,096 frames at 48 kHz.
    static let chunkDuration: Double = 4_096.0 / 48_000.0

    let chunkFrames: AVAudioFrameCount
    private let chunk: AVAudioPCMBuffer

    /// - Parameter maxPieceFrames: The largest buffer `append` will be given.
    init?(format: AVAudioFormat, maxPieceFrames: AVAudioFrameCount) {
        let frames = max(1, AVAudioFrameCount((format.sampleRate * Self.chunkDuration).rounded()))
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames + maxPieceFrames) else { return nil }
        chunkFrames = frames
        self.chunk = chunk
    }

    /// Drops any partial chunk, for the next recording.
    func reset() {
        chunk.frameLength = 0
    }

    /// Adds `piece` and calls `emit` with the chunk once it holds at least
    /// `chunkFrames`. The chunk is emitted as soon as it reaches that, so it
    /// always has room for the next piece of up to `maxPieceFrames`.
    /// Float32, non-interleaved.
    func append(_ piece: AVAudioPCMBuffer, emit: (AVAudioPCMBuffer) -> Void) {
        guard let source = piece.floatChannelData, let destination = chunk.floatChannelData else { return }
        let count = Int(piece.frameLength)
        let offset = Int(chunk.frameLength)
        guard offset + count <= Int(chunk.frameCapacity) else { return }
        for channel in 0..<Int(chunk.format.channelCount) {
            (destination[channel] + offset).update(from: source[channel], count: count)
        }
        chunk.frameLength = AVAudioFrameCount(offset + count)
        if chunk.frameLength >= chunkFrames {
            emit(chunk)
            chunk.frameLength = 0
        }
    }
}
