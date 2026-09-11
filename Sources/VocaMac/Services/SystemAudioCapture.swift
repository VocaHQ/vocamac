// SystemAudioCapture.swift
// VocaMac
//
// Captures the Mac's output with a Core Audio process tap (macOS 14.2+).

import AVFoundation
import CoreAudio
import Foundation
import os

final class SystemAudioAccumulator: @unchecked Sendable {
    static let maximumDurationSeconds = 20 * 60
    private let maximumDurationSeconds: Double
    private struct State {
        var samples: [Float] = []
        var sampleRate = 48_000.0
        var didReachLimit = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(maximumDurationSeconds: Double = Double(SystemAudioAccumulator.maximumDurationSeconds)) {
        self.maximumDurationSeconds = maximumDurationSeconds
    }

    func reset(sampleRate: Double) {
        state.withLock { $0 = State(samples: [], sampleRate: sampleRate) }
    }

    func append(_ input: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let channels = max(1, Int(format.mChannelsPerFrame))
        var mono: [Float] = []
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            let available = min(channels, buffers.count)
            guard available > 0 else { return false }
            let frames = buffers.prefix(available).map { Int($0.mDataByteSize) / MemoryLayout<Float>.size }.min() ?? 0
            mono = Array(repeating: 0, count: frames)
            for channel in 0..<available {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<frames { mono[frame] += data[frame] / Float(available) }
            }
        } else {
            guard let buffer = buffers.first,
                  let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return false }
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            mono.reserveCapacity(frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += data[frame * channels + channel] }
                mono.append(sum / Float(channels))
            }
        }
        return appendMonoSamples(mono)
    }

    /// Appends already-mixed samples and returns true exactly once when the
    /// duration limit is first reached.
    func appendMonoSamples(_ captured: [Float]) -> Bool {
        guard !captured.isEmpty else { return false }
        return state.withLock { state in
            let wasAtLimit = state.didReachLimit
            let limit = Int(state.sampleRate * maximumDurationSeconds)
            let remaining = max(0, limit - state.samples.count)
            state.samples.append(contentsOf: captured.prefix(remaining))
            if captured.count >= remaining { state.didReachLimit = true }
            return state.didReachLimit && !wasAtLimit
        }
    }

    func reachedLimit() -> Bool { state.withLock { $0.didReachLimit } }

    func normalizedSamples() -> [Float] {
        let snapshot = state.withLock { $0 }
        guard !snapshot.samples.isEmpty else { return [] }
        guard abs(snapshot.sampleRate - 16_000) > 0.5 else { return snapshot.samples }
        let ratio = snapshot.sampleRate / 16_000
        let count = Int(Double(snapshot.samples.count) / ratio)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let source = min(snapshot.samples.count - 1, Int(Double(index) * ratio))
            return snapshot.samples[source]
        }
    }
}

@MainActor
final class SystemAudioCapture: ObservableObject {
    enum CaptureError: LocalizedError {
        case unsupported, coreAudio(String, OSStatus), unsupportedFormat
        var errorDescription: String? {
            switch self {
            case .unsupported: return "System-audio capture needs macOS 14.2 or later."
            case .coreAudio(let action, let status): return "Could not \(action) (Core Audio \(status))."
            case .unsupportedFormat: return "The system-audio tap returned an unsupported sample format."
            }
        }
    }

    @Published private(set) var isCapturing = false
    @Published private(set) var didReachLimit = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.vocamac.system-audio", qos: .userInitiated)
    private let accumulator = SystemAudioAccumulator()

    func start() throws {
        guard #available(macOS 14.2, *) else { throw CaptureError.unsupported }
        guard !isCapturing else { return }
        didReachLimit = false
        let tap = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tap.name = "VocaMac System Audio"
        tap.isPrivate = true
        tap.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(tap, &newTap)
        guard status == noErr else { throw CaptureError.coreAudio("create the process tap", status) }
        tapID = newTap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VocaMac System Audio",
            kAudioAggregateDeviceUIDKey: "com.vocamac.system-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tap.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw CaptureError.coreAudio("create the capture device", status)
        }
        aggregateID = aggregate

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        status = AudioObjectGetPropertyData(aggregate, &address, 0, nil, &size, &format)
        guard status == noErr else { cleanup(); throw CaptureError.coreAudio("read the tap format", status) }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            cleanup(); throw CaptureError.unsupportedFormat
        }
        accumulator.reset(sampleRate: format.mSampleRate)

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self, accumulator] _, input, _, _, _ in
            if accumulator.append(input, format: format) {
                Task { @MainActor [weak self] in self?.stopAtDurationLimit() }
            }
        }
        guard status == noErr, let proc else { cleanup(); throw CaptureError.coreAudio("attach the capture callback", status) }
        ioProcID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else { cleanup(); throw CaptureError.coreAudio("start system-audio capture", status) }
        isCapturing = true
        VocaLogger.info(.audioEngine, "System-audio process tap started")
    }

    func stop() -> [Float] {
        cleanup()
        didReachLimit = accumulator.reachedLimit()
        let samples = accumulator.normalizedSamples()
        VocaLogger.info(.audioEngine, "System-audio process tap stopped with \(samples.count) samples")
        return samples
    }

    private func stopAtDurationLimit() {
        guard isCapturing else { return }
        cleanup()
        didReachLimit = true
        VocaLogger.info(.audioEngine, "System-audio process tap stopped at the 20-minute limit")
    }

    private func cleanup() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown), let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isCapturing = false
    }

    deinit {
        // Runtime-owned Core Audio objects are also private/nonpersistent and
        // disappear if the process exits unexpectedly.
    }
}
