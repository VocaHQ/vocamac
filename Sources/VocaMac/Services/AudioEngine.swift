// AudioEngine.swift
// VocaMac
//
// Real-time microphone audio capture using AVAudioEngine.
// Captures audio in the format required by whisper.cpp (16kHz, mono, Float32 PCM).

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio
import VocaMacObjC

final class AudioEngine {

    // MARK: - Properties

    /// AVAudioEngine is created lazily when recording starts and torn down soon
    /// after recording stops. Keeping it alive indefinitely while idle holds an
    /// input route on the system mic, which on Bluetooth devices like AirPods
    /// forces the headset (HFP/SCO) profile and breaks remote media controls
    /// (e.g. tap-to-pause) for any other app playing audio.
    private var engine: AVAudioEngine?
    private var pendingEngineRelease: DispatchWorkItem?
    private var audioBuffer: [Float] = []
    private var _isCurrentlyRecording = false
    private var configuredInputDeviceID: AudioDeviceID?
    private let bufferQueue = DispatchQueue(label: "com.vocamac.audio-buffer", qos: .userInteractive)
    private let lifecycleQueue = DispatchQueue(label: "com.vocamac.audio-engine.lifecycle", qos: .userInitiated)
    private let recordingPreparationLock = NSLock()
    private var _isPreparingRecording = false

    static let inputRouteConfigurationTimeout: TimeInterval = 0.25
    /// Bluetooth headsets need longer for the A2DP → HFP/SCO profile switch.
    static let bluetoothInputRouteConfigurationTimeout: TimeInterval = 3.0
    static let inputRoutePollInterval: TimeInterval = 0.05
    /// HFP/SCO typically runs at 8/16/24 kHz; A2DP stays at 44.1/48 kHz.
    static let bluetoothHFPSampleRateThreshold: Double = 44100
    static let startupConfigurationChangeRecoveryWindow: TimeInterval = 1.0
    static let idleEngineReleaseDelay: TimeInterval = 3.0

    var isCurrentlyRecording: Bool {
        lifecycleQueue.sync { _isCurrentlyRecording }
    }

    var isEngineAllocatedForTesting: Bool {
        lifecycleQueue.sync { engine != nil }
    }

    private var isPreparingRecording: Bool {
        recordingPreparationLock.lock()
        defer { recordingPreparationLock.unlock() }
        return _isPreparingRecording
    }

    // Silence detection
    private var lastSoundTime: Date = Date()
    private var silenceThreshold: Float = 0.01
    private var silenceDuration: Double = 2.0
    private var maxDuration: TimeInterval = 60.0
    private var recordingStartTime: Date = Date()

    // Audio level throttling
    private var lastLevelReportTime: Date = Date()
    private let levelReportInterval: TimeInterval = 1.0 / 15.0  // ~15 Hz

    /// Target audio format for whisper.cpp
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000.0,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Callbacks

    /// Called with the current audio level (0.0 - 1.0) for UI visualization
    var onAudioLevel: ((Float) -> Void)?

    /// Called when silence is detected for the configured duration
    var onSilenceDetected: (() -> Void)?

    /// Called when max recording duration is reached
    var onMaxDurationReached: (() -> Void)?

    /// Called when the audio device configuration changes (e.g., mic unplugged/replugged).
    /// The engine is automatically stopped and reset when this happens.
    /// AppState should use this to recover from a stuck recording state.
    var onAudioDeviceChanged: (() -> Void)?

    // MARK: - Initialization

    init() {
        // Note: we intentionally do NOT create the AVAudioEngine here, nor
        // register for AVAudioEngineConfigurationChange. Both actions cause the
        // engine's input node to materialise and claim the system input route,
        // which on Bluetooth headsets forces the HFP profile. The observer is
        // attached as part of `acquireEngine()` instead, and torn down by
        // `releaseEngine()` once the stopped engine has been idle briefly.
    }

    deinit {
        pendingEngineRelease?.cancel()
        // Make sure any active engine and its observer are released. This is a
        // safety net — under normal flows `stopRecording`/`forceReset` will
        // already have torn things down.
        if let engine {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        }
    }

    // MARK: - Engine Lifecycle

    /// Lazily create the AVAudioEngine and start observing configuration changes.
    /// Must be called on `lifecycleQueue`.
    private func acquireEngine() -> AVAudioEngine {
        pendingEngineRelease?.cancel()
        pendingEngineRelease = nil

        if let engine { return engine }
        let newEngine = AVAudioEngine()
        engine = newEngine
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: newEngine
        )
        VocaLogger.debug(.audioEngine, "AVAudioEngine instance acquired")
        return newEngine
    }

    /// Tear down the AVAudioEngine, removing its observer and releasing the
    /// underlying input route so other apps (and Bluetooth audio profiles)
    /// aren't affected while we're idle.
    /// Must be called on `lifecycleQueue`.
    private func releaseEngine() {
        pendingEngineRelease?.cancel()
        pendingEngineRelease = nil

        configuredInputDeviceID = nil
        guard let engine else { return }
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
        self.engine = nil
        VocaLogger.debug(.audioEngine, "AVAudioEngine instance released")
    }

    /// Release the engine after a short idle window so rapid push-to-talk
    /// recordings can reuse a warm input route.
    /// Must be called on `lifecycleQueue`.
    private func scheduleEngineRelease() {
        pendingEngineRelease?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self._isCurrentlyRecording else { return }
            self.releaseEngine()
        }
        pendingEngineRelease = workItem

        lifecycleQueue.asyncAfter(deadline: .now() + Self.idleEngineReleaseDelay, execute: workItem)
        VocaLogger.debug(.audioEngine, "AVAudioEngine instance scheduled for idle release")
    }

    // MARK: - Audio Configuration Change

    /// Called when macOS detects an audio hardware configuration change.
    /// This happens when a microphone is unplugged/replugged, Bluetooth audio
    /// disconnects, or the default audio device changes (e.g., after sleep).
    ///
    /// When this fires during an active recording, the engine's internal state
    /// is invalidated — the installed tap references a stale format and no audio
    /// flows. We must stop, reset, and notify AppState so it can recover.
    @objc private func handleAudioConfigurationChange(_ notification: Notification) {
        // Capture preparation state on the posting queue. startRecording holds
        // lifecycleQueue during Bluetooth HFP settle, so reading later would race.
        let occurredDuringRecordingPreparation = isPreparingRecording

        lifecycleQueue.async { [weak self] in
            guard let self = self else { return }
            VocaLogger.info(.audioEngine, "Audio configuration changed (device plug/unplug or route change)")

            let wasRecording = self._isCurrentlyRecording
            let elapsedSinceRecordingStart = Date().timeIntervalSince(self.recordingStartTime)
            let currentInputDeviceID = self.engine?.inputNode.audioUnit.flatMap {
                Self.currentInputDeviceID(for: $0)
            }
            // Preparation notifications are queued behind startRecording's sync work,
            // so by the time we run here preparation has usually finished. Only ignore
            // those delayed notifications when the configured route is still healthy;
            // otherwise a disconnect mid-settle would be silently dropped.
            if Self.shouldIgnoreConfigurationChange(
                occurredDuringRecordingPreparation: occurredDuringRecordingPreparation,
                isStillPreparingRecording: self.isPreparingRecording,
                isRecording: wasRecording,
                engineIsRunning: self.engine?.isRunning == true,
                elapsedSinceRecordingStart: elapsedSinceRecordingStart,
                configuredInputDeviceID: self.configuredInputDeviceID,
                currentInputDeviceID: currentInputDeviceID
            ) {
                VocaLogger.info(.audioEngine, "Configuration change did not disrupt the configured recording route")
                return
            }

            if wasRecording {
                VocaLogger.warning(.audioEngine, "Configuration changed while recording — forcing stop and reset")
                // Tear down the stale recording state
                self._isCurrentlyRecording = false
                self.silenceCallbackFired = false
                self.maxDurationCallbackFired = false
                self.removeInputTap(reason: "audio configuration change")
                self.engine?.stop()
            }

            // Drop the engine entirely so the next recording starts from a
            // clean instance bound to the new default device.
            self.releaseEngine()
            VocaLogger.info(.audioEngine, "Audio engine released after configuration change")

            if wasRecording {
                // Notify AppState on the main queue so it can handle the interrupted recording
                DispatchQueue.main.async { [weak self] in
                    self?.onAudioDeviceChanged?()
                }
            }
        }
    }

    // MARK: - Permission Handling

    /// Check current microphone permission status (tri-state)
    func checkPermissionStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Request microphone permission from the user
    func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    // MARK: - Recording Control

    /// Start recording audio from the microphone
    /// - Parameters:
    ///   - silenceThreshold: RMS energy threshold below which audio is considered silence
    ///   - silenceDuration: Seconds of silence before triggering silence detection callback
    ///   - maxDuration: Maximum recording duration in seconds
    /// - Returns: `true` when the engine is recording, otherwise `false`.
    @discardableResult
    func startRecording(
        silenceThreshold: Float = 0.01,
        silenceDuration: Double = 2.0,
        maxDuration: TimeInterval = 60.0,
        preferredInputDeviceID: String? = nil
    ) -> Bool {
        lifecycleQueue.sync {
            guard !self._isCurrentlyRecording else { return true }

            self.setIsPreparingRecording(true)
            defer { self.setIsPreparingRecording(false) }

            self.silenceThreshold = silenceThreshold
            self.silenceDuration = silenceDuration
            self.maxDuration = maxDuration

            resetRecordingState()

            for attempt in 1...2 {
                let engine = acquireEngine()
                let inputNode = engine.inputNode
                guard let configuredInputDeviceID = configureInputRoute(
                    preferredInputDeviceID: preferredInputDeviceID,
                    engine: engine,
                    inputNode: inputNode
                ) else {
                    recoverFromStartFailure(notifyAppState: false)
                    return false
                }
                self.configuredInputDeviceID = configuredInputDeviceID
                let inputFormat = inputNode.outputFormat(forBus: 0)

                guard isValidInputFormat(inputFormat) else {
                    VocaLogger.error(
                        .audioEngine,
                        "Invalid input format before recording start: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)"
                    )
                    recoverFromStartFailure(notifyAppState: false)
                    return false
                }

                // A previous failed start can leave a tap installed even when our
                // recording flag is false. Remove any stale tap before installing a
                // fresh one; otherwise AVAudioEngine raises an uncaught NSException.
                removeInputTap(reason: "pre-start cleanup")

                var startError: Error?
                let exception = VocaObjCExceptionCatcher.catchException { [weak self] in
                    guard let self = self else { return }

                    inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                        self?.processAudioBuffer(buffer, inputFormat: inputFormat)
                    }

                    engine.prepare()

                    do {
                        try engine.start()
                    } catch {
                        startError = error
                    }
                }

                if let exception {
                    VocaLogger.error(.audioEngine, "AVAudioEngine exception while starting recording: \(exception.localizedDescription)")
                    recoverFromStartFailure(notifyAppState: false)
                    return false
                }

                if let startError {
                    VocaLogger.error(
                        .audioEngine,
                        "Failed to start audio engine (attempt \(attempt)): \(Self.describeCoreAudioError(startError))"
                    )
                    recoverFromStartFailure(notifyAppState: false)

                    if Self.shouldRetryStart(after: startError, attempt: attempt) {
                        VocaLogger.warning(.audioEngine, "Retrying audio engine start after hardware-not-running error")
                        continue
                    }
                    return false
                }

                guard engine.isRunning else {
                    VocaLogger.warning(.audioEngine, "Audio engine stopped during route configuration (attempt \(attempt))")
                    recoverFromStartFailure(notifyAppState: false)
                    if attempt == 1 {
                        continue
                    }
                    return false
                }

                // Anchor max-duration / startup recovery to the moment capture
                // actually begins, not the start of Bluetooth route settling.
                recordingStartTime = Date()
                lastSoundTime = Date()
                _isCurrentlyRecording = true
                return true
            }

            return false
        }
    }

    /// Stop recording and return the captured audio samples
    /// - Returns: Array of Float32 PCM samples at 16kHz mono
    func stopRecording() -> [Float] {
        lifecycleQueue.sync {
            guard _isCurrentlyRecording else { return [] }

            _isCurrentlyRecording = false
            removeInputTap(reason: "stop recording")
            engine?.stop()

            let samples = capturedSamplesAndResetBuffer()

            // Keep the stopped engine briefly so rapid push-to-talk recordings
            // don't cold-reacquire a silent input route, then release it so we
            // don't keep forcing Bluetooth headsets into HFP while idle.
            scheduleEngineRelease()

            return samples
        }
    }

    /// Forcibly reset the audio engine to a clean state, regardless of current state.
    /// This is a last-resort recovery mechanism — it unconditionally tears down
    /// taps, stops the engine, clears buffers, and resets all flags.
    /// Use when the engine is suspected to be in an inconsistent state.
    func forceReset() {
        lifecycleQueue.sync {
            VocaLogger.warning(.audioEngine, "Force reset requested (wasRecording=\(_isCurrentlyRecording))")

            _isCurrentlyRecording = false
            silenceCallbackFired = false
            maxDurationCallbackFired = false

            removeInputTap(reason: "force reset")
            engine?.stop()
            engine?.reset()
            clearAudioBuffer()

            // Drop the engine entirely so the input route is released. The
            // next recording will create a fresh instance.
            releaseEngine()

            VocaLogger.info(.audioEngine, "Force reset complete — engine is clean")
        }
    }

    // MARK: - Lifecycle Helpers

    /// Resets per-recording state before a new capture attempt.
    private func resetRecordingState() {
        clearAudioBuffer()
        lastSoundTime = Date()
        recordingStartTime = Date()
        silenceCallbackFired = false
        maxDurationCallbackFired = false
    }

    private func setIsPreparingRecording(_ isPreparing: Bool) {
        recordingPreparationLock.lock()
        _isPreparingRecording = isPreparing
        recordingPreparationLock.unlock()
    }

    /// Clears captured audio samples while preserving buffer capacity.
    private func clearAudioBuffer() {
        bufferQueue.sync {
            audioBuffer.removeAll(keepingCapacity: true)
        }
    }

    /// Returns captured samples and clears the backing buffer.
    private func capturedSamplesAndResetBuffer() -> [Float] {
        bufferQueue.sync {
            let copy = audioBuffer
            audioBuffer.removeAll(keepingCapacity: true)
            return copy
        }
    }

    /// Checks whether a hardware input format is safe to pass to AVAudioEngine.
    /// Invalid or transient formats can cause installTap to raise NSException.
    private func isValidInputFormat(_ format: AVAudioFormat) -> Bool {
        format.sampleRate.isFinite && format.sampleRate > 0 && format.channelCount > 0
    }

    /// Removes the current input tap while converting AVFoundation NSExceptions
    /// into log messages instead of process aborts. No-op if the engine has
    /// already been released.
    private func removeInputTap(reason: String) {
        guard let engine else { return }
        let exception = VocaObjCExceptionCatcher.catchException {
            engine.inputNode.removeTap(onBus: 0)
        }

        if let exception {
            VocaLogger.warning(.audioEngine, "Ignoring AVAudioEngine exception while removing tap during \(reason): \(exception.localizedDescription)")
        }
    }

    /// Restores AudioEngine to a clean idle state after any failed start attempt.
    private func recoverFromStartFailure(notifyAppState: Bool) {
        _isCurrentlyRecording = false
        silenceCallbackFired = false
        maxDurationCallbackFired = false
        removeInputTap(reason: "start failure")
        engine?.stop()
        engine?.reset()
        clearAudioBuffer()

        // Release the engine so a failed start doesn't leave us holding the
        // system input route (and forcing AirPods into HFP) until the next
        // attempt.
        releaseEngine()

        if notifyAppState {
            DispatchQueue.main.async { [weak self] in
                self?.onAudioDeviceChanged?()
            }
        }
    }

    static func shouldRetryStart(after error: Error, attempt: Int) -> Bool {
        guard attempt == 1 else { return false }
        return OSStatus(truncatingIfNeeded: (error as NSError).code) == kAudioHardwareNotRunningError
    }

    static func shouldIgnoreConfigurationChange(
        occurredDuringRecordingPreparation: Bool = false,
        isStillPreparingRecording: Bool = false,
        isRecording: Bool,
        engineIsRunning: Bool,
        elapsedSinceRecordingStart: TimeInterval,
        configuredInputDeviceID: AudioDeviceID?,
        currentInputDeviceID: AudioDeviceID?,
        recoveryWindow: TimeInterval = startupConfigurationChangeRecoveryWindow
    ) -> Bool {
        // Still inside configureInputRoute / startRecording on lifecycleQueue.
        if isStillPreparingRecording {
            return true
        }

        let routeIsHealthy = isConfiguredRouteHealthy(
            configuredInputDeviceID: configuredInputDeviceID,
            currentInputDeviceID: currentInputDeviceID
        )

        // A notification posted during preparation but processed after start must
        // not be ignored blindly: if the headset disconnected mid-settle, recover.
        if occurredDuringRecordingPreparation {
            return isRecording && engineIsRunning && routeIsHealthy
        }

        return isRecording
            && engineIsRunning
            && elapsedSinceRecordingStart >= 0
            && elapsedSinceRecordingStart <= recoveryWindow
            && routeIsHealthy
    }

    /// True when the live AudioUnit device matches the configured one, or is an
    /// acceptable Bluetooth HFP sibling of that headset.
    static func isConfiguredRouteHealthy(
        configuredInputDeviceID: AudioDeviceID?,
        currentInputDeviceID: AudioDeviceID?
    ) -> Bool {
        guard let configuredInputDeviceID, let currentInputDeviceID else {
            return false
        }
        if configuredInputDeviceID == currentInputDeviceID {
            return true
        }
        return isAcceptableBluetoothRouteSubstitute(
            targetDeviceID: configuredInputDeviceID,
            actualDeviceID: currentInputDeviceID
        )
    }

    static func describeCoreAudioError(_ error: Error) -> String {
        let nsError = error as NSError
        var parts = [nsError.localizedDescription, "domain=\(nsError.domain)", "code=\(nsError.code)"]

        if let fourCC = fourCharacterCode(forOSStatusCode: nsError.code) {
            parts.append("'\(fourCC)'")
        }

        return parts.joined(separator: " ")
    }

    static func fourCharacterCode(forOSStatusCode code: Int) -> String? {
        let value = UInt32(bitPattern: Int32(truncatingIfNeeded: code))
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]

        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return nil
        }

        return String(bytes: bytes, encoding: .ascii)
    }

    // MARK: - Audio Processing

    /// Whether silence detection has already fired (prevents repeated callbacks)
    private var silenceCallbackFired = false

    /// Whether max duration callback has already fired
    private var maxDurationCallbackFired = false

    /// Process an incoming audio buffer from AVAudioEngine
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard isCurrentlyRecording else { return }

        // Convert to whisper format (16kHz, mono, Float32)
        guard let convertedBuffer = convertToWhisperFormat(buffer, from: inputFormat) else {
            return
        }

        // Calculate audio energy for level reporting and silence detection
        let energy = calculateRMSEnergy(convertedBuffer)

        // Report audio level (throttled)
        let now = Date()
        if now.timeIntervalSince(lastLevelReportTime) >= levelReportInterval {
            lastLevelReportTime = now
            let normalizedLevel = min(energy / 0.3, 1.0)  // Normalize to 0-1 range
            onAudioLevel?(normalizedLevel)
        }

        // Always append audio samples to the buffer BEFORE checking stop conditions.
        // This ensures no audio frames are discarded when silence or max duration
        // is detected — the triggering frame and any trailing audio are preserved.
        if let channelData = convertedBuffer.floatChannelData {
            let frameCount = Int(convertedBuffer.frameLength)
            bufferQueue.sync {
                audioBuffer.reserveCapacity(audioBuffer.count + frameCount)
                for i in 0..<frameCount {
                    audioBuffer.append(channelData[0][i])
                }
            }
        }

        // Check max duration (fire callback only once)
        let elapsed = now.timeIntervalSince(recordingStartTime)
        if elapsed >= maxDuration && !maxDurationCallbackFired {
            maxDurationCallbackFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onMaxDurationReached?()
            }
            return
        }

        // Silence detection
        if energy > silenceThreshold {
            lastSoundTime = now
            silenceCallbackFired = false  // Reset so silence can be detected again after speech resumes
        } else if now.timeIntervalSince(lastSoundTime) >= silenceDuration && !silenceCallbackFired {
            silenceCallbackFired = true
            DispatchQueue.main.async { [weak self] in
                self?.onSilenceDetected?()
            }
        }
    }

    /// Convert an audio buffer to whisper.cpp's required format (16kHz, mono, Float32)
    private func convertToWhisperFormat(
        _ buffer: AVAudioPCMBuffer,
        from inputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let whisperFormat = AudioEngine.whisperFormat

        // If input is already in the right format, return as-is
        if inputFormat.sampleRate == whisperFormat.sampleRate
            && inputFormat.channelCount == whisperFormat.channelCount
            && inputFormat.commonFormat == whisperFormat.commonFormat {
            return buffer
        }

        // Create a converter
        guard let converter = AVAudioConverter(from: inputFormat, to: whisperFormat) else {
            VocaLogger.error(.audioEngine, "Failed to create audio format converter")
            return nil
        }

        // Calculate output frame capacity based on sample rate ratio
        let ratio = whisperFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: whisperFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            VocaLogger.error(.audioEngine, "Conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }

    /// Calculate the RMS (root mean square) energy of an audio buffer
    private func calculateRMSEnergy(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0.0 }

        var sumSquares: Float = 0.0
        for i in 0..<frameCount {
            let sample = channelData[0][i]
            sumSquares += sample * sample
        }

        return sqrt(sumSquares / Float(frameCount))
    }

    // MARK: - Audio Device Enumeration

    /// List available audio input devices.
    static func availableInputDevices() -> [AudioDevice] {
        let defaultDeviceID = defaultInputAudioDeviceID()

        return inputAudioDeviceIDs().compactMap { deviceID in
            guard let uid = audioDeviceUID(for: deviceID),
                  let name = audioDeviceName(for: deviceID) else {
                return nil
            }

            return AudioDevice(
                id: uid,
                name: name,
                isDefault: deviceID == defaultDeviceID,
                sampleRate: audioDeviceSampleRate(for: deviceID),
                channelCount: inputChannelCount(for: deviceID)
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Configure this engine's input unit before building the recording graph.
    /// Setting CurrentDevice can asynchronously invalidate AVAudioEngine's formats,
    /// so a real route change is allowed to settle and the graph is reset before
    /// the tap's format is queried.
    ///
    /// Bluetooth headsets additionally switch from A2DP to HFP/SCO when the mic is
    /// activated. That profile change can take multiple seconds and may temporarily
    /// clear CurrentDevice across `engine.reset()`, so we poll, re-apply, and only
    /// then verify the active route.
    private func configureInputRoute(
        preferredInputDeviceID: String?,
        engine: AVAudioEngine,
        inputNode: AVAudioInputNode
    ) -> AudioDeviceID? {
        let requestedUID = preferredInputDeviceID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedDeviceID = requestedUID.flatMap(Self.inputAudioDeviceID(forUID:))
        let defaultDeviceID = Self.defaultInputAudioDeviceID()

        if let requestedUID, !requestedUID.isEmpty, requestedDeviceID == nil {
            VocaLogger.warning(.audioEngine, "Preferred input device unavailable, falling back to system default: \(requestedUID)")
        }

        guard let targetDeviceID = requestedDeviceID ?? defaultDeviceID else {
            VocaLogger.warning(.audioEngine, "No input device is available")
            return nil
        }

        guard let audioUnit = inputNode.audioUnit else {
            VocaLogger.warning(.audioEngine, "Input node has no AudioUnit; unable to verify the requested input route")
            return nil
        }

        let isBluetoothTarget = Self.isBluetoothDevice(targetDeviceID)
        let routeTimeout = Self.inputRouteTimeout(isBluetooth: isBluetoothTarget)
        let currentDeviceID = Self.currentInputDeviceID(for: audioUnit)
        guard Self.shouldReconfigureInputDevice(
            currentDeviceID: currentDeviceID,
            targetDeviceID: targetDeviceID
        ) else {
            // Warm engines can keep CurrentDevice while Bluetooth has already
            // fallen back to A2DP. Settle HFP before installing the tap, and if
            // Core Audio moves to an HFP sibling endpoint, return that ID so
            // later route-health checks match the live device.
            if isBluetoothTarget {
                Self.waitForBluetoothHFPIfNeeded(deviceID: targetDeviceID, timeout: routeTimeout)
                if let settledDeviceID = Self.currentInputDeviceID(for: audioUnit),
                   settledDeviceID != targetDeviceID,
                   Self.isAcceptableBluetoothRouteSubstitute(
                    targetDeviceID: targetDeviceID,
                    actualDeviceID: settledDeviceID
                   ) {
                    // Match the cold path: settle against the live HFP endpoint
                    // before the tap format is read.
                    Self.waitForBluetoothHFPIfNeeded(deviceID: settledDeviceID, timeout: routeTimeout)
                    let substituteName = Self.audioDeviceName(for: settledDeviceID) ?? "bluetooth input"
                    VocaLogger.info(.audioEngine, "Warm Bluetooth route resolved to HFP endpoint: \(substituteName)")
                    return settledDeviceID
                }
            }
            let deviceName = Self.audioDeviceName(for: targetDeviceID) ?? requestedUID ?? "system default"
            VocaLogger.debug(.audioEngine, "Input device already configured: \(deviceName)")
            return targetDeviceID
        }

        // Observe directly on Core Audio's posting queue. startRecording holds
        // lifecycleQueue, so waiting for the normal handler would deadlock.
        let routeChangeSignal = DispatchSemaphore(value: 0)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            routeChangeSignal.signal()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        guard Self.applyInputDevice(targetDeviceID, to: audioUnit) else {
            VocaLogger.warning(.audioEngine, "Failed to set input device \(targetDeviceID)")
            return nil
        }

        let deviceIDImmediatelyAfterSet = Self.currentInputDeviceID(for: audioUnit)
        if deviceIDImmediatelyAfterSet != targetDeviceID {
            VocaLogger.debug(.audioEngine, "Input route change is still pending after AudioUnitSetProperty")
        }

        // Wait for either a configuration notification or the device ID to stick.
        // Bluetooth HFP negotiation commonly exceeds the short wired timeout.
        let appliedBeforeReset = Self.waitForInputDevice(
            targetDeviceID,
            on: audioUnit,
            signal: routeChangeSignal,
            timeout: routeTimeout
        )
        if !appliedBeforeReset {
            VocaLogger.debug(.audioEngine, "Requested input device not confirmed before graph rebuild; continuing with rebuild")
        }

        // Apple documents that configuration changes stop and uninitialize the
        // engine while leaving connections with their previous formats. There is
        // no tap yet, so reset now and query the new hardware format afterwards.
        engine.stop()
        engine.reset()

        var deviceIDAfterReset = Self.currentInputDeviceID(for: audioUnit)
        if !Self.shouldAcceptConfiguredInputRoute(
            targetDeviceID: targetDeviceID,
            deviceIDAfterReset: deviceIDAfterReset
        ) {
            // `reset()` can drop a Bluetooth CurrentDevice mid-profile-switch.
            // Re-apply and wait again before giving up.
            VocaLogger.debug(.audioEngine, "Re-applying input device after graph reset")
            guard Self.applyInputDevice(targetDeviceID, to: audioUnit) else {
                VocaLogger.warning(.audioEngine, "Failed to re-apply input device after rebuilding the graph")
                return nil
            }
            _ = Self.waitForInputDevice(
                targetDeviceID,
                on: audioUnit,
                signal: routeChangeSignal,
                timeout: routeTimeout
            )
            deviceIDAfterReset = Self.currentInputDeviceID(for: audioUnit)
        }

        // Bluetooth profile switches can expose a sibling input endpoint with a
        // different AudioDeviceID. Accept that sibling when it shares the UID or
        // name of the requested headset.
        let resolvedDeviceID: AudioDeviceID
        if Self.shouldAcceptConfiguredInputRoute(
            targetDeviceID: targetDeviceID,
            deviceIDAfterReset: deviceIDAfterReset
        ) {
            resolvedDeviceID = targetDeviceID
        } else if isBluetoothTarget,
                  let deviceIDAfterReset,
                  Self.isAcceptableBluetoothRouteSubstitute(
                    targetDeviceID: targetDeviceID,
                    actualDeviceID: deviceIDAfterReset
                  ) {
            let substituteName = Self.audioDeviceName(for: deviceIDAfterReset) ?? "bluetooth input"
            VocaLogger.info(.audioEngine, "Using Bluetooth HFP input endpoint: \(substituteName)")
            resolvedDeviceID = deviceIDAfterReset
        } else {
            let actualDescription = deviceIDAfterReset.map(String.init) ?? "none"
            VocaLogger.warning(
                .audioEngine,
                "Core Audio did not apply the requested input device after rebuilding the graph (wanted \(targetDeviceID), got \(actualDescription), bluetooth=\(isBluetoothTarget))"
            )
            return nil
        }

        // Wait for A2DP → HFP/SCO after the route is confirmed so the tap is
        // installed against the headset mic format, not the stale A2DP rate.
        if isBluetoothTarget {
            Self.waitForBluetoothHFPIfNeeded(deviceID: resolvedDeviceID, timeout: routeTimeout)
        }

        let deviceName = Self.audioDeviceName(for: resolvedDeviceID) ?? requestedUID ?? "system default"
        VocaLogger.info(.audioEngine, "Using input device: \(deviceName)")
        return resolvedDeviceID
    }

    static func shouldReconfigureInputDevice(
        currentDeviceID: AudioDeviceID?,
        targetDeviceID: AudioDeviceID
    ) -> Bool {
        currentDeviceID != targetDeviceID
    }

    static func shouldAcceptConfiguredInputRoute(
        targetDeviceID: AudioDeviceID,
        deviceIDAfterReset: AudioDeviceID?
    ) -> Bool {
        deviceIDAfterReset == targetDeviceID
    }

    static func inputRouteTimeout(isBluetooth: Bool) -> TimeInterval {
        isBluetooth ? bluetoothInputRouteConfigurationTimeout : inputRouteConfigurationTimeout
    }

    static func isBluetoothTransport(_ transportType: UInt32) -> Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    static func hasBluetoothHFPSettled(
        sampleRate: Double?,
        threshold: Double = bluetoothHFPSampleRateThreshold
    ) -> Bool {
        guard let sampleRate, sampleRate > 0 else { return false }
        return sampleRate < threshold
    }

    static func isAcceptableBluetoothRouteSubstitute(
        targetUID: String?,
        actualUID: String?,
        targetName: String?,
        actualName: String?,
        actualIsBluetooth: Bool
    ) -> Bool {
        guard actualIsBluetooth else { return false }
        if let targetUID, let actualUID, targetUID == actualUID {
            return true
        }
        if let targetName, let actualName,
           bluetoothDeviceNamesMatch(targetName, actualName) {
            return true
        }
        return false
    }

    /// macOS often lists the same headset as "Name" (A2DP) and "Name Hands-Free" (HFP).
    static func bluetoothDeviceNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLHS = normalizeBluetoothDeviceName(lhs)
        let normalizedRHS = normalizeBluetoothDeviceName(rhs)
        guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
        return normalizedLHS.localizedCaseInsensitiveCompare(normalizedRHS) == .orderedSame
    }

    static func normalizeBluetoothDeviceName(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes = [" Hands-Free", " Hands Free", " Headset", " HFP"]
        let lowercased = result.lowercased()
        for suffix in suffixes {
            if lowercased.hasSuffix(suffix.lowercased()) {
                result = String(result.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return result
    }

    private static func isAcceptableBluetoothRouteSubstitute(
        targetDeviceID: AudioDeviceID,
        actualDeviceID: AudioDeviceID
    ) -> Bool {
        isAcceptableBluetoothRouteSubstitute(
            targetUID: audioDeviceUID(for: targetDeviceID),
            actualUID: audioDeviceUID(for: actualDeviceID),
            targetName: audioDeviceName(for: targetDeviceID),
            actualName: audioDeviceName(for: actualDeviceID),
            actualIsBluetooth: isBluetoothDevice(actualDeviceID)
        )
    }

    private static func applyInputDevice(_ deviceID: AudioDeviceID, to audioUnit: AudioUnit) -> Bool {
        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            VocaLogger.warning(.audioEngine, "AudioUnitSetProperty CurrentDevice failed: OSStatus \(status)")
            return false
        }
        return true
    }

    /// Waits until the AudioUnit reports `targetDeviceID`, or until timeout.
    /// Returns `true` when the device was observed; `false` on timeout.
    @discardableResult
    private static func waitForInputDevice(
        _ targetDeviceID: AudioDeviceID,
        on audioUnit: AudioUnit,
        signal: DispatchSemaphore,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if currentInputDeviceID(for: audioUnit) == targetDeviceID {
                return true
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let slice = min(inputRoutePollInterval, remaining)
            _ = signal.wait(timeout: .now() + slice)
        }
        return currentInputDeviceID(for: audioUnit) == targetDeviceID
    }

    private static func waitForBluetoothHFPIfNeeded(deviceID: AudioDeviceID, timeout: TimeInterval) {
        guard isBluetoothDevice(deviceID) else { return }

        let deadline = Date().addingTimeInterval(timeout)
        var lastRate = audioDeviceSampleRate(for: deviceID)
        while Date() < deadline {
            let rate = audioDeviceSampleRate(for: deviceID)
            lastRate = rate
            if hasBluetoothHFPSettled(sampleRate: rate) {
                VocaLogger.debug(.audioEngine, "Bluetooth HFP settled at \(Int(rate))Hz")
                return
            }
            Thread.sleep(forTimeInterval: inputRoutePollInterval)
        }

        VocaLogger.debug(
            .audioEngine,
            "Bluetooth HFP settle timed out at \(Int(lastRate))Hz; continuing with current route"
        )
    }

    private static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let transportType = audioDeviceTransportType(for: deviceID) else {
            return false
        }
        return isBluetoothTransport(transportType)
    }

    private static func audioDeviceTransportType(for deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &transportType)
        guard status == noErr else { return nil }
        return transportType
    }

    private static func currentInputDeviceID(for audioUnit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &dataSize
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private static func inputAudioDeviceID(forUID uid: String) -> AudioDeviceID? {
        inputAudioDeviceIDs().first { audioDeviceUID(for: $0) == uid }
    }

    private static func inputAudioDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize) == noErr else {
            VocaLogger.warning(.audioEngine, "Failed to read Core Audio device list size")
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: deviceCount)
        let status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else {
            VocaLogger.warning(.audioEngine, "Failed to read Core Audio device list: OSStatus \(status)")
            return []
        }

        return deviceIDs.filter { inputChannelCount(for: $0) > 0 }
    }

    private static func defaultInputAudioDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    private static func audioDeviceUID(for deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID)
    }

    private static func audioDeviceName(for deviceID: AudioDeviceID) -> String? {
        stringProperty(kAudioObjectPropertyName, for: deviceID)
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)

        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func audioDeviceSampleRate(for deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)

        guard status == noErr else { return 0 }
        return sampleRate
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return 0
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList)
        guard status == noErr else { return 0 }

        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) { total, buffer in
            total + Int(buffer.mNumberChannels)
        }
    }
}

// MARK: - AudioDevice

/// Represents an available audio input device
struct AudioDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
    let sampleRate: Double
    let channelCount: Int
}

// MARK: - AudioRecording Conformance

extension AudioEngine: AudioRecording {}
