import SwiftUI

/// The words recognised so far in a live recording.
///
/// Partial results arrive several times a second. Kept off `AppState` so each
/// one redraws only the text that shows it, not every view observing
/// `AppState` (the whole menu bar panel and any open Settings page).
@MainActor
final class LiveTranscriptState: ObservableObject {
    @Published private(set) var text: String = ""

    func update(_ value: String) {
        guard value != text else { return }
        text = value
    }
}

/// The live transcript in the menu bar panel; empty text shows nothing.
struct ObservedLiveTranscriptView: View {
    @ObservedObject var state: LiveTranscriptState

    var body: some View {
        if !state.text.isEmpty {
            Text(state.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Live transcript")
        }
    }
}
