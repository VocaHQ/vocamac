// CalmModelsCalibration.swift
// VocaMac
//
// Test accuracy (Speech Model page): read a passage once, every downloaded
// model transcribes that recording, and the results say which one heard
// you best. Steps: choose a passage → read it → models run → results.

import SwiftUI

/// The accuracy test, from choosing a passage to switching model.
struct CalmCalibrationDialog: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.calmDismissDialog) private var dismissDialog

    private enum Step: Equatable {
        case choose
        case starting
        case recording(startedAt: Date)
        case testing(CalibrationProgress?)
        case results(CalibrationResult)
        case problem(String)
    }

    @State private var step: Step = .choose
    @State private var passageID = CalibrationPassage.everyday.id
    /// Outlives the dialog: a test closed mid-way still has to give back
    /// the microphone and its claim (see `CalibrationFlow`).
    @State private var flow = CalibrationFlow()

    private var passage: CalibrationPassage {
        CalibrationPassage.passage(withID: passageID) ?? .everyday
    }

    var body: some View {
        Group {
            switch step {
            case .choose: choose
            case .starting: starting
            case .recording(let startedAt): recording(startedAt: startedAt)
            case .testing(let progress): testing(progress)
            case .results(let result): results(result)
            case .problem(let message): problem(message)
            }
        }
        .onDisappear(perform: abandon)
    }

    // MARK: Choose

    private var choose: some View {
        let (candidates, skipped) = appState.calibrationCandidates()
        return CalmDialog(
            "Test accuracy",
            description: "Read a short passage once. Every downloaded model transcribes the same recording, so you can see which one hears you best.",
            width: CalmMetrics.dialogListWidth
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(CalibrationPassage.offered(for: appState.spokenLanguages)) { option in
                    Button { passageID = option.id } label: {
                        HStack(spacing: 12) {
                            CalmRadio(isOn: option.id == passageID)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title).font(CalmFont.sf(14, weight: 560)).foregroundStyle(CalmColor.ink)
                                Text("About \(option.wordCount) words").font(CalmFont.note).foregroundStyle(CalmColor.muted)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CalmPlainFocusStyle(radius: 8))
                    .focusEffectDisabled()
                    .accessibilityAddTraits(option.id == passageID ? .isSelected : [])
                }
            }
            Text(modelsLine(candidates.count, skipped: skipped.count))
                .calmType(.description)
                .foregroundStyle(CalmColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            if appState.isCalibrating {
                CalmInlineNotice("The last test is still finishing a model. Try again in a moment.", tone: .info)
            } else if candidates.count < 2 {
                CalmInlineNotice("Download another model to have something to compare.", tone: .info)
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Start reading",
                isPrimaryEnabled: !candidates.isEmpty && appState.micPermission == .granted && !appState.isCalibrating,
                dismissesOnPrimary: false,
                onPrimary: startRecording
            ) { EmptyView() }
        }
    }

    private func modelsLine(_ count: Int, skipped: Int) -> String {
        var line = "Records with \(appState.calibrationDeviceName). Tests \(count == 1 ? "1 model" : "\(count) models") on this Mac"
        if skipped > 0 { line += " (\(skipped) won’t fit in memory right now)" }
        line += ". Nothing leaves your Mac, and the recording isn’t kept. A model used for the first time compiles before it runs, which can take a few minutes."
        return line
    }

    // MARK: Record

    private var starting: some View {
        CalmDialog("Opening the microphone", description: "Get ready to read.") {
            HStack(spacing: 10) {
                CalmSpinner()
                Text(appState.calibrationDeviceName).font(CalmFont.note).foregroundStyle(CalmColor.muted)
            }
        } footer: {
            CalmDialogFooter(primaryTitle: "Cancel", primaryKind: .secondary, cancelTitle: nil, onPrimary: abandon) {
                EmptyView()
            }
        }
    }

    private func recording(startedAt: Date) -> some View {
        CalmDialog(
            "Read this aloud",
            description: "At your normal pace and volume, as you would dictate. Press Done when you finish.",
            width: CalmMetrics.dialogListWidth
        ) {
            Text(passage.text)
                .font(CalmFont.sf(16, weight: 450))
                .foregroundStyle(CalmColor.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .calmCard()
            HStack(spacing: 12) {
                CalmMicLevelMeter(meter: appState.audioMeter, barCount: 12)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(OverlayCopy.clock(Int(context.date.timeIntervalSince(startedAt))))
                        .monospacedDigit()
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.muted)
                }
                Spacer(minLength: 0)
                Text(flow.input?.name ?? appState.calibrationDeviceName)
                    .font(CalmFont.note).foregroundStyle(CalmColor.muted).lineLimit(1)
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Done", onCancel: cancelRecording, dismissesOnPrimary: false, onPrimary: finishRecording
            ) { EmptyView() }
        }
    }

    // MARK: Test

    private func testing(_ progress: CalibrationProgress?) -> some View {
        CalmDialog(
            "Testing models",
            description: "Each model transcribes your recording in turn. Dictation is paused until this finishes.",
            width: CalmMetrics.dialogListWidth
        ) {
            if let progress {
                CalmProgressBar(
                    value: Double(progress.index) / Double(max(progress.total, 1)),
                    title: "\(progress.modelName) (\(progress.index + 1) of \(progress.total))",
                    detail: progress.isFirstLoad ? "Compiling for this Mac first. This can take a few minutes." : nil
                )
            } else {
                HStack(spacing: 10) {
                    CalmSpinner()
                    Text("Getting ready…").font(CalmFont.note).foregroundStyle(CalmColor.muted)
                }
            }
        } footer: {
            CalmDialogFooter(
                primaryTitle: "Stop after this model", primaryKind: .secondary, cancelTitle: nil,
                dismissesOnPrimary: false, onPrimary: { flow.runner.cancel() }, leading: { EmptyView() }
            )
        }
    }

    // MARK: Results

    private func results(_ result: CalibrationResult) -> some View {
        let best = result.best
        let current = appState.currentModel?.size.rawValue
        return CalmDialog(
            "Results",
            description: best.map { row in
                let phrase = CalibrationPassage.passage(withID: result.passageID)?.winnerPhrase ?? "heard you best"
                return "\(row.modelName) \(phrase)."
            } ?? "No model could be tested.",
            width: CalmMetrics.dialogListWidth
        ) {
            VStack(spacing: 0) {
                ForEach(Array(result.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(CalmColor.line).frame(height: 1) }
                    resultRow(row, isBest: row.id == best?.id, isCurrent: row.id == current)
                }
            }
            .calmDialogScrollingList(maxHeight: 300)
            .background(RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous).fill(CalmColor.panel))
            .clipShape(RoundedRectangle(cornerRadius: CalmMetrics.Radius.panel, style: .continuous))
            Text(resultsNote(result))
                .calmType(.description)
                .foregroundStyle(CalmColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            CalmDialogFooter(primaryTitle: "Done", cancelTitle: nil, onPrimary: {}, leading: {
                Button("Test again") { step = .choose }.calmButton(.quiet)
            })
        }
    }

    private func resultRow(_ row: CalibrationRow, isBest: Bool, isCurrent: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(row.modelName).font(CalmFont.sf(14, weight: 560)).foregroundStyle(CalmColor.ink).lineLimit(1)
                    if isBest { CalmTag("Best", tone: .success) }
                    if isCurrent { CalmTag("In use") }
                }
                Text(rowDetail(row)).font(CalmFont.note).foregroundStyle(CalmColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let rate = row.errorRateText {
                Text(rate).monospacedDigit().font(CalmFont.sf(14, weight: 600)).foregroundStyle(CalmColor.ink)
                    .accessibilityLabel("\(rate) word errors")
            }
            if row.wordErrorRate != nil, !isCurrent {
                Button("Use") {
                    Task { await appState.useCalibratedModel(row.modelID) }
                }
                .calmButton(isBest ? .primary : .secondary, size: .small)
                .accessibilityLabel("Use \(row.modelName)")
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }

    private func rowDetail(_ row: CalibrationRow) -> String {
        if let failure = row.failure { return failure }
        var parts: [String] = []
        if let seconds = row.seconds { parts.append(String(format: "%.1f s", seconds)) }
        parts.append(row.lostTerms.isEmpty ? "every key word right" : "missed " + row.lostTerms.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private func resultsNote(_ result: CalibrationResult) -> String {
        var note = "Word errors: words the model got wrong, left out or added, out of every word in the passage. Lower is better."
        if let extra = CalibrationPassage.passage(withID: result.passageID)?.note { note += " " + extra }
        return note
    }

    // MARK: Problem

    private func problem(_ message: String) -> some View {
        CalmDialog("Couldn’t test", description: message) {
            CalmDialogFooter(
                primaryTitle: "Try again", dismissesOnPrimary: false,
                onPrimary: { step = .choose }, leading: { EmptyView() }
            )
        }
    }

    // MARK: Flow

    private func startRecording() {
        guard let token = appState.beginCalibration() else {
            step = .problem("The last test is still finishing a model. Try again in a moment.")
            return
        }
        let flow = flow
        flow.token = token
        step = .starting
        Task { @MainActor in
            let input = await appState.startCalibrationCapture()
            // Closed while the microphone was opening: close it again.
            if flow.isAbandoned {
                if input != nil { _ = await appState.stopCalibrationCapture() }
                appState.endCalibration(token)
                return
            }
            guard let input else {
                appState.endCalibration(token)
                let failure = appState.lastMicrophoneStartFailure
                step = .problem(failure?.message ?? "Couldn’t start \(appState.calibrationDeviceName). Pick another microphone in Settings › General.")
                return
            }
            flow.input = input
            step = .recording(startedAt: Date())
        }
    }

    private func finishRecording() {
        guard let token = flow.token, let input = flow.input else { return }
        let chosen = passage
        let flow = flow
        step = .testing(nil)
        Task { @MainActor in
            let samples = await appState.stopCalibrationCapture()
            if let problem = CalibrationScoring.recordingProblem(samples, deviceName: input.name) {
                appState.endCalibration(token)
                step = .problem(problem)
                return
            }
            let runner = CalibrationRunner()
            flow.runner = runner
            // `runCalibration` ends the claim itself, even with the dialog closed.
            let result = await appState.runCalibration(
                samples: samples, passage: chosen, input: input, token: token, runner: runner
            ) { progress in
                step = .testing(progress)
            }
            step = .results(result)
        }
    }

    private func cancelRecording() {
        abandon()
        dismissDialog?()
    }

    /// Closing the dialog mid-way: stop the microphone, stop after the model
    /// being tested, and give back the claim once nothing uses it.
    private func abandon() {
        let flow = flow
        flow.isAbandoned = true
        flow.runner.cancel()
        guard let token = flow.token else { return }
        switch step {
        case .recording:
            Task { @MainActor in
                _ = await appState.stopCalibrationCapture()
                appState.endCalibration(token)
            }
        case .choose, .problem, .results:
            appState.endCalibration(token)
        case .starting, .testing:
            // The start task, or `runCalibration`, ends it.
            break
        }
    }
}

/// One test's state that has to outlive the dialog's views: whether it was
/// abandoned, its claim on the test models, the input it recorded with, and
/// the runner to stop.
@MainActor
final class CalibrationFlow {
    var isAbandoned = false
    var token: UUID?
    var input: CalibrationInput?
    var runner = CalibrationRunner()
}
