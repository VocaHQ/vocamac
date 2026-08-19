// ServiceProtocols.swift
// VocaMac
//
// Protocol abstractions for all services that AppState depends on.
// Enables dependency injection and test mocking.

import Foundation
import Combine

// MARK: - AudioRecording

protocol AudioRecording: AnyObject {
    var isCurrentlyRecording: Bool { get }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onSilenceDetected: (() -> Void)? { get set }
    var onMaxDurationReached: (() -> Void)? { get set }
    var onAudioDeviceChanged: (() -> Void)? { get set }

    @discardableResult
    func startRecording(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?
    ) -> Bool
    @discardableResult func stopRecording() -> [Float]
    func forceReset()
    func checkPermissionStatus() -> PermissionStatus
    func requestPermission(completion: @escaping (Bool) -> Void)
}

// MARK: - SoundPlaying

protocol SoundPlaying: AnyObject {
    var volume: Float { get set }
    func playStartSound()
    func playStartSoundAsync() async
    func playStopSound()
    func playStopSoundAsync() async
    func previewStartThenStop() async
}

extension SoundPlaying {
    func previewStartThenStop() async {
        await playStartSoundAsync()
        await playStopSoundAsync()
    }
}

// MARK: - HotKeyMonitoring

protocol HotKeyMonitoring: AnyObject {
    var isListening: Bool { get }
    var eventTap: CFMachPort? { get }
    var onRecordingStart: (() -> Void)? { get set }
    var onRecordingStop: (() -> Void)? { get set }

    func checkAccessibilityPermission(prompt: Bool) -> Bool
    func startListening(keyCode: Int, mode: ActivationMode, doubleTapThreshold: Double, safetyTimeout: Double, modifiers: HotKeyModifiers)
    func stopListening()
    func resetKeyState()
    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?, modifiers: HotKeyModifiers?)
}

extension HotKeyMonitoring {
    func updateConfiguration(keyCode: Int? = nil, mode: ActivationMode? = nil, doubleTapThreshold: Double? = nil, safetyTimeout: Double? = nil, modifiers: HotKeyModifiers? = nil) {
        _updateConfiguration(keyCode: keyCode, mode: mode, doubleTapThreshold: doubleTapThreshold, safetyTimeout: safetyTimeout, modifiers: modifiers)
    }
}

// MARK: - PermissionManaging

@MainActor
protocol PermissionManaging: AnyObject {
    var micPermission: PermissionStatus { get set }
    var accessibilityPermission: PermissionStatus { get set }
    var inputMonitoringPermission: PermissionStatus { get set }
    var allPermissionsGranted: Bool { get }
    var onAllPermissionsGranted: (() -> Void)? { get set }

    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }

    func checkPermissions()
    func startPermissionPolling()
    func stopPermissionPolling()
    func requestMicrophonePermission()
    func openMicrophoneSettings()
    func requestAccessibilityPermission()
    func requestInputMonitoringPermission()
}

// MARK: - CursorOverlayManaging

@MainActor
protocol CursorOverlayManaging: AnyObject {
    func show(style: OverlayStyle, position: OverlayPosition)
    func hide()
    func transitionToProcessing()
    func updateAudioLevel(_ level: Float)
}

// MARK: - ModelManaging

protocol ModelManaging: AnyObject {
    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String])
    func modelFolder(for size: ModelSize) -> URL?
    func bundledModelFolder(for size: ModelSize) -> URL?
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool
    func ensureTokenizerAssets(for size: ModelSize) throws -> URL
    func isModelDownloaded(_ size: ModelSize) -> Bool
    func isModelSupported(_ size: ModelSize) -> Bool
    func modelIdentifier(for size: ModelSize) -> String
    func modelSize(from identifier: String) -> ModelSize?
    func downloadModel(size: ModelSize, onProgress: @escaping (Double) -> Void) async throws
    func deleteModel(_ size: ModelSize) async throws
    func diskUsageDescription() -> String
}

extension ModelManaging {
    func bundledModelFolder(for size: ModelSize) -> URL? { nil }
}

extension ModelManaging {
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool { false }
}

extension ModelManaging {
    func ensureTokenizerAssets(for size: ModelSize) throws -> URL {
        guard let folder = modelFolder(for: size) else {
            throw NSError(domain: "VocaMac.ModelManaging", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model folder unavailable for \(size.rawValue)"])
        }
        return folder
    }
}

// MARK: - SpeechTranscribing

protocol SpeechTranscribing: AnyObject {
    var loadedModelName: String? { get }
    var isModelLoaded: Bool { get }
    func transcribe(audioData: [Float], language: String?, translate: Bool, vocabulary: String) async throws -> VocaTranscription
    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws
    /// Release the currently loaded model (and any sibling engines) to free memory.
    func unloadModel() async
}

extension SpeechTranscribing {
    func loadModel(name: String? = nil, folder: URL? = nil, onPhaseChange: ((String) -> Void)? = nil) async throws {
        try await _loadModel(name: name, folder: folder, onPhaseChange: onPhaseChange)
    }
}

// MARK: - TextInjecting

protocol TextInjecting: AnyObject {
    func inject(text: String, preserveClipboard: Bool)
}

// MARK: - StatsManaging

@MainActor
protocol StatsManaging: AnyObject {
    var stats: UserStats { get }
    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }
    func recordTranscription(_ transcription: VocaTranscription)
    func resetStats()
}
