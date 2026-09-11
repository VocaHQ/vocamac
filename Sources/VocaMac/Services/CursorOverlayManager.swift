// CursorOverlayManager.swift
// VocaMac
//
// Shows a Handy-inspired floating recording overlay. The overlay can be a
// compact pill or a larger status panel and can be anchored to the caret or to
// the top/bottom edge of the active display.

import AppKit
import SwiftUI

// MARK: - Overlay Layout

/// Shared overlay dimensions keep the AppKit panel and SwiftUI content in sync.
enum OverlayLayout {
    /// Transparent room for rounded-edge antialiasing at the native panel boundary.
    static let edgeInset: CGFloat = 2

    static func contentSize(for style: OverlayStyle) -> CGSize {
        switch style {
        case .off:
            return .zero
        case .minimal:
            return CGSize(width: 108, height: 44)
        case .live:
            return CGSize(width: 340, height: 104)
        }
    }

    static func size(for style: OverlayStyle) -> CGSize {
        let content = contentSize(for: style)
        guard content != .zero else { return .zero }
        return CGSize(
            width: content.width + edgeInset * 2,
            height: content.height + edgeInset * 2
        )
    }
}

/// Pure placement helpers used by the Accessibility-based cursor positioning.
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

// MARK: - CursorOverlayManager

@MainActor
final class CursorOverlayManager {

    // MARK: - Properties

    /// The floating panel that hosts the overlay.
    private var overlayPanel: NSPanel?

    /// Hosting view for the SwiftUI overlay content.
    private var hostingView: NSHostingView<HandyOverlayView>?

    /// The SwiftUI view model driving the overlay.
    private let viewModel = MicIndicatorViewModel()

    /// Timer to follow the caret or active display when needed.
    private var repositionTimer: Timer?
    private let positionQueue = DispatchQueue(label: "com.vocamac.caret", qos: .userInitiated)
    private var isPositionQueryRunning = false
    private var positionGeneration = UUID()

    /// Timer for the recording duration shown by the live panel.
    private var elapsedTimer: Timer?

    // MARK: - Public API

    /// Shows the recording overlay using the requested style and position.
    func show(style: OverlayStyle, position: OverlayPosition) {
        guard style != .off else {
            hide()
            return
        }

        positionGeneration = UUID()
        viewModel.style = style
        viewModel.position = position
        // Capture has not begun yet — `transitionToRecording()` says when it has.
        viewModel.phase = .connecting
        viewModel.audioLevel = 0
        viewModel.elapsedSeconds = 0
        viewModel.transcript = ""
        viewModel.isCommandMode = false
        viewModel.isActive = true

        if let overlayPanel {
            updatePanelLayout(overlayPanel)
            startTimers()
            VocaLogger.debug(.cursorOverlay, "Overlay shown (existing panel, style=\(style.rawValue))")
            return
        }

        let size = overlaySize
        let hosting = NSHostingView(rootView: HandyOverlayView(viewModel: viewModel))
        hosting.frame = NSRect(origin: .zero, size: size)
        // Follow the system appearance so SwiftUI colorScheme stays in sync.
        hosting.appearance = nil

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = nil
        // Overlay is display-only; clicks pass through so the target app keeps focus.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.contentView = hosting

        overlayPanel = panel
        hostingView = hosting
        updatePanelLayout(panel)
        panel.orderFrontRegardless()
        startTimers()

        VocaLogger.debug(.cursorOverlay, "Overlay shown (style=\(style.rawValue), position=\(position.rawValue))")
    }

    /// The input route is live and the microphone is actually capturing.
    func transitionToRecording() {
        guard overlayPanel != nil, viewModel.phase == .connecting else { return }
        viewModel.phase = .recording
        viewModel.audioLevel = 0
        viewModel.elapsedSeconds = 0
        viewModel.transcript = ""
        VocaLogger.debug(.cursorOverlay, "Overlay transitioned to recording")
    }

    /// Transitions the overlay from recording to batch transcription.
    func transitionToProcessing() {
        guard overlayPanel != nil else { return }
        viewModel.phase = .processing
        viewModel.isActive = true
        if let overlayPanel {
            updatePanelLayout(overlayPanel)
        }
        VocaLogger.debug(.cursorOverlay, "Overlay transitioned to processing")
    }

    /// Hides the recording overlay and resets its transient state.
    func hide() {
        positionGeneration = UUID()
        repositionTimer?.invalidate()
        repositionTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil

        viewModel.isActive = false
        viewModel.phase = .idle
        viewModel.audioLevel = 0
        viewModel.waveformTick = 0
        viewModel.elapsedSeconds = 0

        overlayPanel?.orderOut(nil)
        overlayPanel = nil
        hostingView = nil
        VocaLogger.debug(.cursorOverlay, "Overlay hidden")
    }

    /// Updates the current audio level used to animate the waveform.
    func updateAudioLevel(_ level: Float) {
        guard overlayPanel != nil, viewModel.phase == .recording else { return }
        // Mild pre-gain so quiet speech still drives a lively waveform.
        let target = min(max(level * 2.6, 0), 1)
        let smoothing: Float = target > viewModel.audioLevel ? 0.78 : 0.28
        viewModel.audioLevel += (target - viewModel.audioLevel) * smoothing
        viewModel.waveformTick &+= 1
    }

    func updateTranscript(_ text: String) {
        guard overlayPanel != nil, viewModel.style == .live else { return }
        viewModel.transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setCommandMode(_ active: Bool) {
        viewModel.isCommandMode = active
    }

    // MARK: - Layout

    private var overlaySize: CGSize {
        OverlayLayout.size(for: viewModel.style)
    }

    private func updatePanelLayout(_ panel: NSPanel) {
        let size = overlaySize
        panel.setContentSize(size)
        hostingView?.frame = NSRect(origin: .zero, size: size)
        positionPanel(panel, size: size)
    }

    private func positionPanel(_ panel: NSPanel, size: CGSize) {
        switch viewModel.position {
        case .nearCursor:
            requestCaretPosition(panel, size: size)
        case .top, .bottom:
            guard let screen = activeScreen else {
                requestCaretPosition(panel, size: size)
                return
            }

            let visibleFrame = screen.visibleFrame
            let x = visibleFrame.midX - size.width / 2
            let y: CGFloat
            switch viewModel.position {
            case .top:
                y = visibleFrame.maxY - size.height - 46
            case .bottom:
                y = visibleFrame.minY + 15
            case .nearCursor:
                y = visibleFrame.minY
            }
            panel.setFrameOrigin(NSPoint(x: x, y: y))
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
                guard let self, let panel = self.overlayPanel else { return }
                self.positionPanel(panel, size: self.overlaySize)
            }
        }

        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel.phase == .recording else { return }
                self.viewModel.elapsedSeconds += 1
            }
        }
    }

    /// At most one query runs at once. Hide/show and focus changes invalidate its result.
    private func requestCaretPosition(_ panel: NSPanel, size: CGSize) {
        guard !isPositionQueryRunning else { return }
        let frames = NSScreen.screens.map(\.visibleFrame)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let mouse = NSEvent.mouseLocation
        let fallback = CGPoint(x: mouse.x + 16, y: mouse.y - 40)
        if !panel.isVisible {
            panel.setFrameOrigin(OverlayPlacement.clampedOrigin(fallback, panelSize: size, visibleFrames: frames))
        }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let generation = positionGeneration
        isPositionQueryRunning = true
        positionQueue.async { [weak self] in
            let interval = PerformanceTrace.begin("CaretAccessibilityQuery")
            let origin = CaretPositionQuery.position(
                panelSize: size, visibleScreenFrames: frames,
                primaryScreenTop: top, mouse: fallback, applicationPID: pid
            )
            PerformanceTrace.end(interval)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPositionQueryRunning = false
                guard self.positionGeneration == generation,
                      self.overlayPanel === panel,
                      self.viewModel.position == .nearCursor,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
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
    @Published var transcript: String = ""
    /// The session edits selected text (Command Mode) instead of dictating.
    @Published var isCommandMode = false
}

// MARK: - Waveform Metrics

/// Converts the single audio level currently exposed by AudioEngine into the
/// nine asymmetric bars used by the Handy-inspired overlay.
enum OverlayWaveformMetrics {
    static let barProfile: [CGFloat] = [0.42, 0.68, 0.92, 0.70, 1.0, 0.78, 0.88, 0.60, 0.38]

    /// Amplifies quiet speech so the bars react clearly without needing to shout.
    static let inputGain: CGFloat = 3.4

    static func heights(for level: Float, tick: Int = 0, maximumHeight: CGFloat = 18) -> [CGFloat] {
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

// MARK: - HandyOverlayView

struct HandyOverlayView: View {
    @ObservedObject var viewModel: MicIndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false
    @State private var hasEntered = false

    private var isDark: Bool { colorScheme == .dark }

    /// A brighter recording accent keeps the small waveform and status icon
    /// distinct from the panel in both system appearances.
    private var recordingColor: Color {
        VocaDesign.accent
    }

    /// Yellow is clear on a dark panel, while the deeper amber remains visible
    /// against the light panel when it is used for the processing spinner.
    private var processingColor: Color {
        isDark
            ? Color(nsColor: .systemYellow)
            : Color(red: 0.55, green: 0.27, blue: 0.0)
    }

    private var panelFill: Color {
        isDark
            ? Color(white: 0.16)
            : Color(red: 0.99, green: 0.99, blue: 1.0)
    }

    private var primaryText: Color {
        isDark ? Color.white.opacity(0.96) : Color(red: 0.08, green: 0.1, blue: 0.12)
    }

    private var secondaryText: Color {
        isDark ? Color.white.opacity(0.68) : Color.black.opacity(0.52)
    }

    private var tertiaryFill: Color {
        isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.06)
    }

    private var strokeBase: Color {
        isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.14)
    }

    /// Muted while the route comes up: the panel is visible but the microphone
    /// is not live yet, and it should not look like it is.
    private var connectingColor: Color {
        isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
    }

    private var waveformColor: Color {
        switch viewModel.phase {
        case .recording: return recordingColor
        case .connecting: return connectingColor
        case .idle, .processing: return processingColor
        }
    }

    private var accentColor: Color { waveformColor }

    private var statusTitle: String {
        switch viewModel.phase {
        case .connecting: return "Connecting"
        case .recording: return viewModel.isCommandMode ? "Command Mode" : "Listening"
        case .idle, .processing: return viewModel.isCommandMode ? "Editing Selection" : "Transcribing"
        }
    }

    private var statusDetail: String {
        switch viewModel.phase {
        case .connecting: return "Waiting for microphone…"
        case .recording: return viewModel.isCommandMode ? "Say how to change it" : "Speak now"
        case .idle, .processing: return viewModel.isCommandMode ? "Rewriting…" : "Transcribing…"
        }
    }

    private var transcriptPlaceholder: String {
        viewModel.isCommandMode
            ? "e.g. “make this shorter” or “translate to Spanish”"
            : "Words will appear here as you speak"
    }

    private var recordingSymbol: String {
        if viewModel.phase == .connecting { return "mic.slash.fill" }
        return viewModel.isCommandMode ? "wand.and.stars" : "mic.fill"
    }

    private var slideInOffset: CGFloat {
        switch viewModel.position {
        case .top:
            return -42
        case .bottom, .nearCursor:
            return 42
        }
    }

    var body: some View {
        let content = OverlayLayout.contentSize(for: viewModel.style)

        Group {
            if viewModel.style == .live {
                livePanelContent
            } else {
                minimalControlRow
            }
        }
        .frame(width: content.width, height: content.height)
        .background(panelFill)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    viewModel.phase == .recording
                        ? recordingColor.opacity(isPulsing ? 0.95 : 0.55)
                        : strokeBase,
                    lineWidth: viewModel.phase == .recording ? 1.6 : 1
                )
        }
        // Leave only enough transparent room for rounded-edge antialiasing.
        // There is deliberately no outer shadow that could reveal panel bounds.
        .padding(OverlayLayout.edgeInset)
        .frame(width: panelSize.width, height: panelSize.height)
        .opacity(viewModel.isActive && hasEntered ? 1 : 0)
        .offset(y: hasEntered || reduceMotion ? 0 : slideInOffset)
        .scaleEffect(hasEntered || reduceMotion ? 1 : 0.94)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: hasEntered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: viewModel.phase)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9), value: isPulsing)
        .onAppear {
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            playEntranceIfNeeded()
        }
        .onChange(of: viewModel.isActive) { _, active in
            if active {
                playEntranceIfNeeded()
            } else {
                hasEntered = false
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

    private func playEntranceIfNeeded() {
        guard viewModel.isActive else { return }
        hasEntered = false
        // Defer one turn so the off-screen offset is committed before animating in.
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                hasEntered = true
            }
        }
    }

    private var panelSize: CGSize {
        OverlayLayout.size(for: viewModel.style)
    }

    private var cornerRadius: CGFloat {
        viewModel.style == .live ? 16 : 22
    }

    private var liveHeader: some View {
        HStack(spacing: 7) {
            recordingIndicatorIcon

            Text(statusTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(primaryText)

            Spacer()

            if viewModel.phase == .recording {
                Text(formattedElapsed)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(secondaryText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(tertiaryFill, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
    }

    private var livePanelContent: some View {
        VStack(spacing: 0) {
            liveHeader
            liveControlRow
            Text(viewModel.transcript.isEmpty ? transcriptPlaceholder : viewModel.transcript)
                .font(.system(size: 11))
                .foregroundStyle(viewModel.transcript.isEmpty ? secondaryText : primaryText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Live transcript")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var liveControlRow: some View {
        HStack(spacing: 8) {
            if viewModel.phase == .recording {
                waveform

                Text(statusDetail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentColor)

                Text(statusDetail)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(secondaryText)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 28)
    }

    @ViewBuilder
    private var minimalControlRow: some View {
        HStack(spacing: 8) {
            if viewModel.phase == .recording {
                recordingIndicatorIcon
                waveform
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(accentColor)
                    .accessibilityLabel(statusTitle)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private var waveform: some View {
        let maximumHeight: CGFloat = viewModel.style == .live ? 20 : 16
        let barWidth: CGFloat = viewModel.style == .live ? 4 : 3
        let spacing: CGFloat = viewModel.style == .live ? 3 : 2
        let heights = OverlayWaveformMetrics.heights(
            for: viewModel.audioLevel,
            tick: viewModel.waveformTick,
            maximumHeight: maximumHeight
        )

        return HStack(spacing: spacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(waveformColor)
                    .frame(width: barWidth, height: height)
            }
        }
        .frame(height: maximumHeight)
        .animation(
            .interactiveSpring(response: 0.18, dampingFraction: 0.68, blendDuration: 0.06),
            value: viewModel.waveformTick
        )
        .accessibilityLabel("Microphone level")
    }

    private var recordingIndicatorIcon: some View {
        ZStack {
            if viewModel.phase == .recording {
                Circle()
                    .fill(recordingColor.opacity(isDark ? 0.28 : 0.18))
                    .frame(width: 22, height: 22)
                    .scaleEffect(isPulsing ? 1.08 : 0.86)
                    .opacity(isPulsing ? 0.55 : 0.9)
            }

            Image(systemName: recordingSymbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(accentColor)
                .shadow(color: waveformColor.opacity(0.45), radius: 3)
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(viewModel.phase == .recording ? "Recording" : statusTitle)
    }

    private var formattedElapsed: String {
        let minutes = viewModel.elapsedSeconds / 60
        let seconds = viewModel.elapsedSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
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

        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
           focusedElement != nil {
            let element = focusedElement as! AXUIElement
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

        var bounds: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success else { return nil }

        var rect = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &rect) else { return nil }

        return convertAXRectToAppKit(rect, primaryScreenTop: primaryScreenTop)
    }

    private static func getElementRect(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success else { return nil }

        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }

        return CGRect(origin: position, size: size)
    }

    private static func getFocusedWindowRect(_ app: AXUIElement) -> CGRect? {
        var window: AnyObject?
        var result = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)

        if result != .success {
            result = AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &window)
        }

        guard result == .success, window != nil else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        return getElementRect(element)
    }

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
