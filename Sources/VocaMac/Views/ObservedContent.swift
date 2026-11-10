// ObservedContent.swift
// VocaMac
//
// Redraws a piece of a view when one of AppState's sub-objects changes,
// without AppState forwarding that change to every view that reads it.

import SwiftUI

/// Draws `content` and draws it again whenever `object` changes. Only this
/// view redraws, not the view around it, so a sub-object that changes often
/// (the update checker during a download) doesn't redraw the whole window.
struct ObservedContent<Object: ObservableObject, Content: View>: View {
    @ObservedObject var object: Object
    @ViewBuilder let content: (Object) -> Content

    var body: some View { content(object) }
}
