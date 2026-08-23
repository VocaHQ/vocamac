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
/// This is a single `NSWorkspace` read per dictation. It deliberately does not
/// poll.
final class FrontmostAppResolver: FrontmostAppResolving {

    func currentFrontmostApp() -> RunningAppSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            VocaLogger.debug(.textInjector, "No frontmost application reported")
            return nil
        }
        // `snapshot(for:)` returns nil for VocaMac itself, which is what we
        // want: when Settings has focus the caller falls back to the snapshot
        // taken when recording started.
        return AppIdentityMatching.snapshot(for: app)
    }
}
