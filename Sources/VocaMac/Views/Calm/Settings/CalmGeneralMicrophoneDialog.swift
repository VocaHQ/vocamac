// CalmGeneralMicrophoneDialog.swift
// VocaMac
//
// The Microphone picker (Dialogs board): input devices with the live level
// on the one in use, “Follow the system input” (System Default), the
// input channel for multi-input interfaces, and the closed-lid fallback.
// Pickers apply immediately; Done just closes.

import SwiftUI

/// The microphone picker. Choosing a device or the system input applies at once.
struct CalmMicrophoneDialog: View {
    @EnvironmentObject private var appState: AppState
    @State private var devices: [AudioDevice]

    /// - Parameter devices: Devices to show before the first refresh (previews).
    init(devices: [AudioDevice] = []) {
        _devices = State(initialValue: devices)
    }

    var body: some View {
        CalmDialog("Microphone", description: "The level moves while you dictate.", width: 480) {
            if devices.isEmpty && !isSelectedUnavailable {
                CalmInlineNotice("No microphones found. Connect one, or check System Settings › Sound.", tone: .warning)
            } else {
                deviceList
            }
            if isSelectedUnavailable {
                CalmInlineNotice("\(selectedName) is unavailable. Using the system input until it reconnects.", tone: .warning)
                    .padding(.top, -8)
            }
            if let notice = appState.inputDeviceFallbackNotice {
                CalmInlineNotice(notice, tone: .warning)
                    .padding(.top, -8)
            }
            VStack(spacing: 14) {
                switchLine(
                    "Follow the system input",
                    detail: "Uses whatever macOS picks. Never changes macOS’s own setting.",
                    isOn: followsSystemBinding
                )
                if channelCount > 1 { channelLine }
                switchLine(
                    "Use an external microphone when the lid is closed",
                    detail: "Your choice comes back when you open the lid.",
                    isOn: $appState.externalMicWhenLidClosed
                )
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {}, leading: {
                Button("Refresh", action: refresh).calmButton(.quiet)
                    .help("Look for microphones again")
            })
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .vocaAudioDevicesChanged)) { _ in refresh() }
    }

    // MARK: Devices

    private var deviceList: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous)
        return VStack(spacing: 0) {
            if isSelectedUnavailable {
                deviceRow(id: appState.selectedAudioDeviceID, name: selectedName, detail: "Not connected", isOn: true) {}
                    .disabled(true)
                Rectangle().fill(CalmColor.line).frame(height: 1)
            }
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Rectangle().fill(CalmColor.line).frame(height: 1) }
                deviceRow(
                    id: device.id, name: device.name, detail: CalmSettingsSummary.deviceDetail(device),
                    isOn: device.id == activeDevice?.id
                ) {
                    select(device)
                }
            }
        }
        .calmDialogScrollingList(maxHeight: 280)
        .background(shape.fill(CalmColor.panel))
        .clipShape(shape)
    }

    private func deviceRow(
        id: String, name: String, detail: String, isOn: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CalmRadio(isOn: isOn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(CalmFont.sf(14, weight: 560)).foregroundStyle(CalmColor.ink).lineLimit(1)
                    Text(detail).font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isOn && !isSelectedUnavailable {
                    CalmMicLevelMeter(meter: appState.audioMeter, barCount: 10)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(CalmPlainFocusStyle(radius: 0))
        .focusEffectDisabled()
        .accessibilityLabel(name)
        .accessibilityValue(detail)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .id(id)
    }

    private func switchLine(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).calmType(.rowTitle).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(CalmFont.description).foregroundStyle(CalmColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CalmSwitch(isOn: isOn).accessibilityLabel(title)
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.wrappedValue.toggle() }
    }

    private var channelLine: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Input channel").calmType(.rowTitle)
                Text("The interface input your microphone is plugged into")
                    .font(CalmFont.description).foregroundStyle(CalmColor.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CalmDropdown(
                selection: channelBinding,
                options: (0..<channelCount).map { CalmOption($0, "Channel \($0 + 1)") }
            )
        }
    }

    // MARK: State

    private var selectedDevice: AudioDevice? {
        guard !appState.selectedAudioDeviceID.isEmpty else { return nil }
        return devices.first { $0.id == appState.selectedAudioDeviceID }
    }

    /// The device recordings use: the chosen one, or the system's.
    private var activeDevice: AudioDevice? {
        appState.selectedAudioDeviceID.isEmpty ? devices.first(where: \.isDefault) : selectedDevice
    }

    private var isSelectedUnavailable: Bool {
        !appState.selectedAudioDeviceID.isEmpty && selectedDevice == nil
    }

    private var selectedName: String {
        appState.selectedAudioDeviceName.isEmpty ? "Selected microphone" : appState.selectedAudioDeviceName
    }

    private var channelCount: Int { activeDevice?.channelCount ?? 0 }

    private var followsSystemBinding: Binding<Bool> {
        Binding(
            get: { appState.selectedAudioDeviceID.isEmpty },
            set: { follows in
                if follows {
                    appState.selectAudioDevice(nil)
                } else if let device = activeDevice ?? devices.first {
                    appState.selectAudioDevice(device)
                }
                syncChannel()
            }
        )
    }

    private var channelBinding: Binding<Int> {
        Binding(
            get: { appState.selectedAudioChannel },
            set: { channel in
                guard let activeDevice else { return }
                appState.selectAudioChannel(channel, for: activeDevice)
            }
        )
    }

    private func select(_ device: AudioDevice) {
        appState.selectAudioDevice(device)
        syncChannel()
    }

    private func refresh() {
        devices = appState.availableInputDevices()
        if let selectedDevice { appState.selectAudioDevice(selectedDevice) }
        syncChannel()
    }

    private func syncChannel() {
        guard let activeDevice else { return }
        appState.syncSelectedAudioChannel(with: activeDevice)
    }
}
