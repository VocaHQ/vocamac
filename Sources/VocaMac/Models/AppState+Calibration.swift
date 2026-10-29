// AppState+Calibration.swift
// VocaMac
//
// The accuracy test (Settings › Speech Model › Test accuracy): which models
// it runs, running it, and the result the Speech Model page shows.

import Foundation

extension AppState {

    // MARK: - Calibration

    /// The last accuracy test, if any.
    var lastCalibration: CalibrationResult? {
        CalibrationResult.decode(calibrationResultJSON)
    }

    /// The last test, when it was recorded with the input a dictation would
    /// use now (the chosen microphone, or whatever the system input is).
    var currentCalibration: CalibrationResult? {
        guard let result = lastCalibration,
              let current = inputDeviceUIDResolver(selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID),
              !result.isStale(currentDeviceUID: current) else { return nil }
        return result
    }

    /// Why the microphone didn't start for the test, when the engine knows.
    var lastMicrophoneStartFailure: AudioStartFailure? { audioEngine.lastStartFailure }

    /// The microphone a test would record with, by name.
    var calibrationDeviceName: String {
        selectedAudioDeviceName.isEmpty ? "the system default microphone" : selectedAudioDeviceName
    }

    /// Downloaded models the test can run, and why the others can't.
    ///
    /// A Custom Endpoint is left out: the test never sends a recording off
    /// this Mac.
    func calibrationCandidates() -> (candidates: [CalibrationCandidate], skipped: [CalibrationRow]) {
        var candidates: [CalibrationCandidate] = []
        var skipped: [CalibrationRow] = []
        // The test unloads the dictation model first, so its memory counts.
        let freeing = whisperService.isModelLoaded ? (currentModel?.size.ramRequiredGB ?? 0) : 0
        for info in availableModels where info.size.engine != .customEndpoint {
            let size = info.size
            guard info.isSupported, info.isDownloaded || size.isSystemManaged else { continue }
            guard modelFitsInMemory(size, freeing) else {
                skipped.append(.failed(
                    modelID: size.rawValue, modelName: size.displayName,
                    reason: "Needs more free memory than this Mac has right now."
                ))
                continue
            }
            candidates.append(CalibrationCandidate(
                size: size,
                name: size.displayName,
                identifier: modelManager.modelIdentifier(for: size),
                folder: modelManager.modelFolder(for: size)
            ))
        }
        return (candidates, skipped)
    }

    /// Run the recording through every candidate, keep the result, and end
    /// the test `token` claimed.
    ///
    /// The dictation model is unloaded first, so a test model never shares
    /// memory with it, and loaded again afterwards.
    func runCalibration(
        samples: [Float],
        passage: CalibrationPassage,
        input: CalibrationInput,
        token: UUID,
        runner: CalibrationRunner,
        progress: @escaping (CalibrationProgress) -> Void
    ) async -> CalibrationResult {
        let (candidates, skipped) = calibrationCandidates()
        await unloadActiveModel(reason: .manual)
        let compiled = CompiledModelRecord()
        let fits = modelFitsInMemory
        let rows = await runner.run(
            candidates: candidates,
            samples: samples,
            passage: passage,
            language: CalibrationScoring.transcriptionLanguage(for: passage),
            isFirstLoad: { !compiled.hasLoaded($0) },
            canLoad: { fits($0, 0) },
            didLoad: { compiled.recordLoad($0) },
            progress: progress
        )
        let result = CalibrationResult(
            date: Date(),
            passageID: passage.id,
            deviceUID: input.uid,
            deviceName: input.name,
            rows: CalibrationScoring.ranked(rows + skipped)
        )
        calibrationResultJSON = result.encoded()
        endCalibration(token)
        await ensureModelLoaded()
        return result
    }

    /// Dictate with a model the test measured.
    func useCalibratedModel(_ modelID: String) async {
        guard let size = ModelSize(rawValue: modelID) else { return }
        await loadModel(size)
    }

    /// The Speech Model page's line for a model the last test measured with
    /// this microphone: "7.3% word errors on your voice".
    func calibrationNote(for size: ModelSize) -> String? {
        guard let row = currentCalibration?.row(for: size.rawValue), let rate = row.errorRateText else { return nil }
        return "\(rate) word errors on your voice"
    }
}
