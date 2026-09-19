// VocaMacApp.swift
// VocaMac
//
// Main entry point for the VocaMac application.
// Configures the app as a menu bar-only application (no Dock icon).

import SwiftUI

extension Notification.Name {
    static let vocaOpenURL = Notification.Name("com.vocamac.open-url")
}

final class VocaApplicationDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NotificationCenter.default.post(name: .vocaOpenURL, object: url)
        }
    }
}

/// Manages the settings window for menu-bar-only apps
@MainActor
final class SettingsWindowManager: ObservableObject {
    /// Shared instance. The deep-link observer in `VocaMacApp.init` reads
    /// this manager before its `@StateObject` is installed on a view, and
    /// every such access builds a new manager that is released as soon as
    /// the call returns — so a link would open a second window instead of
    /// focusing the open one, and the close observer token would die with
    /// the manager, leaving the Dock icon behind.
    static let shared = SettingsWindowManager()

    private var settingsWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func open(appState: AppState) {
        // If window already exists, just bring it to front
        if let window = settingsWindow {
            restoreUsableFrame(window)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create the settings view
        let settingsView = SettingsView()
            .environmentObject(appState)

        // Create a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VocaMac Settings"
        // A hosting controller lets the native split view own its toolbar and
        // safe area, including the system sidebar toggle.
        window.titleVisibility = .hidden
        window.backgroundColor = .windowBackgroundColor
        let hostingController = NSHostingController(rootView: settingsView)
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 760, height: 580)
        // With automatic hosting sizing disabled, attaching the controller
        // can collapse the initial window to its 1-point intrinsic width.
        // Establish the default again before applying a saved frame.
        window.setContentSize(NSSize(width: 860, height: 620))
        window.autorecalculatesKeyViewLoop = true
        if !window.setFrameUsingName("VocaMac.Settings") { window.center() }
        restoreUsableFrame(window)
        window.setFrameAutosaveName("VocaMac.Settings")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window

        // Show in the Dock so the window can take focus.
        DockVisibilityCoordinator.shared.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        // Held so it can be removed on close — a block-based observer lives
        // until its token is released, so opening repeatedly would otherwise
        // stack up observers.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settingsWindow = nil
                if let observer = self.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.closeObserver = nil
                }
                DockVisibilityCoordinator.shared.windowDidClose()
            }
        }
    }

    /// Reject collapsed or off-screen frames left by hosting layout or an
    /// earlier display configuration before making the window visible.
    private func restoreUsableFrame(_ window: NSWindow) {
        let screens = NSScreen.screens.map(\.visibleFrame)
        if SettingsWindowGeometry.needsReset(window.frame, screens: screens) {
            window.setContentSize(NSSize(width: 860, height: 620))
            window.center()
        }
    }
}

/// Manages the standalone update details window.
/// Update details open in their own window rather than as a sheet inside the
/// MenuBarExtra popover: sheets there detach, fight the popover for focus,
/// and pull it down along with themselves when dismissed.
@MainActor
final class UpdateWindowManager: ObservableObject {
    private var updateWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    /// The release currently on screen, so a newer one can replace it.
    private var presentedInfo: UpdateInfo?

    func open(appState: AppState, info: UpdateInfo) {
        if let window = updateWindow, window.isVisible {
            // Already showing this release — just bring it forward. If a
            // newer one arrived while the window was open, swap the contents
            // rather than leaving the stale release on screen.
            if presentedInfo != info {
                window.contentView = NSHostingView(rootView: detailView(appState: appState, info: info))
                presentedInfo = info
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let updateView = detailView(appState: appState, info: info)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VocaMac Update"
        window.contentView = NSHostingView(rootView: updateView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.updateWindow = window
        self.presentedInfo = info

        // Show in the Dock so the window can take focus.
        DockVisibilityCoordinator.shared.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateWindow = nil
                self.presentedInfo = nil
                if let observer = self.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.closeObserver = nil
                }
                DockVisibilityCoordinator.shared.windowDidClose()
            }
        }
    }

    private func detailView(appState: AppState, info: UpdateInfo) -> some View {
        UpdateDetailView(info: info, isPresented: Binding(
            get: { true },
            set: { [weak self] stillPresented in
                if !stillPresented { self?.updateWindow?.close() }
            }
        ))
        .environmentObject(appState)
    }
}

/// Manages the onboarding window
@MainActor
final class OnboardingWindowManager: ObservableObject {
    /// Shared instance. Every caller lives in a closure created by
    /// `VocaMacApp.init`, where a `@StateObject` is not yet installed on a
    /// view: each access there builds a *new* manager that is released as soon
    /// as the call returns. A per-App-struct manager therefore forgets its own
    /// window the moment it is shown — nothing is left to bring an existing
    /// window forward, and the close observer token dies with it, so the Dock
    /// is never told the window went away.
    static let shared = OnboardingWindowManager()

    private var onboardingWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    private init() {}

    func open(appState: AppState) {
        // If window already exists, just bring it to front
        if let window = onboardingWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        // Create the onboarding view. It closes this window directly rather
        // than going back through the manager, so "Finish" and "Set up later"
        // work regardless of who still holds a reference to the manager.
        let onboardingView = OnboardingView { [weak window] in
            window?.close()
        }
            .environmentObject(appState)

        window.contentMinSize = NSSize(width: 780, height: 600)
        window.title = "Welcome to VocaMac"
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window

        // Show in the Dock so the window can take focus.
        DockVisibilityCoordinator.shared.windowDidOpen()
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onboardingWindow = nil
                if let observer = self.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.closeObserver = nil
                }
                DockVisibilityCoordinator.shared.windowDidClose()
            }
        }
    }
}

struct VocaMacApp: App {
    /// Set by the first `init`; see the URL observer there.
    @MainActor private static var didInstallURLObserver = false
    @NSApplicationDelegateAdaptor(VocaApplicationDelegate.self) private var applicationDelegate
    @StateObject private var appState = AppState.production()
    @StateObject private var settingsManager = SettingsWindowManager.shared
    @StateObject private var updateWindowManager = UpdateWindowManager()
    @StateObject private var fileTranscriptionManager = FileTranscriptionWindowManager.shared
    @StateObject private var scratchpadManager = ScratchpadWindowManager.shared
    @StateObject private var meetingCaptureManager = MeetingCaptureWindowManager()

    var body: some Scene {
        // Menu bar presence — the primary UI for VocaMac
        MenuBarExtra {
            MenuBarView(
                settingsManager: settingsManager,
                updateWindowManager: updateWindowManager,
                fileTranscriptionManager: fileTranscriptionManager,
                scratchpadManager: scratchpadManager,
                meetingCaptureManager: meetingCaptureManager
            )
                .environmentObject(appState)
        } label: {
            MenuBarIcon(appStatus: appState.appStatus, isCommandMode: appState.commandModeSession != nil)
                .onAppear {
                    // Trigger startup from the SwiftUI lifecycle so it only runs
                    // on the AppState instance that SwiftUI actually retains.
                    // Previously, startup ran in AppState.init() which caused
                    // double initialization (and double event taps) because
                    // SwiftUI may instantiate the App struct more than once.
                    appState.triggerStartupIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor init() {
        // Ensure only one instance of VocaMac is running
        Self.ensureSingleInstance()
        appState.repairLegacyOnboardingCompletionIfNeeded()

        // For .app bundles, Dock hiding is handled by LSUIElement=true in Info.plist.
        // For direct binary execution, we set it programmatically.
        DispatchQueue.main.async {
            NSApp?.setActivationPolicy(.accessory)
        }

        // Listen for setup requests from Settings. Reopening setup must not
        // clear the durable completion flag: closing a refresher window should
        // never make onboarding appear again after the next login.
        NotificationCenter.default.addObserver(
            forName: .showOnboarding,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor [self] in
                OnboardingWindowManager.shared.open(appState: self.appState)
            }
        }

        // SwiftUI can build the App struct more than once. A second observer
        // would handle every link twice — two confirmations, and a toggle
        // link that starts and immediately stops recording.
        if !Self.didInstallURLObserver {
            Self.didInstallURLObserver = true
            NotificationCenter.default.addObserver(
                forName: .vocaOpenURL,
                object: nil,
                queue: .main
            ) { [self] notification in
                guard let url = notification.object as? URL,
                      let link = VocaDeepLink(url: url) else { return }
                let returnTarget: NSRunningApplication?
                if link.requiresExternalConfirmation {
                    returnTarget = NSWorkspace.shared.frontmostApplication
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Allow VocaMac action?"
                    alert.informativeText = "Another app or website asked VocaMac to \(link.confirmationDescription). Continue only if you initiated this action."
                    alert.addButton(withTitle: "Allow")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                } else {
                    returnTarget = nil
                }
                Task { @MainActor [self] in
                    // The confirmation window activates VocaMac. Put the user's
                    // original destination back in front before recording or text
                    // insertion resolves its target.
                    if let returnTarget,
                       returnTarget.bundleIdentifier != Bundle.main.bundleIdentifier {
                        returnTarget.activate()
                        try? await Task.sleep(for: .milliseconds(150))
                    }
                    await appState.handleDeepLink(link)
                    switch link {
                    case .history, .settings:
                        settingsManager.open(appState: appState)
                    case .transcribeFile:
                        fileTranscriptionManager.open(appState: appState)
                    case .scratchpad:
                        scratchpadManager.open(appState: appState)
                    case .startDictation, .stopDictation, .toggleDictation, .pasteLast:
                        break
                    }
                }
            }
        }

        // Show onboarding on first launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !self.appState.hasCompletedOnboarding {
                OnboardingWindowManager.shared.open(appState: self.appState)
            }
        }
    }

    /// Terminate any other running instances of VocaMac
    private static func ensureSingleInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.vocamac.app")

        for app in runningApps where app.processIdentifier != currentPID {
            VocaLogger.info(.general, "Terminating previous instance (PID \(app.processIdentifier))")
            app.terminate()
        }

        // Also kill by process name for direct binary execution (no bundle ID).
        // Match the executable's own name, never a substring of the command
        // line: `tail -f ~/Library/Logs/VocaMac/…`, an editor with
        // `Sources/VocaMac/…` open, or `xcodebuild -scheme VocaMac` must not
        // be terminated. A running headless CLI job (e.g.
        // `VocaMac --transcribe-file ... --json`) is left alone too.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ucomm=,args="]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            if let output = String(data: data, encoding: .utf8) {
                for pid in previousGUIInstancePIDs(psOutput: output, currentPID: currentPID) {
                    VocaLogger.info(.general, "Killing previous VocaMac process (PID \(pid))")
                    kill(pid, SIGTERM)
                }
            }
        } catch {
            // ps not found or failed — not critical
        }
    }

    /// PIDs of other GUI VocaMac processes in `ps -axo pid=,ucomm=,args=`
    /// output: the executable name must be exactly `VocaMac`, and headless CLI
    /// invocations (see `CLICommand.cliFlags`) are skipped.
    nonisolated static func previousGUIInstancePIDs(psOutput: String, currentPID: Int32) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let pid = Int32(fields[0]), pid != currentPID,
                  fields[1] == "VocaMac" else { return nil }
            let arguments = fields.count > 2 ? fields[2].split(separator: " ").map(String.init) : []
            guard !arguments.contains(where: CLICommand.cliFlags.contains) else { return nil }
            return pid
        }
    }
}

// MARK: - Menu Bar Icon

/// Renders the Voca mark in the menu bar with color changes based on app status.
///
/// Idle uses a template SF Symbol mic so it matches neighboring status items.
/// Recording tints the Voca mark brand teal. Processing and error keep SF Symbols.
///
/// MenuBarExtra strips SwiftUI `.foregroundStyle()` colors, so status colors
/// are applied via `NSImage` + `sourceAtop` with `isTemplate = false`.
///
/// States:
///   • idle       → SF Symbol mic.fill (template, adapts to menu bar)
///   • recording  → Voca mark in brand teal (mic hot)
///   • processing → yellow ellipsis (non-template, colored)
///   • error      → orange warning (non-template, colored)
struct MenuBarIcon: View {
    let appStatus: AppStatus
    var isCommandMode = false

    var body: some View {
        Image(nsImage: makeMenuBarIcon())
    }

    private func makeMenuBarIcon() -> NSImage {
        switch MenuBarIconStyle.style(for: appStatus, isCommandMode: isCommandMode) {
        case .brandMarkTemplate:
            if let mark = sizedMark() {
                mark.isTemplate = true
                return mark
            }
            return fallbackSymbol(named: "mic.fill", tint: nil)

        case .systemSymbolTemplate(let name):
            return fallbackSymbol(named: name, tint: nil)

        case .brandMarkTinted:
            if let mark = sizedMark() {
                return tintedImage(base: mark, color: BrandAssets.brandGreen)
            }
            return fallbackSymbol(named: "mic.fill", tint: BrandAssets.brandGreen)

        case .systemSymbol(let name):
            return fallbackSymbol(named: name, tint: statusColor)
        }
    }

    /// Menu-bar point size for the brand mark.
    /// Slightly above the 16pt SF Symbol default so the line-art mic reads at a
    /// similar visual weight to neighboring status items.
    private static let markPointSize: CGFloat = 20

    /// Sized copy of the bundled mic mark, or `nil` if the asset is missing.
    ///
    /// The mark is taller than it is wide, so it is scaled to fit the square
    /// slot (not stretched) and centered — that uses the full slot height.
    private func sizedMark() -> NSImage? {
        guard let mark = BrandAssets.mark else { return nil }
        let slot = Self.markPointSize
        let size = NSSize(width: slot, height: slot)
        return NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            let markSize = mark.size
            guard markSize.width > 0, markSize.height > 0 else { return false }
            let scale = min(rect.width / markSize.width, rect.height / markSize.height)
            let drawSize = NSSize(width: markSize.width * scale, height: markSize.height * scale)
            let drawRect = NSRect(
                x: rect.midX - drawSize.width / 2,
                y: rect.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            mark.draw(in: drawRect)
            return true
        }
    }

    private func fallbackSymbol(named name: String, tint: NSColor?) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: Self.markPointSize, weight: .regular)
        guard let baseImage = NSImage(systemSymbolName: name, accessibilityDescription: "VocaMac")?
            .withSymbolConfiguration(config) else {
            return NSImage(systemSymbolName: "mic", accessibilityDescription: "VocaMac") ?? NSImage()
        }

        guard let tint else {
            let copy = baseImage.copy() as? NSImage ?? baseImage
            copy.isTemplate = true
            return copy
        }

        return tintedImage(base: baseImage, color: tint)
    }

    private func tintedImage(base: NSImage, color: NSColor) -> NSImage {
        let size = base.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private var statusColor: NSColor {
        if isCommandMode { return VocaDesign.commandNSColor }
        switch appStatus {
        case .idle:       return BrandAssets.brandGreen
        case .recording:  return BrandAssets.brandGreen
        case .processing: return .systemYellow
        case .error:      return .systemOrange
        }
    }
}
