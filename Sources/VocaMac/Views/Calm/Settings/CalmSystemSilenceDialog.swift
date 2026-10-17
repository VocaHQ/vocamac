// CalmSystemSilenceDialog.swift
// VocaMac
//
// Settings › System › Silence: how quiet counts as silence, and how long
// hands-free and double-tap dictation wait in silence before stopping.
// Applies as you change it; Done closes.

import SwiftUI

/// The Silence dialog: sensitivity and stop-after-silence.
struct CalmSilenceDialog: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isSecondsFocused: Bool

    var body: some View {
        CalmDialog("Silence", description: "How VocaMac tells you’ve stopped talking.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Sensitivity").calmType(.rowTitle)
                    Spacer(minLength: 8)
                    Text(CalmSettingsSummary.sensitivity(threshold: appState.silenceThreshold))
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.muted)
                }
                HStack(spacing: 12) {
                    Text("High").font(CalmFont.note).foregroundStyle(CalmColor.muted)
                    CalmSlider(
                        value: $appState.silenceThreshold, in: 0.001...0.05, step: 0.001, label: "Sensitivity",
                        valueText: CalmSettingsSummary.sensitivity(threshold: appState.silenceThreshold)
                    )
                    Text("Low").font(CalmFont.note).foregroundStyle(CalmColor.muted)
                }
                Text("High keeps quiet speech. Choose Low in a noisy room.")
                    .font(CalmFont.description)
                    .foregroundStyle(CalmColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop after silence").calmType(.rowTitle)
                    Text("Hands-free and double-tap only. Push to talk stops when you let go.")
                        .font(CalmFont.description)
                        .foregroundStyle(CalmColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    CalmNumberField(value: durationBinding, label: "Stop after silence, seconds", focus: $isSecondsFocused)
                        .frame(width: 64)
                    Text("seconds").font(CalmFont.description).foregroundStyle(CalmColor.muted)
                }
                .help("Between 0.5 and 300 seconds")
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {})
        }
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { appState.silenceDuration },
            set: { appState.silenceDuration = SilenceDetectionSettings.clampedDuration($0) }
        )
    }
}

/// A short numeric field in the Calm field style (h36 r9, content fill,
/// 1 pt line2; ink and the focus halo while editing).
///
/// The value is committed as you type: a formatted `TextField` only commits
/// on Return or focus loss, and Return presses the dialog's Done first, so
/// the typed number was lost when the dialog closed.
struct CalmNumberField: View {
    @Binding var value: Double
    let label: String
    var focus: FocusState<Bool>.Binding

    @State private var text = ""

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: CalmMetrics.Radius.field, style: .continuous)
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(CalmFont.field)
            .foregroundStyle(CalmColor.ink)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .focused(focus)
            .padding(.horizontal, 12)
            .frame(height: CalmMetrics.fieldHeight)
            .background(shape.fill(CalmColor.content))
            .overlay(shape.strokeBorder(focus.wrappedValue ? CalmColor.ink : CalmColor.line2, lineWidth: 1))
            .calmFieldFocusRing(focus.wrappedValue, radius: CalmMetrics.Radius.field)
            .accessibilityLabel(label)
            .onAppear { text = Self.format(value) }
            .onChange(of: text) { _, newText in
                if let number = Self.parse(newText), number != value { value = number }
            }
            // Show the stored (clamped) value once editing ends.
            .onChange(of: focus.wrappedValue) { _, focused in if !focused { text = Self.format(value) } }
            .onChange(of: value) { _, newValue in if !focus.wrappedValue { text = Self.format(newValue) } }
            .onSubmit { text = Self.format(value) }
    }

    /// “2.5”, with at most one decimal, in the user's locale.
    static func format(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
    }

    /// The number typed, or nil while it isn't one yet (empty, “2.”).
    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let number = try? Double(trimmed, format: .number.locale(locale)), number.isFinite else {
            return nil
        }
        return number
    }
}
