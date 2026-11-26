// AppState+Microphone.swift
// VocaMac
//
// Keeps the saved microphone pointed at the same device when its Core Audio
// UID changes (a USB mic moved to another port).

import Foundation

extension AppState {
    /// Re-points the saved microphone at the same device under its new UID.
    ///
    /// Does nothing for System Default, when the saved UID is connected, or
    /// when no single connected device matches (`AudioDeviceMatch`).
    func reconcileSelectedAudioDevice(with devices: [AudioDevice]) {
        let savedID = selectedAudioDeviceID
        guard !savedID.isEmpty,
              !devices.contains(where: { $0.id == savedID }),
              let match = AudioDeviceMatch.device(
                forSavedID: savedID,
                savedName: selectedAudioDeviceName,
                among: devices
              ) else { return }

        VocaLogger.info(.audioEngine, "Selected microphone \(match.name) reconnected with a new ID; following it")
        // The channel choice belongs to the same physical interface.
        if selectedAudioChannelDeviceID == savedID {
            selectedAudioChannelDeviceID = match.id
        }
        selectedAudioDeviceID = match.id
        selectedAudioDeviceName = match.name
    }
}
