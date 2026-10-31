// CalmInsightsPage.swift
// VocaMac
//
// Insights (the old Stats page): speed, words this year and time saved;
// the streak with a year of activity as a heatmap (Words or Time); where
// the user dictates, from history; personal bests. The header menu shares
// the stats card or resets the statistics.

import AppKit
import SwiftUI

/// Insights: totals, streak, heatmap and personal bests (old Stats page).
struct CalmInsightsPage: View {
    @EnvironmentObject private var appState: AppState

    @State private var metric: CalmInsightsMetric = .words
    @State private var isConfirmingReset = false
    @State private var shareState: ShareState = .idle
    /// Bumped on every share state change so a pending reset only clears
    /// the state it was scheduled for.
    @State private var shareStateToken = 0
    @State private var sharePickerAnchor = CalmSharePickerAnchor()

    /// What the last share did, shown as a line under the header.
    private enum ShareState: Equatable {
        case idle
        case copied
        case opened(StatsShareDestination, cardCopied: Bool)
        case failed(String)
    }

    var body: some View {
        // Cached on AppState: recomputed only when the stats, history or day
        // change, not on every redraw or every visit to the page.
        let summary = appState.calmInsightsSummary()
        let apps = appState.calmAppShares()
        CalmPage(.list, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                CalmPageHeader("Insights") {
                    HStack(spacing: 8) {
                        CalmSegmentedControl(
                            selection: $metric,
                            options: CalmInsightsMetric.allCases.map { CalmOption($0, $0.title) },
                            accessibilityLabel: "Measure"
                        )
                        moreMenu
                    }
                }
                if let note = shareNote {
                    CalmInlineNotice(note.text, tone: note.isError ? .warning : .success)
                        .transition(.opacity)
                }
            }
            .padding(.bottom, 4)
            .animation(.easeInOut(duration: 0.2), value: shareState)

            totals(summary)
                .settingsTarget("stats")

            CalmStreakPanel(summary: summary, days: appState.calmHeatmapDays(), metric: metric)

            bottomRow(summary: summary, apps: apps)
        }
        .onAppear { appState.statsManager.refreshCurrentStreak() }
        .calmDialog(isPresented: $isConfirmingReset) {
            CalmDialog(
                "Reset all statistics?",
                description: "This deletes your totals, streaks and daily activity from this Mac. It can’t be undone. Your dictation history is kept."
            ) {
                CalmDialogFooter(primaryTitle: "Reset", primaryKind: .destructive) {
                    appState.statsManager.resetStats()
                    clearShareState()
                }
            }
        }
    }

    // MARK: Totals

    private func totals(_ summary: CalmInsightsSummary) -> some View {
        var yearNote = "On \(CalmFormat.count(summary.yearActiveDays, "day"))"
        if summary.lifetimeWords > summary.yearWords {
            yearNote += " · \(CalmFormat.number(summary.lifetimeWords)) all time"
        }
        return HStack(spacing: 12) {
            CalmStatCard(
                value: CalmFormat.number(summary.wordsPerMinute), label: "words a minute",
                note: summary.speedNote ?? "Your speaking speed"
            )
            // The 53-week grid, not the calendar year.
            CalmStatCard(value: CalmFormat.number(summary.yearWords), label: "words in the past year", note: yearNote)
            CalmStatCard(
                value: CalmFormat.saved(summary.savedSeconds), label: "saved",
                note: "Compared with typing at \(Int(CalmInsightsSummary.typingWPM)) wpm"
            )
        }
        .help(
            "All time: \(CalmFormat.count(summary.lifetimeWords, "word")) in "
                + "\(CalmFormat.count(summary.lifetimeDictations, "dictation")), "
                + "\(CalmFormat.speakingTime(summary.lifetimeSpeakingSeconds)) of speaking"
        )
    }

    // MARK: Where you dictate · Personal bests

    @ViewBuilder
    private func bottomRow(summary: CalmInsightsSummary, apps: [CalmAppShare]) -> some View {
        let bests = bestRows(summary)
        if !apps.isEmpty || !bests.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                if !apps.isEmpty {
                    CalmWhereYouDictate(apps: apps)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .calmPanelBackground()
                }
                if !bests.isEmpty {
                    CalmPersonalBests(rows: bests)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .calmPanelBackground()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bestRows(_ summary: CalmInsightsSummary) -> [CalmPersonalBests.Row] {
        var rows: [CalmPersonalBests.Row] = []
        if let rate = appState.calmEditFreeRate() {
            rows.append(.init(
                title: "Sent without edits", value: "\(rate.percent)%",
                help: "Of the last \(CalmFormat.count(rate.observed, "dictation")) VocaMac read back after typing, "
                    + "the share you didn’t change. Needs History and learning from your corrections."
            ))
        }
        if let words = summary.biggestDayWords {
            rows.append(.init(title: "Biggest day", value: CalmFormat.count(words, "word")))
        }
        if let seconds = summary.longestDictationSeconds {
            rows.append(.init(title: "Longest dictation", value: CalmFormat.duration(seconds)))
        }
        if let seconds = summary.fastestStopWaitSeconds {
            rows.append(.init(
                title: "Fastest wait after you stop", value: CalmFormat.wait(seconds),
                help: "From letting go of the key to your text reaching the app."
            ))
        }
        let waitHelp = "Median time from letting go of the key to your text reaching the app, for dictations over "
            + "\(Int(UserStats.comparedStopWaitSeconds)) seconds. Process while speaking is in Settings › System."
        if let wait = summary.medianStopWait {
            let title = summary.medianStopWaitWithoutProcessing == nil
                ? "Usual wait after you stop" : "Usual wait with Process while speaking"
            rows.append(.init(
                title: title, value: CalmFormat.wait(wait.seconds),
                help: "\(waitHelp) \(CalmFormat.count(wait.count, "dictation"))."
            ))
        }
        if let wait = summary.medianStopWaitWithoutProcessing {
            rows.append(.init(
                title: "Usual wait without it", value: CalmFormat.wait(wait.seconds),
                help: "\(waitHelp) \(CalmFormat.count(wait.count, "dictation"))."
            ))
        }
        return rows
    }

    // MARK: Share menu

    private var moreMenu: some View {
        Menu {
            ForEach(StatsShareDestination.allCases) { destination in
                Button("Share on \(destination.displayName)…") { share(to: destination) }
            }
            Button("Share with Other Apps…") { showSharePicker() }
            Button("Copy Card Image") { copyCardImage() }
            Divider()
            Button("Reset All Statistics…", role: .destructive) { isConfirmingReset = true }
        } label: {
            CalmIconMenuLabel("Share and more", icon: .more, size: 18, weight: 2.4)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(CalmIconButtonStyle())
        .focusEffectDisabled()
        .fixedSize()
        .background(CalmSharePickerAnchorView(anchor: sharePickerAnchor))
        .disabled(!appState.hasStatistics)
        .help("Share your stats card, or reset your statistics")
        .accessibilityLabel("Share and more")
    }

    /// The line under the header. Never claims the card is on the clipboard
    /// unless it is: the user pastes whatever is there into a public post.
    private var shareNote: (text: String, isError: Bool)? {
        switch shareState {
        case .idle:
            return nil
        case .copied:
            return ("Card image copied.", false)
        case .opened(let destination, let cardCopied):
            guard cardCopied else {
                return ("Couldn’t copy the card image, so your \(destination.displayName) post has the text only.", true)
            }
            return ("Card copied. Paste it into your \(destination.displayName) post.", false)
        case .failed(let message):
            return (message, true)
        }
    }

    private func setShareState(_ state: ShareState, clearingAfter seconds: Double) {
        shareStateToken += 1
        let token = shareStateToken
        shareState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if shareStateToken == token { shareState = .idle }
        }
    }

    private func clearShareState() {
        shareStateToken += 1
        shareState = .idle
    }

    /// Social composers can't take an attachment, so the card lands on the
    /// clipboard and the user pastes it into the prefilled post.
    private func share(to destination: StatsShareDestination) {
        let snapshot = StatsShareSnapshot.from(appState.statsManager.stats)
        switch StatsShareExporter.share(snapshot, to: destination) {
        case .shared:
            setShareState(.opened(destination, cardCopied: true), clearingAfter: 4)
        case .sharedWithoutCard:
            setShareState(.opened(destination, cardCopied: false), clearingAfter: 6)
        case .failed:
            setShareState(.failed("Couldn’t open \(destination.displayName)."), clearingAfter: 6)
        }
    }

    /// For apps with no composer URL of their own. The picker pops up from
    /// the header's menu button.
    private func showSharePicker() {
        guard let view = sharePickerAnchor.view else {
            setShareState(.failed("Couldn’t open the share picker."), clearingAfter: 6)
            return
        }
        let snapshot = StatsShareSnapshot.from(appState.statsManager.stats)
        // The menu is still closing when its action runs, and a picker shown
        // during that would be dismissed along with it.
        DispatchQueue.main.async {
            StatsShareExporter.showSharePicker(for: snapshot, relativeTo: view)
        }
    }

    private func copyCardImage() {
        let snapshot = StatsShareSnapshot.from(appState.statsManager.stats)
        guard StatsShareExporter.copyImage(toClipboard: snapshot) else {
            setShareState(.failed("Couldn’t copy the card image."), clearingAfter: 6)
            return
        }
        setShareState(.copied, clearingAfter: 2)
    }
}

// MARK: - Streak and heatmap

/// The streak panel: flame, streak and best streak, the year as a
/// heatmap, the selected day's detail line and the legend.
private struct CalmStreakPanel: View {
    let summary: CalmInsightsSummary
    /// The heatmap's days, oldest first (`CalmActivityCalendar.heatmapDays`).
    let days: [CalmActivityDay]
    let metric: CalmInsightsMetric

    @EnvironmentObject private var appState: AppState
    /// The clicked day's key; nil means today. A key, not a grid index,
    /// so the selection stays on its day when a new week starts.
    @State private var selectedKey: String?
    @State private var hoveredIndex: Int?
    @State private var availableWidth: CGFloat = 800

    private static let labelColumn: CGFloat = 24
    private static let labelGap: CGFloat = 6
    /// The design lets the grid run into the panel's trailing padding.
    private static let trailingOverhang: CGFloat = 22

    var body: some View {
        let calendar = appState.statsCalendar
        let stats = appState.statsManager.stats
        let todayIndex = days.lastIndex { !$0.isFuture } ?? max(0, days.count - 1)
        let selected = selectedKey.flatMap { key in days.firstIndex { $0.key == key } } ?? todayIndex
        let shown = hoveredIndex.flatMap { days.indices.contains($0) && !days[$0].isFuture ? $0 : nil } ?? selected
        VStack(alignment: .leading, spacing: 14) {
            header
            heatmap(days: days, selected: selected, todayIndex: todayIndex, calendar: calendar, stats: stats)
            HStack(alignment: .center) {
                if days.indices.contains(shown) {
                    Text(days[shown].detail(for: metric, averageWPM: stats.averageWPM, calendar: calendar))
                        .font(CalmFont.note)
                        .foregroundStyle(CalmColor.ink2)
                        .monospacedDigit()
                }
                Spacer(minLength: 12)
                CalmHeatLegend()
            }
            .padding(.leading, Self.labelColumn + Self.labelGap)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .calmPanelBackground()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            CalmIcon(.flame, size: 22)
                .foregroundStyle(CalmColor.amber)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(CalmColor.amberSoft))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(CalmFormat.number(summary.currentStreak))
                        .font(.system(size: 26, weight: .regular, design: .serif))
                        .foregroundStyle(CalmColor.ink)
                        .monospacedDigit()
                    Text("day streak")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(CalmColor.ink)
                }
                Text(summary.streakNudge)
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Best streak")
                    .font(CalmFont.note)
                    .foregroundStyle(CalmColor.muted)
                Text(CalmFormat.count(summary.bestStreak, "day"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CalmColor.ink)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Heatmap

    /// Fits the year into the panel's inner width plus the trailing
    /// overhang the design lets the grid use.
    private func fit() -> CalmHeatmapFit {
        let room = availableWidth + Self.trailingOverhang - Self.labelColumn - Self.labelGap
        return CalmHeatmapFit.fit(width: room, weekCount: CalmActivityCalendar.weekCount)
    }

    private func heatmap(
        days: [CalmActivityDay], selected: Int, todayIndex: Int, calendar: Calendar, stats: UserStats
    ) -> some View {
        let fit = fit()
        let cell = fit.cell
        let gap = fit.gap
        let step = cell + gap
        let allColumns = days.count / 7
        let columns = min(fit.weeks, allColumns)
        // When the panel is too narrow for a year, the oldest weeks go.
        let firstColumn = allColumns - columns
        let offset = firstColumn * 7
        let months = CalmActivityCalendar.monthLabels(for: days, calendar: calendar)
        let rowLabels = CalmActivityCalendar.weekdayRowLabels(calendar: calendar)
        let wpm = stats.averageWPM
        return HStack(alignment: .top, spacing: Self.labelGap) {
            VStack(alignment: .leading, spacing: gap) {
                ForEach(0..<7, id: \.self) { row in
                    Text(rowLabels[row])
                        .font(.system(size: 10))
                        .foregroundStyle(CalmColor.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: Self.labelColumn, height: cell, alignment: .leading)
                }
            }
            .padding(.top, 12 + 6)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: gap) {
                    ForEach(firstColumn..<allColumns, id: \.self) { column in
                        Text(months[column])
                            .font(.system(size: 10))
                            .foregroundStyle(CalmColor.muted)
                            .fixedSize()
                            .frame(width: cell, height: 12, alignment: .leading)
                    }
                }
                .accessibilityHidden(true)

                HStack(alignment: .top, spacing: gap) {
                    ForEach(firstColumn..<allColumns, id: \.self) { column in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { row in
                                let index = column * 7 + row
                                let day = days[index]
                                CalmHeatCell(
                                    level: day.level(for: metric, averageWPM: wpm),
                                    size: cell,
                                    isSelected: index == selected
                                )
                                .opacity(day.isFuture ? 0 : 1)
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoveredIndex = index(at: point, step: step, offset: offset, count: days.count)
                    case .ended: hoveredIndex = nil
                    }
                }
                .onTapGesture { point in
                    guard let index = index(at: point, step: step, offset: offset, count: days.count),
                          !days[index].isFuture else { return }
                    select(index, in: days, todayIndex: todayIndex)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(columns < allColumns
                    ? "Dictation activity for the past \(columns) weeks" : "Dictation activity for the past year")
                .accessibilityValue(days.indices.contains(selected)
                    ? days[selected].detail(for: metric, averageWPM: wpm, calendar: calendar) : "")
                .accessibilityAdjustableAction { direction in
                    let next: Int
                    switch direction {
                    case .increment: next = min(todayIndex, selected + 1)
                    case .decrement: next = max(offset, selected - 1)
                    @unknown default: return
                    }
                    select(next, in: days, todayIndex: todayIndex)
                }
            }
        }
        .padding(.trailing, -Self.trailingOverhang)
        // minWidth 0 so this measures the panel, not the grid inside it.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            // The panel's inner width; the grid may use the overhang beyond it.
            if width > 0, abs(width - availableWidth) > 0.5 { availableWidth = width }
        }
    }

    private func select(_ index: Int, in days: [CalmActivityDay], todayIndex: Int) {
        guard days.indices.contains(index) else { return }
        selectedKey = index == todayIndex ? nil : days[index].key
    }

    private func index(at point: CGPoint, step: CGFloat, offset: Int, count: Int) -> Int? {
        guard point.x >= 0, point.y >= 0 else { return nil }
        let column = Int(point.x / step)
        let row = Int(point.y / step)
        guard row < 7 else { return nil }
        let index = offset + column * 7 + row
        return index < count ? index : nil
    }
}

// MARK: - Where you dictate

/// Per-app shares of the words in history, as bars.
private struct CalmWhereYouDictate: View {
    let apps: [CalmAppShare]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where you dictate").font(CalmFont.groupLabel).foregroundStyle(CalmColor.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(apps) { app in
                HStack(spacing: 12) {
                    Text(app.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 76, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(CalmColor.panel2)
                            // The design draws a share at twice its width, capped at full.
                            Capsule().fill(CalmColor.accent)
                                .frame(width: proxy.size.width * min(1, app.share * 2))
                        }
                    }
                    .frame(height: 8)
                    Text("\(app.percent)%")
                        .foregroundStyle(CalmColor.muted)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .font(.system(size: 13))
                .foregroundStyle(CalmColor.ink)
                .help("\(app.name): \(CalmFormat.count(app.words, "word"))")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(app.name), \(app.percent) percent")
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
    }
}

// MARK: - Personal bests

/// Label–value rows with a line between them; rows without data are left out.
private struct CalmPersonalBests: View {
    struct Row: Identifiable {
        let title: String
        let value: String
        var help: String?
        var id: String { title }
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Personal bests").font(CalmFont.groupLabel).foregroundStyle(CalmColor.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack {
                    Text(row.title).foregroundStyle(CalmColor.muted)
                    Spacer(minLength: 12)
                    Text(row.value).fontWeight(.semibold).foregroundStyle(CalmColor.ink).monospacedDigit()
                }
                .font(.system(size: 13))
                .padding(.top, index == 0 ? 0 : 10)
                .overlay(alignment: .top) {
                    if index > 0 { Rectangle().fill(CalmColor.line).frame(height: 1) }
                }
                .help(row.help ?? "")
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
    }
}

// MARK: - Share picker anchor

/// Holds the AppKit view the share picker pops up from. SwiftUI's `Menu`
/// has no view of its own to anchor an `NSSharingServicePicker` to.
private final class CalmSharePickerAnchor {
    weak var view: NSView?
}

private struct CalmSharePickerAnchorView: NSViewRepresentable {
    let anchor: CalmSharePickerAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}
