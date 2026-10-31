// CursorOverlayManager.swift
// VocaMac
//
// Shows the floating recording overlay: a compact dark-glass pill or a live
// panel with the words as they are recognised. It can be anchored to the
// caret or to the top/bottom edge of the active display.

import AppKit
import SwiftUI

// MARK: - Overlay Layout

/// Shared overlay dimensions keep the AppKit panel and SwiftUI content in sync.
///
/// The *card* is the visible pill or panel. The NSPanel is the card's slot
/// plus transparent room for the card's soft shadow, so sizes come in two
/// forms: `contentSize` (the slot) and `size` (the whole panel).
enum OverlayLayout {
    /// Transparent room around the card for its shadow (0 16 40 at 35%).
    static let shadowInsets = NSEdgeInsets(top: 10, left: 24, bottom: 36, right: 24)

    // MARK: Pill

    static let pillHeight: CGFloat = 40
    static let pillCornerRadius: CGFloat = 20
    /// Room for the widest pill: a label, the timer, and the Stop and Cancel
    /// buttons that appear while the pointer is over it.
    static let pillSlotWidth: CGFloat = 340
    /// A failure message wraps at this width, up to `failureMaxLines` lines.
    static let failureMaxWidth: CGFloat = 440
    static let failureMaxLines = 3
    /// Text width inside a failure pill: padding 14 + 16, icon 15, gap 10.
    static let failureTextWidth: CGFloat = failureMaxWidth - 14 - 16 - 15 - 10
    /// Room an Undo button takes beside a "Learned" message: gap 10 plus the button.
    static let learnedUndoWidth: CGFloat = 62
    /// How long a "Learned" message with its Undo button stays up.
    static let learnedDisplayDuration: TimeInterval = 6
    static let failureLineHeight: CGFloat = 17

    // MARK: Live panel

    static let liveWidth: CGFloat = 460
    static let liveCornerRadius: CGFloat = 14
    /// 15-point text at 1.5 line height.
    static let liveLineHeight: CGFloat = 22.5
    /// The words grow to this many lines, then scroll.
    static let liveMaxLines = 4
    /// Text width inside the live panel (16 on each side).
    static let liveTextWidth: CGFloat = liveWidth - 32
    /// "Editing 120 characters" above a Command Mode instruction.
    static let liveHeaderHeight: CGFloat = 16

    /// The card slot for a style at rest: a pill, or a one-line live panel.
    static func contentSize(for style: OverlayStyle) -> CGSize {
        switch style {
        case .off:
            return .zero
        case .minimal:
            return CGSize(width: pillSlotWidth, height: pillHeight)
        case .live:
            return CGSize(width: liveWidth, height: liveHeight(lines: 1, hasHeader: false))
        }
    }

    /// A failure message needs room for text in every style, including Minimal.
    static let failureContentSize = CGSize(width: failureMaxWidth, height: pillHeight)

    static func contentSize(for style: OverlayStyle, phase: IndicatorPhase) -> CGSize {
        phase == .failure ? failureContentSize : contentSize(for: style)
    }

    /// Live panel height: padding 14, optional header, the words, a divider
    /// with 10 above and below, an 18-point footer and padding 12.
    static func liveHeight(lines: Int, hasHeader: Bool) -> CGFloat {
        let lines = min(max(lines, 1), liveMaxLines)
        let header = hasHeader ? liveHeaderHeight + 10 : 0
        return 14 + header + CGFloat(lines) * liveLineHeight + 10 + 1 + 10 + 18 + 12
    }

    /// Failure pill height: one line fills the 40-point pill; more lines add
    /// their height inside 11.5 of padding.
    static func failureHeight(lines: Int) -> CGFloat {
        let lines = min(max(lines, 1), failureMaxLines)
        guard lines > 1 else { return pillHeight }
        return (CGFloat(lines) * failureLineHeight + 23).rounded(.up)
    }

    /// The whole panel for a card slot: the slot plus its shadow room.
    static func panelSize(forContent content: CGSize) -> CGSize {
        guard content != .zero else { return .zero }
        return CGSize(
            width: content.width + shadowInsets.left + shadowInsets.right,
            height: content.height + shadowInsets.top + shadowInsets.bottom
        )
    }

    static func size(for style: OverlayStyle, phase: IndicatorPhase) -> CGSize {
        panelSize(forContent: contentSize(for: style, phase: phase))
    }

    static func size(for style: OverlayStyle) -> CGSize {
        panelSize(forContent: contentSize(for: style))
    }

    /// Where the panel goes so its card slot starts at `cardOrigin`.
    static func panelOrigin(forCardOrigin cardOrigin: CGPoint) -> CGPoint {
        CGPoint(x: cardOrigin.x - shadowInsets.left, y: cardOrigin.y - shadowInsets.bottom)
    }

    /// The card slot inside a panel frame.
    static func cardFrame(inPanel frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX + shadowInsets.left,
            y: frame.minY + shadowInsets.bottom,
            width: max(0, frame.width - shadowInsets.left - shadowInsets.right),
            height: max(0, frame.height - shadowInsets.top - shadowInsets.bottom)
        )
    }

    /// The visible card inside a panel frame, in screen coordinates: the
    /// measured card at the top of its slot, at the slot's leading edge
    /// next to the caret and centred at the top or bottom of the screen
    /// (as `HandyOverlayView` lays it out). The whole slot until measured.
    ///
    /// Only this rectangle takes the pointer: the slot is as wide as the
    /// widest pill, and the panel adds shadow room on every side.
    static func visibleCardFrame(inPanel frame: CGRect, cardSize: CGSize, position: OverlayPosition) -> CGRect {
        let slot = cardFrame(inPanel: frame)
        guard cardSize.width > 0, cardSize.height > 0 else { return slot }
        let width = min(cardSize.width, slot.width)
        let height = min(cardSize.height, slot.height)
        let x = position == .nearCursor ? slot.minX : slot.midX - width / 2
        return CGRect(x: x, y: slot.maxY - height, width: width, height: height)
    }

    /// Distance from the bottom of the visible frame (the top of the Dock)
    /// to the bottom of the card.
    static let bottomEdgeGap: CGFloat = 24
    /// Distance from the top of the visible frame (under the menu bar) to the
    /// top of the card.
    static let topEdgeGap: CGFloat = 46
}

/// Measures overlay text with AppKit so the panel can be sized before the
/// SwiftUI content lays out.
enum OverlayTextMeasure {
    /// Lines `text` wraps to at `width`, at least 1.
    static func lineCount(_ text: String, font: NSFont, width: CGFloat, lineHeight: CGFloat) -> Int {
        guard !text.isEmpty, width > 0 else { return 1 }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.lineBreakMode = .byWordWrapping
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font, .paragraphStyle: style]
        )
        return max(1, Int((rect.height / lineHeight).rounded()))
    }

    /// One-line width of `text`.
    static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// The live panel's 15-point text. Measured a little narrower than it
    /// draws, so a line SwiftUI wraps a word earlier still fits.
    static var liveFont: NSFont { .systemFont(ofSize: 15) }
    /// The pill's 13-point label at the design's 550 weight (measured at
    /// semibold, slightly wider, so it never clips).
    static var pillFont: NSFont { .systemFont(ofSize: 13, weight: .semibold) }
}

/// Pure placement helpers used by the Accessibility-based cursor positioning.
/// All rects and sizes are the card's, not the panel's.
enum OverlayPlacement {
    static func origin(
        near anchorRect: CGRect,
        panelSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        let anchorPoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        guard let visibleFrame = nearestVisibleFrame(to: anchorPoint, in: visibleFrames) else {
            return CGPoint(x: anchorRect.maxX + 10, y: anchorRect.minY - panelSize.height - 8)
        }

        let rightOrigin = anchorRect.maxX + 10
        let leftOrigin = anchorRect.minX - panelSize.width - 10
        let x = rightOrigin + panelSize.width <= visibleFrame.maxX
            ? rightOrigin
            : leftOrigin

        let belowOrigin = anchorRect.minY - panelSize.height - 8
        let aboveOrigin = anchorRect.maxY + 8
        let y = belowOrigin >= visibleFrame.minY
            ? belowOrigin
            : aboveOrigin

        return clampedOrigin(
            CGPoint(x: x, y: y),
            panelSize: panelSize,
            visibleFrames: visibleFrames
        )
    }

    static func clampedOrigin(
        _ point: CGPoint,
        panelSize: CGSize,
        visibleFrames: [CGRect]
    ) -> CGPoint {
        guard let visibleFrame = nearestVisibleFrame(to: point, in: visibleFrames) else {
            return point
        }

        return CGPoint(
            x: min(max(point.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width),
            y: min(max(point.y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
        )
    }

    /// Card origin for the Top and Bottom positions: centred, `topEdgeGap`
    /// under the menu bar or `bottomEdgeGap` above the Dock.
    static func edgeOrigin(for position: OverlayPosition, cardSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        let x = visibleFrame.midX - cardSize.width / 2
        switch position {
        case .top:
            return CGPoint(x: x, y: visibleFrame.maxY - cardSize.height - OverlayLayout.topEdgeGap)
        case .bottom, .nearCursor:
            return CGPoint(x: x, y: visibleFrame.minY + OverlayLayout.bottomEdgeGap)
        }
    }

    private static func nearestVisibleFrame(to point: CGPoint, in visibleFrames: [CGRect]) -> CGRect? {
        visibleFrames.min { lhs, rhs in
            squaredDistance(from: point, to: lhs) < squaredDistance(from: point, to: rhs)
        }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let nearestX = min(max(point.x, rect.minX), rect.maxX)
        let nearestY = min(max(point.y, rect.minY), rect.maxY)
        let xDistance = point.x - nearestX
        let yDistance = point.y - nearestY
        return xDistance * xDistance + yDistance * yDistance
    }
}

/// Whether the overlay takes clicks. It does while a dictation is under way,
/// so its Stop and Cancel buttons work; otherwise clicks pass through to the
/// app underneath.
enum OverlayInteraction {
    static func acceptsClicks(in phase: IndicatorPhase) -> Bool {
        switch phase {
        case .connecting, .recording, .processing: return true
        case .idle, .failure: return false
        }
    }

    /// How long a failure message stays up: long enough to read, longer for
    /// longer messages, but never parked on screen.
    static func failureDisplayDuration(for message: String) -> TimeInterval {
        min(max(2.5 + Double(message.count) * 0.06, 4), 8)
    }
}

/// Seconds left before the recording limit, once inside the warning window.
enum RecordingCountdown {
    static let warningWindow: TimeInterval = 10

    /// Whole seconds remaining when the limit is within `warningWindow`, else nil.
    static func secondsRemaining(elapsed: TimeInterval, limit: TimeInterval?) -> Int? {
        guard let limit, limit > 0, elapsed >= 0 else { return nil }
        let remaining = limit - elapsed
        guard remaining <= warningWindow else { return nil }
        return max(0, Int(remaining.rounded(.up)))
    }
}

// MARK: - Stop Hint

/// How the current dictation ends, so the overlay can say so ("Let go of
/// Right ⌥ to type") and label a recording that won't stop on release.
enum OverlayStopHint: Equatable, Sendable {
    /// Push to talk: letting go of the key types the text.
    case hold(key: String)
    /// Double-tap toggle: another double-tap types it.
    case doubleTap(key: String)
    /// The hands-free shortcut (or the menu): pressing it again types it.
    /// Nil when no shortcut is set.
    case handsFree(shortcut: String?)
    /// Started without holding anything (a deep link, the menu) in push to
    /// talk: pressing the dictation key types it.
    case press(key: String)
    /// Command Mode while its shortcut is held: letting go applies the edit.
    case commandHold
    /// Command Mode after a quick press: pressing the shortcut again applies it.
    case commandPress(shortcut: String?)

    /// The recording carries on after the key is let go.
    var isHandsFree: Bool {
        switch self {
        case .hold, .commandHold: return false
        default: return true
        }
    }

    /// Whether this is a Command Mode hint (“to apply”, not “to type”).
    var isCommandMode: Bool {
        switch self {
        case .commandHold, .commandPress: return true
        default: return false
        }
    }

    /// What ends this dictation and types it, if there is a key to name.
    var instruction: String? {
        switch self {
        case .hold(let key): return "Let go of \(key) to type"
        case .doubleTap(let key): return "Double-tap \(key) to type"
        case .handsFree(let shortcut?), .press(let shortcut): return "Press \(shortcut) to type"
        case .handsFree(nil): return nil
        case .commandHold: return "Let go to apply"
        case .commandPress(let shortcut?): return "Press \(shortcut) to apply"
        case .commandPress(nil): return nil
        }
    }

    /// The hint for a dictation, from how it actually started.
    ///
    /// - Parameters:
    ///   - commandMode: For a Command Mode session, whether its shortcut is
    ///     still held and the shortcut's keys; nil for a dictation.
    ///   - trigger: What started a dictation that isn't hands-free.
    static func resolve(
        commandMode: (isKeyHeld: Bool, shortcut: String?)?,
        isHandsFreeSession: Bool, handsFreeShortcut: String?,
        trigger: DictationTrigger, mode: ActivationMode, dictationKey: String
    ) -> OverlayStopHint {
        if let commandMode {
            return commandMode.isKeyHeld ? .commandHold : .commandPress(shortcut: commandMode.shortcut)
        }
        if isHandsFreeSession { return .handsFree(shortcut: handsFreeShortcut) }
        // The mouse button works like the key, so it is named instead.
        let key = trigger == .mouseButton ? "the mouse button" : dictationKey
        switch (mode, trigger) {
        case (.pushToTalk, .other): return .press(key: dictationKey)
        case (.pushToTalk, _): return .hold(key: key)
        case (.doubleTapToggle, _): return .doubleTap(key: key)
        }
    }
}

/// What started a dictation, so the overlay names the right way to end it.
enum DictationTrigger: Equatable, Sendable {
    /// The dictation key.
    case dictationKey
    /// The mouse button set to work like the dictation key.
    case mouseButton
    /// Anything else: a deep link, the menu, a test dictation.
    case other
}

extension CalmKeyCaps {
    /// A shortcut as one line of text, the way menus write it: modifier
    /// symbols run together before the key (“⌃⌥V”, “Right ⌥”).
    static func compactText(for combo: HotKeyCombo) -> String {
        let caps = labels(for: combo)
        guard let key = caps.last else { return "" }
        return caps.dropLast().joined() + key
    }
}

// MARK: - Overlay Notice

/// What a failure message is: a real error (amber, warning icon), the
/// text landing on the clipboard instead of in a field (copy icon, neutral),
/// or something VocaMac learned from the user's edits (with Undo).
enum OverlayNotice: Equatable {
    case error(String)
    case copied(String)
    case learned(String)

    static func from(message: String) -> OverlayNotice {
        if message == TextInjector.accessibilityOffMessage {
            return .copied("Copied — press ⌘V to paste")
        }
        return .error(message)
    }

    var text: String {
        switch self {
        case .error(let text), .copied(let text), .learned(let text): return text
        }
    }
}

// MARK: - Live Transcript

/// Splits live words into the part recognition has settled on and the last
/// words it may still change, so the unsettled ones can be drawn at 50%.
enum OverlayLiveTranscript {
    /// Length (in characters) of the words `current` shares with `previous`,
    /// ending on a word boundary. Words after it are still unconfirmed.
    static func confirmedLength(previous: String, current: String) -> Int {
        guard !previous.isEmpty, !current.isEmpty else { return 0 }
        var length = 0
        var lastBoundary = 0
        for (old, new) in zip(previous, current) {
            guard old == new else { break }
            length += 1
            if new.isWhitespace { lastBoundary = length }
        }
        // The whole of the earlier text is still there and the next character
        // starts a new word (or there is none): that last word is settled too.
        if length == previous.count {
            let rest = current.dropFirst(length)
            if rest.isEmpty || rest.first?.isWhitespace == true { return length }
        }
        return lastBoundary
    }
}

// MARK: - CursorOverlayManager

@MainActor
final class CursorOverlayManager {

    // MARK: - Properties

    /// The floating panel that hosts the overlay.
    private var overlayPanel: NSPanel?

    /// Hosting view for the SwiftUI overlay content.
    private var hostingView: OverlayHostingView?

    /// The SwiftUI view model driving the overlay.
    private let viewModel = MicIndicatorViewModel()

    /// Timer to follow the caret or active display when needed.
    private var repositionTimer: Timer?
    private let positionQueue = DispatchQueue(label: "com.vocamac.caret", qos: .userInitiated)
    private var isPositionQueryRunning = false
    private var positionGeneration = UUID()

    /// Timer for the recording duration and the limit countdown.
    private var elapsedTimer: Timer?
    private var recordingStartedAt: Date?

    /// Dismisses a failure message; replaced by any later show or failure.
    private var failureDismissal: DispatchWorkItem?
    /// A "Learned" notice that arrived while a dictation was under way,
    /// shown once the overlay is free.
    private var pendingLearned: (message: String, undo: @MainActor () -> Void)?
    /// From the start of a dictation (or Command Mode session) to its
    /// `hide()` or failure, whatever the overlay style: with the overlay Off
    /// nothing is on screen, but a "Learned" notice must still wait.
    private var isDictationUnderway = false

    /// Pointer-move monitors, installed while the overlay takes clicks, so
    /// the panel only stops ignoring the mouse while the pointer is over
    /// the visible card.
    private var mouseMonitors: [Any] = []

    /// Maximum recording length, so the overlay can count down its last seconds.
    /// Nil shows no countdown.
    var recordingLimit: TimeInterval? {
        didSet { viewModel.recordingLimit = recordingLimit }
    }

    private var isShowingRecordingSession: Bool {
        viewModel.isActive && viewModel.phase != .failure && viewModel.phase != .idle
    }

    // MARK: - Public API

    /// Shows the recording overlay using the requested style and position.
    func show(style: OverlayStyle, position: OverlayPosition) {
        guard style != .off else {
            hide()
            return
        }

        isDictationUnderway = true
        parkLearnedNotice()
        cancelFailureDismissal()
        positionGeneration = UUID()
        viewModel.style = style
        viewModel.position = position
        // Capture has not begun yet — `transitionToRecording()` says when it has.
        viewModel.phase = .connecting
        viewModel.audioLevel = 0
        viewModel.elapsedSeconds = 0
        viewModel.setTranscript("")
        viewModel.failureMessage = ""
        viewModel.learnedUndo = nil
        viewModel.commandSession = nil
        viewModel.liveWordsAvailable = false
        viewModel.isLoadingSpeechModel = false
        viewModel.isCleaningUp = false
        viewModel.stopHint = nil
        viewModel.isPointerInside = false
        viewModel.isActive = true
        recordingStartedAt = nil

        let panel = preparedPanel()
        updateMouseHandling(panel)
        updatePanelLayout(panel)
        panel.orderFrontRegardless()
        startTimers()

        VocaLogger.debug(.cursorOverlay, "Overlay shown (style=\(style.rawValue), position=\(position.rawValue))")
    }

    /// The input route is live and the microphone is actually capturing.
    func transitionToRecording() {
        isDictationUnderway = true
        // With the overlay Off, `show` isn't called: a "Learned" notice still
        // up waits for this dictation to finish.
        if viewModel.phase == .failure, viewModel.learnedUndo != nil {
            parkLearnedNotice()
            hideNow()
        }
        guard viewModel.isActive, viewModel.phase == .connecting else { return }
        viewModel.phase = .recording
        viewModel.audioLevel = 0
        viewModel.elapsedSeconds = 0
        viewModel.setTranscript("")
        recordingStartedAt = Date()
        refreshPanelSize()
        VocaLogger.debug(.cursorOverlay, "Overlay transitioned to recording")
    }

    /// Transitions the overlay from recording to batch transcription.
    func transitionToProcessing() {
        isDictationUnderway = true
        guard isShowingRecordingSession, let overlayPanel else { return }
        viewModel.phase = .processing
        updateMouseHandling(overlayPanel)
        refreshPanelSize()
        VocaLogger.debug(.cursorOverlay, "Overlay transitioned to processing")
    }

    /// The transcript is with the cleanup model. Only a dictation already
    /// processing moves on; a Settings preview of cleanup changes nothing.
    func transitionToCleaningUp() {
        guard viewModel.isActive, viewModel.phase == .processing, !viewModel.isCleaningUp else { return }
        viewModel.isCleaningUp = true
        VocaLogger.debug(.cursorOverlay, "Overlay transitioned to cleaning up")
    }

    func setControlActions(stop: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
        viewModel.onStop = stop
        viewModel.onCancel = cancel
    }

    func setEscapeHintVisible(_ visible: Bool) {
        if viewModel.showsEscapeHint != visible { viewModel.showsEscapeHint = visible }
    }

    func setStopHint(_ hint: OverlayStopHint?) {
        if viewModel.stopHint != hint { viewModel.stopHint = hint }
    }

    /// Shows a short failure message for a few seconds, then hides. It appears
    /// whatever the overlay style, since the user is looking at the target app,
    /// not the menu bar.
    func showFailure(message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // A failure ends the dictation. A "Learned" notice it covers comes
        // back after it, with its Undo.
        isDictationUnderway = false
        parkLearnedNotice()
        viewModel.learnedUndo = nil
        presentNotice(trimmed, duration: OverlayInteraction.failureDisplayDuration(for: trimmed))
        VocaLogger.debug(.cursorOverlay, "Overlay showing failure")
    }

    /// Say what VocaMac learned from the user's edits, with an Undo button,
    /// for a few seconds. While a dictation is under way, or a failure is
    /// up, it waits until the overlay is free; a newer one replaces it.
    func showLearned(message: String, undo: @escaping @MainActor () -> Void) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let isShowingFailure = viewModel.isActive && viewModel.phase == .failure && viewModel.learnedUndo == nil
        guard !isDictationUnderway, !isShowingFailure else {
            pendingLearned = (trimmed, undo)
            return
        }
        viewModel.learnedUndo = undo
        viewModel.onNoticeFinished = { [weak self] in self?.hideNow() }
        presentNotice(trimmed, duration: OverlayLayout.learnedDisplayDuration)
        VocaLogger.debug(.cursorOverlay, "Overlay showing what was learned")
    }

    /// Show a one-line notice in the failure pill for `duration`, then hide.
    private func presentNotice(_ trimmed: String, duration: TimeInterval) {
        let panel = preparedPanel()
        let wasVisible = panel.isVisible && viewModel.isActive
        stopTimers()
        recordingStartedAt = nil
        positionGeneration = UUID()

        viewModel.failureMessage = trimmed
        viewModel.phase = .failure
        viewModel.audioLevel = 0
        viewModel.commandSession = nil
        viewModel.isPointerInside = false
        viewModel.isActive = true
        updateMouseHandling(panel)

        let size = overlaySize
        if wasVisible {
            // Keep the message where the user was already looking.
            let frames = NSScreen.screens.map(\.visibleFrame)
            let card = OverlayLayout.cardFrame(inPanel: panel.frame)
            let cardOrigin = OverlayPlacement.clampedOrigin(
                CGPoint(x: card.minX, y: card.maxY - viewModel.contentSize.height),
                panelSize: viewModel.contentSize, visibleFrames: frames
            )
            panel.setFrame(NSRect(origin: OverlayLayout.panelOrigin(forCardOrigin: cardOrigin), size: size), display: true)
            hostingView?.frame = NSRect(origin: .zero, size: size)
        } else {
            panel.setContentSize(size)
            hostingView?.frame = NSRect(origin: .zero, size: size)
            positionPanel(panel, size: size)
        }
        panel.orderFrontRegardless()

        cancelFailureDismissal()
        let dismissal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.viewModel.phase == .failure else { return }
                self.failureDismissal = nil
                self.hideNow()
            }
        }
        failureDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: dismissal)
    }

    /// Hides the recording overlay and resets its transient state. A failure
    /// message stays up until its own dismissal, so an error path that hides
    /// the recording overlay after reporting the failure doesn't erase it.
    func hide() {
        isDictationUnderway = false
        if viewModel.phase == .failure, failureDismissal != nil {
            return
        }
        hideNow()
    }

    /// A "Learned" notice is on screen with its Undo.
    var isShowingLearnedNotice: Bool { viewModel.phase == .failure && viewModel.learnedUndo != nil }

    /// A "Learned" notice is waiting for the overlay to be free.
    var hasPendingLearnedNotice: Bool { pendingLearned != nil }

    /// Keep a "Learned" notice that is on screen for later, when something
    /// else is about to take the overlay.
    private func parkLearnedNotice() {
        guard viewModel.phase == .failure, let undo = viewModel.learnedUndo else { return }
        pendingLearned = (viewModel.failureMessage, undo)
    }

    private func hideNow() {
        cancelFailureDismissal()
        positionGeneration = UUID()
        stopTimers()
        recordingStartedAt = nil

        viewModel.isActive = false
        viewModel.phase = .idle
        viewModel.learnedUndo = nil
        viewModel.audioLevel = 0
        viewModel.waveformTick = 0
        viewModel.elapsedSeconds = 0
        viewModel.isCleaningUp = false
        viewModel.isPointerInside = false
        if let overlayPanel { updateMouseHandling(overlayPanel) }

        // The panel is kept and reused: rebuilding an NSPanel and hosting view
        // on the hotkey path costs main-thread time on every dictation.
        overlayPanel?.orderOut(nil)
        VocaLogger.debug(.cursorOverlay, "Overlay hidden")

        if let pending = pendingLearned {
            pendingLearned = nil
            // After the caller's own work on this turn (a failure shown
            // straight after hiding takes the overlay, and this waits again).
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.showLearned(message: pending.message, undo: pending.undo) }
            }
        }
    }

    /// Updates the current audio level used to animate the waveform.
    func updateAudioLevel(_ level: Float) {
        guard viewModel.isActive, viewModel.phase == .recording else { return }
        // Mild pre-gain so quiet speech still drives a lively waveform.
        let target = min(max(level * 2.6, 0), 1)
        let smoothing: Float = target > viewModel.audioLevel ? 0.78 : 0.28
        viewModel.audioLevel += (target - viewModel.audioLevel) * smoothing
        viewModel.waveformTick &+= 1
    }

    func updateTranscript(_ text: String) {
        guard isShowingRecordingSession, viewModel.style == .live else { return }
        viewModel.setTranscript(text.trimmingCharacters(in: .whitespacesAndNewlines))
        refreshPanelSize()
    }

    func setCommandSession(_ session: CommandModeSession?) {
        viewModel.commandSession = session
        refreshPanelSize()
    }

    func setLoadingSpeechModel(_ loading: Bool) {
        viewModel.isLoadingSpeechModel = loading
    }

    func setLiveWordsAvailable(_ available: Bool) {
        viewModel.liveWordsAvailable = available
        refreshPanelSize()
    }

    // MARK: - Layout

    private var overlaySize: CGSize {
        OverlayLayout.panelSize(forContent: viewModel.contentSize)
    }

    /// Returns the one overlay panel, creating it on first use.
    private func preparedPanel() -> NSPanel {
        if let overlayPanel { return overlayPanel }

        let size = overlaySize
        let hosting = OverlayHostingView(rootView: HandyOverlayView(viewModel: viewModel))
        hosting.frame = NSRect(origin: .zero, size: size)
        // The pill is always dark glass; the appearance only matters to
        // anything else the panel might draw.
        hosting.appearance = nil
        hosting.onPointerInside = { [weak self] _ in
            guard let self, let panel = self.overlayPanel else { return }
            self.updateMouseHandling(panel)
        }
        viewModel.onCardSizeChange = { [weak self] in
            guard let self, let panel = self.overlayPanel else { return }
            self.updateMouseHandling(panel)
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The card draws its own soft shadow inside the panel's margin.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil
        // Clicks pass through until a dictation is under way; then only the
        // overlay's own buttons take them. A borderless non-activating panel
        // never becomes key, so the target app keeps focus either way.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting

        overlayPanel = panel
        hostingView = hosting
        return panel
    }

    /// Clicks pass through everywhere except the visible card, and only
    /// while a dictation is under way; hover (Stop and Cancel) follows the
    /// same rectangle. The transparent slot and shadow room never take the
    /// pointer from the app underneath.
    private func updateMouseHandling(_ panel: NSPanel) {
        // A "Learned" notice takes clicks too: its Undo button.
        let acceptsClicks = viewModel.isActive
            && (OverlayInteraction.acceptsClicks(in: viewModel.phase) || viewModel.learnedUndo != nil)
        let card = visibleCardFrame(of: panel)
        let isOverCard = acceptsClicks && card.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == isOverCard { panel.ignoresMouseEvents = !isOverCard }
        if viewModel.isPointerInside != isOverCard { viewModel.isPointerInside = isOverCard }
        hostingView?.cardRectInWindow = card.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        setMouseMonitoring(acceptsClicks)
    }

    /// The visible card in screen coordinates.
    private func visibleCardFrame(of panel: NSPanel) -> CGRect {
        OverlayLayout.visibleCardFrame(inPanel: panel.frame, cardSize: viewModel.cardSize, position: viewModel.position)
    }

    /// A panel that ignores the mouse gets no events, so pointer moves over
    /// other apps say when the pointer reaches the card.
    private func setMouseMonitoring(_ isOn: Bool) {
        guard isOn == mouseMonitors.isEmpty else { return }
        guard isOn else {
            mouseMonitors.forEach(NSEvent.removeMonitor)
            mouseMonitors.removeAll()
            return
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        // Both monitors run on the main thread.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    private func pointerMoved() {
        guard let overlayPanel, overlayPanel.isVisible else { return }
        updateMouseHandling(overlayPanel)
    }

    /// While the pointer is over the card the user is reaching for a
    /// button, so the panel holds still instead of following the caret or
    /// the mouse away from it.
    private func isPointerOver(_ panel: NSPanel) -> Bool {
        panel.isVisible && visibleCardFrame(of: panel).contains(NSEvent.mouseLocation)
    }

    private func cancelFailureDismissal() {
        failureDismissal?.cancel()
        failureDismissal = nil
    }

    private func updatePanelLayout(_ panel: NSPanel) {
        let size = overlaySize
        panel.setContentSize(size)
        hostingView?.frame = NSRect(origin: .zero, size: size)
        positionPanel(panel, size: size)
    }

    /// The live panel grows with the words. Resize in place, keeping the
    /// edge it hangs from: the bottom at the Bottom position, the top
    /// otherwise, so the words grow away from the menu bar or the caret.
    private func refreshPanelSize() {
        guard viewModel.isActive, let panel = overlayPanel, panel.isVisible else { return }
        let size = overlaySize
        guard size != panel.frame.size else { return }
        let old = panel.frame
        let y = viewModel.position == .bottom ? old.minY : old.maxY - size.height
        let x = viewModel.position == .nearCursor ? old.minX : old.midX - size.width / 2
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        hostingView?.frame = NSRect(origin: .zero, size: size)
        updateMouseHandling(panel)
    }

    private func positionPanel(_ panel: NSPanel, size: CGSize) {
        switch viewModel.position {
        case .nearCursor:
            requestCaretPosition(panel)
        case .top, .bottom:
            guard let screen = activeScreen else {
                requestCaretPosition(panel)
                return
            }
            let cardOrigin = OverlayPlacement.edgeOrigin(
                for: viewModel.position, cardSize: viewModel.contentSize, visibleFrame: screen.visibleFrame
            )
            panel.setFrameOrigin(OverlayLayout.panelOrigin(forCardOrigin: cardOrigin))
        }
    }

    private var activeScreen: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func startTimers() {
        repositionTimer?.invalidate()
        repositionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isShowingRecordingSession, let panel = self.overlayPanel,
                      !self.isPointerOver(panel) else { return }
                self.positionPanel(panel, size: self.overlaySize)
                // The card may have moved under a pointer that stayed still.
                self.updateMouseHandling(panel)
            }
        }

        elapsedTimer?.invalidate()
        // Sub-second ticks keep the countdown aligned with the recording start;
        // the published value only changes once per second.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.phase == .recording,
                      let start = self.recordingStartedAt else { return }
                let elapsed = Int(Date().timeIntervalSince(start))
                if self.viewModel.elapsedSeconds != elapsed {
                    self.viewModel.elapsedSeconds = elapsed
                }
            }
        }
    }

    private func stopTimers() {
        repositionTimer?.invalidate()
        repositionTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// At most one query runs at once. Hide/show and focus changes invalidate its result.
    private func requestCaretPosition(_ panel: NSPanel) {
        guard !isPositionQueryRunning else { return }
        let cardSize = viewModel.contentSize
        let frames = NSScreen.screens.map(\.visibleFrame)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let mouse = NSEvent.mouseLocation
        let fallback = CGPoint(x: mouse.x + 16, y: mouse.y - 40)
        if !panel.isVisible {
            let cardOrigin = OverlayPlacement.clampedOrigin(fallback, panelSize: cardSize, visibleFrames: frames)
            panel.setFrameOrigin(OverlayLayout.panelOrigin(forCardOrigin: cardOrigin))
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let generation = positionGeneration
        isPositionQueryRunning = true
        positionQueue.async { [weak self] in
            let interval = PerformanceTrace.begin("CaretAccessibilityQuery")
            let cardOrigin = CaretPositionQuery.position(
                panelSize: cardSize, visibleScreenFrames: frames,
                primaryScreenTop: top, mouse: fallback, applicationPID: pid
            )
            PerformanceTrace.end(interval)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPositionQueryRunning = false
                guard self.positionGeneration == generation,
                      self.overlayPanel === panel,
                      self.viewModel.position == .nearCursor,
                      !self.isPointerOver(panel),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let origin = OverlayLayout.panelOrigin(forCardOrigin: cardOrigin)
                if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
            }
        }
    }

}

// MARK: - IndicatorPhase

enum IndicatorPhase {
    case idle
    /// The audio engine is negotiating its input route. Bluetooth headsets take
    /// seconds to switch to their microphone, and nothing is captured until they
    /// do — showing "recording" through that window loses the user's first words.
    case connecting
    case recording
    case processing
    /// A dictation failed; the overlay shows a short message, then hides.
    case failure
}

// MARK: - MicIndicatorViewModel

@MainActor
final class MicIndicatorViewModel: ObservableObject {
    @Published var isActive: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var phase: IndicatorPhase = .idle
    @Published var style: OverlayStyle = .minimal
    @Published var position: OverlayPosition = .nearCursor
    @Published var waveformTick: Int = 0
    @Published var elapsedSeconds: Int = 0
    /// Live words. Set through `setTranscript(_:)` so the settled part is tracked.
    @Published private(set) var transcript: String = ""
    /// How much of `transcript` recognition has settled on; the rest is drawn at 50%.
    @Published private(set) var confirmedTranscriptLength = 0
    /// Set while the session edits selected text (Command Mode).
    @Published var commandSession: CommandModeSession?
    @Published var liveWordsAvailable = false
    /// The speech model is still loading while the microphone records.
    @Published var isLoadingSpeechModel = false
    @Published var failureMessage: String = ""
    /// Takes back what a "Learned" notice reports; nil for other notices.
    @Published var learnedUndo: (@MainActor () -> Void)?
    /// Hides the overlay once a notice's button has done its work.
    var onNoticeFinished: (@MainActor () -> Void)?
    @Published var recordingLimit: TimeInterval?
    /// Processing has moved from transcription to Smart Cleanup.
    @Published var isCleaningUp = false
    /// Escape cancels (Settings → Dictation), so the overlay can say so.
    @Published var showsEscapeHint = true
    /// How this dictation ends, for the hint and the Hands-free label.
    @Published var stopHint: OverlayStopHint?
    /// The pointer is over the card; its Stop and Cancel buttons show.
    @Published var isPointerInside = false
    /// The visible card's measured size (a pill is narrower than its slot).
    /// Not published: only the overlay manager's pointer handling reads it.
    var cardSize: CGSize = .zero {
        didSet { if cardSize != oldValue { onCardSizeChange?() } }
    }
    /// Tells the manager the card changed size, to re-check the pointer.
    var onCardSizeChange: (@MainActor () -> Void)?
    /// The overlay's Stop and Cancel buttons. Set once by AppState.
    var onStop: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    var isCommandMode: Bool { commandSession != nil }

    /// Seconds left before the recording limit stops capture, during its last ten seconds.
    var countdownSeconds: Int? {
        guard phase == .recording else { return nil }
        return RecordingCountdown.secondsRemaining(elapsed: TimeInterval(elapsedSeconds), limit: recordingLimit)
    }

    var notice: OverlayNotice {
        learnedUndo == nil ? OverlayNotice.from(message: failureMessage) : .learned(failureMessage)
    }

    /// The Undo button on a "Learned" notice.
    func undoLearned() {
        let undo = learnedUndo
        learnedUndo = nil
        undo?()
        onNoticeFinished?()
    }

    /// Replace the live words, keeping what the previous update already had
    /// as settled.
    func setTranscript(_ text: String) {
        let confirmed = OverlayLiveTranscript.confirmedLength(previous: transcript, current: text)
        if confirmedTranscriptLength != confirmed { confirmedTranscriptLength = confirmed }
        if transcript != text { transcript = text }
    }

    // MARK: Live panel content

    /// The words the live panel shows, and whether they are a placeholder.
    var liveText: (text: String, isPlaceholder: Bool) {
        if let session = commandSession {
            if session.phase == .rewriting, let written = session.previewTail {
                return (written, false)
            }
            if session.phase == .rewriting, let instruction = session.instruction, !instruction.isEmpty {
                return ("“\(instruction)”", false)
            }
            if !transcript.isEmpty { return (transcript, false) }
            switch session.kind {
            case .edit: return ("“\(session.selectionPreview)”", true)
            case .compose: return ("Say what to write", true)
            case .answer: return ("“\(session.selectionPreview)”", true)
            }
        }
        if !transcript.isEmpty { return (transcript, false) }
        return (
            liveWordsAvailable ? "Words will appear here as you speak" : "Your words will appear when you stop",
            true
        )
    }

    /// The live panel's Command Mode header: what is being edited, and where.
    var liveHeader: String? {
        guard let session = commandSession else { return nil }
        let place = session.appName.flatMap { $0.isEmpty ? nil : " in \($0)" } ?? ""
        let count = session.characterCount == 1 ? "1 character" : "\(session.characterCount) characters"
        switch session.kind {
        case .edit: return "Editing \(count)\(place)"
        case .compose: return "New text at the cursor\(place)"
        case .answer: return "Can’t be edited, so you’ll get an answer about \(count)\(place)"
        }
    }

    /// Lines the live words take, 1…`OverlayLayout.liveMaxLines`.
    var liveLineCount: Int {
        let lines = OverlayTextMeasure.lineCount(
            liveText.text, font: OverlayTextMeasure.liveFont,
            width: OverlayLayout.liveTextWidth - 4, lineHeight: OverlayLayout.liveLineHeight
        )
        return min(lines, OverlayLayout.liveMaxLines)
    }

    /// The failure message's wrap width and line count.
    var failureTextLayout: (width: CGFloat, lines: Int) {
        let text = notice.text
        let available = learnedUndo == nil
            ? OverlayLayout.failureTextWidth : OverlayLayout.failureTextWidth - OverlayLayout.learnedUndoWidth
        let natural = OverlayTextMeasure.width(text, font: OverlayTextMeasure.pillFont)
        guard natural > available else { return (natural, 1) }
        let lines = OverlayTextMeasure.lineCount(
            text, font: OverlayTextMeasure.pillFont,
            width: available - 4, lineHeight: OverlayLayout.failureLineHeight
        )
        return (available, min(lines, OverlayLayout.failureMaxLines))
    }

    /// The card slot for the current state.
    var contentSize: CGSize {
        if phase == .failure {
            return CGSize(
                width: OverlayLayout.failureMaxWidth,
                height: OverlayLayout.failureHeight(lines: failureTextLayout.lines)
            )
        }
        switch style {
        case .off, .minimal:
            return OverlayLayout.contentSize(for: .minimal)
        case .live:
            return CGSize(
                width: OverlayLayout.liveWidth,
                height: OverlayLayout.liveHeight(lines: liveLineCount, hasHeader: liveHeader != nil)
            )
        }
    }
}

// MARK: - Waveform Metrics

/// Converts the single audio level currently exposed by AudioEngine into the
/// eight bars of the overlay's waveform (the design's 6 11 16 9 14 7 12 5).
enum OverlayWaveformMetrics {
    static let barProfile: [CGFloat] = [6, 11, 16, 9, 14, 7, 12, 5].map { $0 / 16 }

    /// Amplifies quiet speech so the bars react clearly without needing to shout.
    static let inputGain: CGFloat = 3.4

    static func heights(for level: Float, tick: Int = 0, maximumHeight: CGFloat = 16) -> [CGFloat] {
        let boosted = min(1, max(0, CGFloat(level) * inputGain))
        // Lower exponent = more height from mid/quiet levels.
        let shaped = pow(boosted, 0.42)
        return barProfile.enumerated().map { index, profile in
            let phase = Double(tick) * 0.95 + Double(index) * 1.31
            let movement = CGFloat(0.78 + sin(phase) * 0.22)
            return min(maximumHeight, max(3, 3 + shaped * profile * movement * (maximumHeight - 3)))
        }
    }
}

// MARK: - Overlay Palette

/// The overlay is dark glass in both appearances, so it reads over any app.
/// Mint marks dictation, violet Command Mode, amber a problem.
enum OverlayPalette {
    static let glass = Color(.sRGB, red: 20 / 255, green: 28 / 255, blue: 25 / 255, opacity: 0.94)
    static let edge = Color.white.opacity(0.09)
    static let shadow = Color.black.opacity(0.35)
    static let text = Color(.sRGB, red: 237 / 255, green: 242 / 255, blue: 238 / 255, opacity: 1)
    static let secondaryText = text.opacity(0.6)
    static let pendingText = text.opacity(0.5)
    static let divider = Color.white.opacity(0.1)
    static let spinnerTrack = Color.white.opacity(0.18)
    static let buttonFill = Color.white.opacity(0.12)
    static let buttonHover = Color.white.opacity(0.2)
    static let mint = Color(.sRGB, red: 0x55 / 255, green: 0xC2 / 255, blue: 0xA0 / 255, opacity: 1)
    static let violet = Color(.sRGB, red: 0xBB / 255, green: 0xA4 / 255, blue: 0xFF / 255, opacity: 1)
    static let amber = Color(.sRGB, red: 0xFF / 255, green: 0xB4 / 255, blue: 0x59 / 255, opacity: 1)
    /// Bars while the microphone route comes up: not live yet, and not
    /// pretending to be.
    static let connecting = Color.white.opacity(0.35)
}

// MARK: - HandyOverlayView

/// The overlay's SwiftUI content: the dark-glass card (pill or live panel)
/// inside the panel's transparent shadow margin.
struct HandyOverlayView: View {
    @ObservedObject var viewModel: MicIndicatorViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasEntered = false

    var body: some View {
        let slot = viewModel.contentSize
        let insets = OverlayLayout.shadowInsets

        card
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewModel.cardSize = $0 }
            .frame(width: slot.width, height: slot.height, alignment: cardAlignment)
            .padding(EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right))
            .opacity(viewModel.isActive && hasEntered ? 1 : 0)
            .offset(y: hasEntered || reduceMotion ? 0 : slideInOffset)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hasEntered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: viewModel.isPointerInside)
            .onAppear { playEntranceIfNeeded() }
            .onChange(of: viewModel.isActive) { _, active in
                if active {
                    playEntranceIfNeeded()
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { hasEntered = false }
                }
            }
            .onChange(of: viewModel.position) { _, _ in
                // Re-run entrance when the anchor edge changes between shows.
                if viewModel.isActive {
                    hasEntered = false
                    playEntranceIfNeeded()
                }
            }
    }

    /// Next to the caret the card starts at the caret's side; at the top and
    /// bottom of the screen it is centred.
    private var cardAlignment: Alignment {
        viewModel.position == .nearCursor ? .topLeading : .top
    }

    private var slideInOffset: CGFloat {
        viewModel.position == .top ? -6 : 6
    }

    private func playEntranceIfNeeded() {
        guard viewModel.isActive else { return }
        hasEntered = false
        // Defer one turn so the off-screen offset is committed before animating in.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                hasEntered = true
            }
        }
    }

    @ViewBuilder
    private var card: some View {
        if viewModel.phase == .failure {
            OverlayFailurePill(viewModel: viewModel)
        } else if viewModel.style == .live {
            OverlayLivePanel(viewModel: viewModel)
        } else {
            OverlayPill(viewModel: viewModel)
        }
    }
}

// MARK: - Glass

private struct OverlayGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(shape.fill(OverlayPalette.glass))
            .overlay(shape.strokeBorder(OverlayPalette.edge, lineWidth: 1))
            .compositingGroup()
            .shadow(color: OverlayPalette.shadow, radius: 20, y: 16)
    }
}

private extension View {
    func overlayGlass(cornerRadius: CGFloat) -> some View {
        modifier(OverlayGlass(cornerRadius: cornerRadius))
    }
}

// MARK: - Pieces

/// The eight waveform bars: 3 wide, 2 apart, 18 tall.
private struct OverlayWaveform: View {
    @ObservedObject var viewModel: MicIndicatorViewModel
    let color: Color

    var body: some View {
        let heights = OverlayWaveformMetrics.heights(for: viewModel.audioLevel, tick: viewModel.waveformTick)
        HStack(spacing: 2) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color)
                    .frame(width: 3, height: height)
            }
        }
        .frame(height: 18)
        .animation(
            .interactiveSpring(response: 0.18, dampingFraction: 0.68, blendDuration: 0.06),
            value: viewModel.waveformTick
        )
        .accessibilityHidden(true)
    }
}

/// A 15-point spinner on the dark glass: faint track, a quarter arc.
private struct OverlaySpinner: View {
    var color: Color = OverlayPalette.text

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        let width: CGFloat = 2.4 * 15 / 20
        ZStack {
            Circle().stroke(OverlayPalette.spinnerTrack, lineWidth: width)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .padding(15 * 3 / 20)
        .frame(width: 15, height: 15)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
        }
        .accessibilityHidden(true)
    }
}

/// Stop and Cancel, shown while the pointer is over the card. Stop ends the
/// recording and types it; Cancel throws the dictation away, as Escape does.
private struct OverlayControls: View {
    @ObservedObject var viewModel: MicIndicatorViewModel

    var body: some View {
        HStack(spacing: 6) {
            control(.cancel)
            if viewModel.phase == .recording {
                control(.stop)
            }
        }
    }

    enum Control { case stop, cancel }

    private func control(_ control: Control) -> some View {
        let isStop = control == .stop
        let label = OverlayCopy.controlLabel(isStop: isStop, isCommandMode: viewModel.isCommandMode)
        let help = !isStop && viewModel.showsEscapeHint ? "\(label) (Esc)" : label
        return Button {
            if isStop { viewModel.onStop?() } else { viewModel.onCancel?() }
        } label: {
            Group {
                if isStop {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(viewModel.isCommandMode ? OverlayPalette.violet : OverlayPalette.mint)
                        .frame(width: 8, height: 8)
                } else {
                    CalmIcon(.close, size: 12, weight: 2.4)
                        .foregroundStyle(OverlayPalette.text)
                }
            }
            .frame(width: 22, height: 22)
            .background(Circle().fill(OverlayPalette.buttonFill))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }
}

/// Text shared by the pill and the live panel.
enum OverlayCopy {
    static func controlLabel(isStop: Bool, isCommandMode: Bool) -> String {
        switch (isStop, isCommandMode) {
        case (true, false): return "Stop recording"
        case (true, true): return "Finish instruction"
        case (false, false): return "Cancel dictation"
        case (false, true): return "Cancel edit"
        }
    }

    /// "1:05", for the timer.
    static func clock(_ seconds: Int) -> String {
        "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// "0:10 left", in the last seconds before the recording limit.
    static func countdown(_ seconds: Int) -> String {
        "\(clock(seconds)) left"
    }

    /// The pill's Command Mode word.
    static func commandWord(_ kind: CommandModeSession.Kind) -> String {
        switch kind {
        case .edit: return "Edit"
        case .compose: return "Write"
        case .answer: return "Ask"
        }
    }

    /// What the pill says once the recording has ended.
    @MainActor
    static func workingTitle(_ viewModel: MicIndicatorViewModel) -> String {
        if viewModel.isLoadingSpeechModel { return "Loading model…" }
        if let session = viewModel.commandSession {
            switch session.kind {
            case .edit: return "Editing…"
            case .compose: return "Writing…"
            case .answer: return "Answering…"
            }
        }
        return viewModel.isCleaningUp ? "Cleaning up…" : "Typing…"
    }

    /// The live panel's footer once the recording has ended: the stage, and
    /// for Command Mode which model is at work.
    @MainActor
    static func workingDetail(_ viewModel: MicIndicatorViewModel) -> String {
        if viewModel.isLoadingSpeechModel { return "Loading speech model…" }
        guard let session = viewModel.commandSession else {
            return viewModel.isCleaningUp ? "Cleaning up…" : "Typing…"
        }
        guard session.phase == .rewriting else { return "Transcribing instruction…" }
        switch session.kind {
        case .edit: return "Rewriting with \(session.engineName)…"
        case .compose: return "Writing with \(session.engineName)…"
        case .answer: return "Answering with \(session.engineName)…"
        }
    }

    /// The live panel's footer while listening: how to finish, and Esc.
    @MainActor
    static func listeningHint(_ viewModel: MicIndicatorViewModel) -> String {
        var parts: [String] = []
        if viewModel.phase == .connecting {
            parts.append(viewModel.isLoadingSpeechModel ? "Loading speech model…" : "Waiting for microphone…")
        } else if viewModel.isLoadingSpeechModel {
            parts.append("Speak now — loading speech model…")
        } else if viewModel.isCommandMode {
            // Held: letting go applies. After a quick press: press again.
            if let hint = viewModel.stopHint, hint.isCommandMode {
                if let instruction = hint.instruction { parts.append(instruction) }
            } else {
                parts.append("Let go to apply")
            }
        } else if let instruction = viewModel.stopHint?.instruction {
            parts.append(instruction)
        }
        if viewModel.showsEscapeHint { parts.append("Esc to cancel") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pill

/// The minimal style: a 40-point dark-glass pill.
private struct OverlayPill: View {
    @ObservedObject var viewModel: MicIndicatorViewModel

    private var tint: Color { viewModel.isCommandMode ? OverlayPalette.violet : OverlayPalette.mint }

    var body: some View {
        HStack(spacing: 10) {
            content
            if viewModel.isPointerInside, OverlayInteraction.acceptsClicks(in: viewModel.phase) {
                OverlayControls(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .font(CalmFont.sf(13, weight: 550))
        .foregroundStyle(OverlayPalette.text)
        .lineLimit(1)
        .padding(.leading, 14)
        .padding(.trailing, viewModel.isPointerInside ? 9 : 16)
        .frame(height: OverlayLayout.pillHeight)
        .fixedSize()
        .overlayGlass(cornerRadius: OverlayLayout.pillCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: OverlayCopy.controlLabel(isStop: false, isCommandMode: viewModel.isCommandMode)) {
            viewModel.onCancel?()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .connecting:
            OverlayWaveform(viewModel: viewModel, color: OverlayPalette.connecting)
            Text(viewModel.isLoadingSpeechModel ? "Loading model…" : "Connecting…")
                .foregroundStyle(OverlayPalette.secondaryText)
        case .recording:
            OverlayWaveform(viewModel: viewModel, color: tint)
            if let session = viewModel.commandSession {
                Text(OverlayCopy.commandWord(session.kind)).foregroundStyle(OverlayPalette.violet)
            } else if viewModel.isLoadingSpeechModel {
                Text("Loading model…").foregroundStyle(OverlayPalette.secondaryText)
            } else if viewModel.stopHint?.isHandsFree == true {
                Text("Hands-free")
            }
            if let seconds = viewModel.countdownSeconds {
                Text(OverlayCopy.countdown(seconds))
                    .monospacedDigit()
                    .foregroundStyle(OverlayPalette.amber)
            } else {
                Text(OverlayCopy.clock(viewModel.elapsedSeconds))
                    .monospacedDigit()
                    .foregroundStyle(OverlayPalette.secondaryText)
            }
        case .processing:
            OverlaySpinner(color: viewModel.isCommandMode ? OverlayPalette.violet : OverlayPalette.text)
            Text(OverlayCopy.workingTitle(viewModel))
        case .idle, .failure:
            // Hidden. The panel is kept between dictations, and a spinner
            // left in it spun forever off screen (several % CPU when idle).
            EmptyView()
        }
    }

    private var accessibilityLabel: String {
        switch viewModel.phase {
        case .connecting: return "Waiting for microphone"
        case .recording:
            if let seconds = viewModel.countdownSeconds { return "Recording stops in \(seconds) seconds" }
            if viewModel.isCommandMode { return "Command Mode, listening" }
            return viewModel.stopHint?.isHandsFree == true ? "Recording, hands-free" : "Recording"
        case .processing, .idle: return OverlayCopy.workingTitle(viewModel)
        case .failure: return viewModel.notice.text
        }
    }
}

/// A failure, or text that went to the clipboard instead of a field.
private struct OverlayFailurePill: View {
    @ObservedObject var viewModel: MicIndicatorViewModel

    var body: some View {
        let notice = viewModel.notice
        let layout = viewModel.failureTextLayout
        let isCopied: Bool = {
            if case .copied = notice { return true }
            return false
        }()
        let isLearned: Bool = {
            if case .learned = notice { return true }
            return false
        }()
        HStack(alignment: layout.lines > 1 ? .top : .center, spacing: 10) {
            Group {
                if isLearned {
                    CalmIcon(.check, size: 14, weight: 2).foregroundStyle(OverlayPalette.mint)
                } else if isCopied {
                    CalmIcon(.copy, size: 14, weight: 1.8).foregroundStyle(OverlayPalette.text)
                } else {
                    CalmIcon(.warning, size: 15, weight: 2).foregroundStyle(OverlayPalette.amber)
                }
            }
            .frame(width: 15, height: layout.lines > 1 ? OverlayLayout.failureLineHeight : 15)
            Text(notice.text)
                .font(CalmFont.sf(13, weight: 550))
                .foregroundStyle(isCopied || isLearned ? OverlayPalette.text : OverlayPalette.amber)
                .lineLimit(OverlayLayout.failureMaxLines)
                .lineSpacing(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: layout.width + 2, alignment: .leading)
            if isLearned {
                Button("Undo") { viewModel.undoLearned() }
                    .buttonStyle(.plain)
                    .font(CalmFont.sf(13, weight: 650))
                    .foregroundStyle(OverlayPalette.mint)
                    .accessibilityHint("Takes back what VocaMac just learned")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .padding(.vertical, layout.lines > 1 ? 11.5 : 0)
        .frame(height: OverlayLayout.failureHeight(lines: layout.lines))
        .fixedSize()
        .overlayGlass(cornerRadius: OverlayLayout.pillCornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isLearned ? viewModel.failureMessage
                : isCopied ? "Copied: \(viewModel.failureMessage)" : "Didn’t work: \(viewModel.failureMessage)"
        )
    }
}

// MARK: - Live Panel

/// The live style: 460 wide, the words as they are recognised (the last
/// unconfirmed ones at 50%), growing to four lines and then scrolling.
private struct OverlayLivePanel: View {
    @ObservedObject var viewModel: MicIndicatorViewModel

    private var tint: Color { viewModel.isCommandMode ? OverlayPalette.violet : OverlayPalette.mint }

    var body: some View {
        let lines = viewModel.liveLineCount
        VStack(alignment: .leading, spacing: 10) {
            if let header = viewModel.liveHeader {
                Text(header)
                    .font(.system(size: 12))
                    .foregroundStyle(OverlayPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: OverlayLayout.liveHeaderHeight)
            }
            ScrollView(.vertical) {
                words
                    .font(.system(size: 15))
                    .lineSpacing(4.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .defaultScrollAnchor(.bottom)
            .frame(height: CGFloat(lines) * OverlayLayout.liveLineHeight, alignment: .top)
            .accessibilityLabel(viewModel.isCommandMode ? "Command Mode" : "Live transcript")
            .accessibilityValue(viewModel.liveText.text)

            VStack(spacing: 0) {
                Rectangle().fill(OverlayPalette.divider).frame(height: 1)
                footer
                    .frame(height: 18)
                    .padding(.top, 10)
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .frame(width: OverlayLayout.liveWidth)
        .overlayGlass(cornerRadius: OverlayLayout.liveCornerRadius)
        .accessibilityElement(children: .contain)
    }

    /// The words, with the settled part at full strength and the rest at 50%.
    private var words: Text {
        let live = viewModel.liveText
        guard !live.isPlaceholder else {
            return Text(live.text).foregroundStyle(OverlayPalette.pendingText)
        }
        let isInstruction = viewModel.isCommandMode && viewModel.commandSession?.phase != .rewriting
        let base = isInstruction ? OverlayPalette.violet : OverlayPalette.text
        // Once the recording ends every word is final.
        let settledCount = viewModel.phase == .recording && viewModel.commandSession?.phase != .rewriting
            ? min(viewModel.confirmedTranscriptLength, live.text.count)
            : live.text.count
        let pendingColor = isInstruction ? OverlayPalette.violet.opacity(0.6) : OverlayPalette.pendingText
        return Text(String(live.text.prefix(settledCount))).foregroundStyle(base)
            + Text(String(live.text.dropFirst(settledCount))).foregroundStyle(pendingColor)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            switch viewModel.phase {
            case .connecting, .recording:
                OverlayWaveform(
                    viewModel: viewModel,
                    color: viewModel.phase == .connecting ? OverlayPalette.connecting : tint
                )
                Text(OverlayCopy.listeningHint(viewModel))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.phase == .recording, !viewModel.isCommandMode || viewModel.countdownSeconds != nil {
                    if let seconds = viewModel.countdownSeconds {
                        Text(OverlayCopy.countdown(seconds))
                            .monospacedDigit()
                            .foregroundStyle(OverlayPalette.amber)
                            .accessibilityLabel("Recording stops in \(seconds) seconds")
                    } else {
                        Text(OverlayCopy.clock(viewModel.elapsedSeconds)).monospacedDigit()
                    }
                }
            case .idle:
                // Hidden; no spinner left running off screen (see the pill).
                EmptyView()
            case .processing:
                OverlaySpinner(color: viewModel.isCommandMode ? OverlayPalette.violet : OverlayPalette.text)
                Text(OverlayCopy.workingDetail(viewModel))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if viewModel.showsEscapeHint {
                    Text("Esc to cancel").accessibilityHidden(true)
                }
            case .failure:
                EmptyView()
            }
            if viewModel.isPointerInside, OverlayInteraction.acceptsClicks(in: viewModel.phase) {
                OverlayControls(viewModel: viewModel)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(OverlayPalette.secondaryText)
    }
}

// MARK: - OverlayHostingView

/// Takes the first click, and reports the pointer entering and leaving. The
/// panel is never key, so without `acceptsFirstMouse` a click on Stop would
/// only be spent on activating the window, and SwiftUI hover tracking would
/// not run while another app is active.
final class OverlayHostingView: NSHostingView<HandyOverlayView> {
    var onPointerInside: ((Bool) -> Void)?
    private var pointerTracking: NSTrackingArea?
    /// The visible card in window coordinates; hover is tracked over it alone.
    var cardRectInWindow: NSRect? {
        didSet { if cardRectInWindow != oldValue { updateTrackingAreas() } }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        // The hosting view is flipped: the shadow room above the card is
        // the inset's top.
        let insets = OverlayLayout.shadowInsets
        let slot = NSRect(
            x: insets.left, y: isFlipped ? insets.top : insets.bottom,
            width: max(0, bounds.width - insets.left - insets.right),
            height: max(0, bounds.height - insets.top - insets.bottom)
        )
        let card = cardRectInWindow.map { convert($0, from: nil) } ?? slot
        let area = NSTrackingArea(
            rect: card,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerInside?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerInside?(false)
    }
}

// MARK: - CursorOverlayManaging Conformance

extension CursorOverlayManager: CursorOverlayManaging {}

/// Immutable desktop geometry keeps synchronous Accessibility IPC off the main actor.
private enum CaretPositionQuery {
    // MARK: - Caret Position Detection

    static func position(panelSize: CGSize, visibleScreenFrames: [CGRect], primaryScreenTop: CGFloat, mouse: CGPoint, applicationPID: pid_t) -> NSPoint {
        let systemWide = AXUIElementCreateApplication(applicationPID)
        AXUIElementSetMessagingTimeout(systemWide, 0.1)

        let app = systemWide

        var focusedElement: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           let element = axElement(focusedElement) {
            AXUIElementSetMessagingTimeout(element, 0.1)

            if let caretRect = getCaretRectFromElement(element, primaryScreenTop: primaryScreenTop) {
                VocaLogger.debug(.cursorOverlay, "Positioned via caret")
                return OverlayPlacement.origin(
                    near: caretRect,
                    panelSize: panelSize,
                    visibleFrames: visibleScreenFrames
                )
            }

            if let elementRect = convertAXRectToAppKit(getElementRect(element), primaryScreenTop: primaryScreenTop) {
                VocaLogger.debug(.cursorOverlay, "Positioned via focused element")
                return OverlayPlacement.origin(
                    near: elementRect,
                    panelSize: panelSize,
                    visibleFrames: visibleScreenFrames
                )
            }
        }

        if let windowRect = convertAXRectToAppKit(getFocusedWindowRect(app), primaryScreenTop: primaryScreenTop) {
            VocaLogger.debug(.cursorOverlay, "Positioned via focused window")
            return OverlayPlacement.clampedOrigin(
                NSPoint(x: windowRect.maxX - panelSize.width - 20, y: windowRect.maxY - panelSize.height - 20),
                panelSize: panelSize, visibleFrames: visibleScreenFrames
            )
        }

        VocaLogger.debug(.cursorOverlay, "Positioned via mouse cursor (fallback)")
        return OverlayPlacement.clampedOrigin(mouse, panelSize: panelSize, visibleFrames: visibleScreenFrames)
    }

    private static func getCaretRectFromElement(_ element: AXUIElement, primaryScreenTop: CGFloat) -> CGRect? {
        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)
        guard rangeResult == .success, let range = selectedRange else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let boundsValue = axValue(bounds) else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(boundsValue, .cgRect, &rect) else { return nil }

        return convertAXRectToAppKit(rect, primaryScreenTop: primaryScreenTop)
    }

    private static func getElementRect(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionValue = axValue(positionRef) else { return nil }

        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeValue = axValue(sizeRef) else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }

        return CGRect(origin: position, size: size)
    }

    private static func getFocusedWindowRect(_ app: AXUIElement) -> CGRect? {
        var window: CFTypeRef?
        var result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)

        if result != .success {
            result = AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window)
        }

        guard result == .success, let element = axElement(window) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.1)
        return getElementRect(element)
    }

    // MARK: - Type-checked AX casts

    // Other apps' Accessibility implementations can return nil or an
    // unexpected CF type even when the call reports success.
    // swiftlint:disable force_cast
    private static func axElement(_ ref: CFTypeRef?) -> AXUIElement? {
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return (ref as! AXUIElement)
    }

    private static func axValue(_ ref: CFTypeRef?) -> AXValue? {
        guard let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }
    // swiftlint:enable force_cast

    // MARK: - Coordinate Helpers

    private static func convertAXRectToAppKit(_ rect: CGRect?, primaryScreenTop: CGFloat) -> CGRect? {
        guard let rect,
              rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite else { return nil }
        var converted = rect
        converted.origin.y = primaryScreenTop - rect.origin.y - rect.height
        return converted
    }

}
