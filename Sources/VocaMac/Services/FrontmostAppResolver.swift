// FrontmostAppResolver.swift
// VocaMac
//
// Identifies the application that is about to receive injected text.

import Foundation
import AppKit

/// Reads the frontmost application from `NSWorkspace`.
///
/// Resolution happens at injection time rather than at record start, because
/// text lands wherever focus actually is when the paste or Accessibility write
/// happens — styling for a different app than the one receiving the text is
/// the one failure mode users would call a bug. VocaMac is an `LSUIElement`
/// agent and the cursor overlay is non-activating, so the frontmost app does
/// not normally change during a dictation.
///
/// The menu bar popover is the exception: `.menuBarExtraStyle(.window)`
/// activates VocaMac, so while the popover is open the frontmost app is
/// VocaMac itself and `currentFrontmostApp()` returns `nil`. A workspace
/// activation observer remembers the app the user came from, which is the one
/// the menu bar's style row is really talking about.
///
/// This is a single `NSWorkspace` read per dictation. It deliberately does not
/// poll.
@MainActor
final class FrontmostAppResolver: FrontmostAppResolving {

    /// Last non-VocaMac app to be activated. Written from the activation
    /// notification, which `NSWorkspace` delivers on the main thread.
    private var lastActive: RunningAppSnapshot?
    private var observer: NSObjectProtocol?

    init() {
        lastActive = AppIdentityMatching.snapshot(for: NSWorkspace.shared.frontmostApplication)
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let snapshot = AppIdentityMatching.snapshot(for: app) else { return }
            self?.lastActive = snapshot
        }
    }

    deinit {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    func currentFrontmostApp() -> RunningAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            VocaLogger.debug(.textInjector, "No frontmost application reported")
            return nil
        }
        // `snapshot(for:)` returns nil for VocaMac itself, which is what we
        // want: when Settings has focus the caller falls back to the snapshot
        // taken when recording started, or to the last active app.
        return AppIdentityMatching.snapshot(for: app)
    }

    func lastActiveApp() -> RunningAppSnapshot? {
        lastActive
    }
}
