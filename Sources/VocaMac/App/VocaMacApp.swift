// VocaMacApp.swift
// VocaMac
//
// Main entry point for the VocaMac application.
// Configures the app as a menu bar-only application (no Dock icon).

import SwiftUI

/// Manages the settings window for menu-bar-only apps
@MainActor
final class SettingsWindowManager: ObservableObject {
    private var settingsWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func open(appState: AppState) {
        // If window already exists, just bring it to front
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create the settings view
        let settingsView = SettingsView()
            .environmentObject(appState)

        // Create a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VocaMac Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
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
    private var onboardingWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    var onCompletion: (() -> Void)?

    func open(appState: AppState, force: Bool = false) {
        // If window already exists, just bring it to front
        if let window = onboardingWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // When manually re-triggered, reset completion flag so the
        // monitor doesn't immediately close the window
        if force {
            appState.hasCompletedOnboarding = false
        }

        // Create the onboarding view
        let onboardingView = OnboardingView()
            .environmentObject(appState)

        // Create a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to VocaMac"
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

        // Monitor app state for onboarding completion on main thread
        DispatchQueue.main.async {
            self.monitorOnboardingCompletion(appState: appState)
        }
    }

    private func monitorOnboardingCompletion(appState: AppState) {
        Task {
            while self.onboardingWindow?.isVisible == true {
                await MainActor.run {
                    if appState.hasCompletedOnboarding {
                        self.onboardingWindow?.close()
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)  // Check every 100ms
            }
        }
    }
}

@main
struct VocaMacApp: App {
    @StateObject private var appState = AppState.production()
    @StateObject private var settingsManager = SettingsWindowManager()
    @StateObject private var updateWindowManager = UpdateWindowManager()
    @StateObject private var onboardingManager = OnboardingWindowManager()

    var body: some Scene {
        // Menu bar presence — the primary UI for VocaMac
        MenuBarExtra {
            MenuBarView(settingsManager: settingsManager, updateWindowManager: updateWindowManager)
                .environmentObject(appState)
        } label: {
            MenuBarIcon(appStatus: appState.appStatus)
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

        // For .app bundles, Dock hiding is handled by LSUIElement=true in Info.plist.
        // For direct binary execution, we set it programmatically.
        DispatchQueue.main.async {
            NSApp?.setActivationPolicy(.accessory)
        }

        // Listen for "Show Setup Wizard" requests from Settings / Menu Bar
        NotificationCenter.default.addObserver(
            forName: .showOnboarding,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor [self] in
                self.onboardingManager.open(appState: self.appState, force: true)
            }
        }

        // Show onboarding on first launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !self.appState.hasCompletedOnboarding {
                self.onboardingManager.open(appState: self.appState)
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

        // Also kill by process name for direct binary execution (no bundle ID)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "VocaMac"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pids = output.split(separator: "\n").compactMap { Int32($0) }
                for pid in pids where pid != currentPID {
                    VocaLogger.info(.general, "Killing previous VocaMac process (PID \(pid))")
                    kill(pid, SIGTERM)
                }
            }
        } catch {
            // pgrep not found or failed — not critical
        }
    }
}

// MARK: - Menu Bar Icon

/// Renders the Voca mark in the menu bar with color changes based on app status.
///
/// Idle uses a template silhouette so macOS follows the menu bar appearance.
/// Recording tints that same mark brand teal. Processing and error keep SF Symbols.
///
/// MenuBarExtra strips SwiftUI `.foregroundStyle()` colors, so status colors
/// are applied via `NSImage` + `sourceAtop` with `isTemplate = false`.
///
/// States:
///   • idle       → Voca mark (template, adapts to menu bar)
///   • recording  → Voca mark in brand teal (mic hot)
///   • processing → yellow ellipsis (non-template, colored)
///   • error      → orange warning (non-template, colored)
struct MenuBarIcon: View {
    let appStatus: AppStatus

    var body: some View {
        Image(nsImage: makeMenuBarIcon())
    }

    private func makeMenuBarIcon() -> NSImage {
        switch MenuBarIconStyle.style(for: appStatus) {
        case .brandMarkTemplate:
            if let mark = sizedMark() {
                mark.isTemplate = true
                return mark
            }
            return fallbackSymbol(named: "mic.fill", tint: nil)

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
        switch appStatus {
        case .idle:       return BrandAssets.brandGreen
        case .recording:  return BrandAssets.brandGreen
        case .processing: return .systemYellow
        case .error:      return .systemOrange
        }
    }
}
