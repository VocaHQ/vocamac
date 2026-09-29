// UndoCenter.swift
// VocaMac
//
// One pending "Undo" for list edits in Settings. Removing a snippet or a rule
// takes effect at once and offers a few seconds to take it back, which is
// lighter than a confirmation dialog on every row.

import Foundation
import Observation

/// Holds the most recent undoable removal and clears it after a short delay.
///
/// Only one removal is undoable at a time: offering a second one commits the
/// first. That keeps the toast a single line and the restore order obvious.
@MainActor
@Observable
final class UndoCenter {
    /// A removal that can still be taken back.
    struct Entry: Identifiable {
        let id = UUID()
        let message: String
        let restore: () -> Void
    }

    /// The removal currently on offer, if any.
    private(set) var current: Entry?

    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    init(duration: Duration = .seconds(6)) {
        self.duration = duration
    }

    /// Offer to take back a change. Replaces any earlier offer.
    func offer(_ message: String, restore: @escaping () -> Void) {
        dismissTask?.cancel()
        let entry = Entry(message: message, restore: restore)
        current = entry
        dismissTask = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.expire(entry.id)
        }
    }

    /// Run the pending restore and clear the offer.
    func undo() {
        guard let entry = current else { return }
        dismiss()
        entry.restore()
    }

    /// Clear the offer without restoring.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }

    private func expire(_ id: Entry.ID) {
        guard current?.id == id else { return }
        current = nil
        dismissTask = nil
    }

    /// Remove the element with `id` from an array property and offer to put it
    /// back at the same position.
    ///
    /// Undo never brings back a stale copy over newer work: if the list gained
    /// an element with the same `id`, or one that `conflictsWith` the removed
    /// element (say, a snippet re-added with the same trigger), the removed
    /// element stays gone.
    ///
    /// Returns whether anything was removed.
    @discardableResult
    func remove<Root: AnyObject, Element: Identifiable>(
        id: Element.ID,
        from keyPath: ReferenceWritableKeyPath<Root, [Element]>,
        of root: Root,
        message: String,
        conflictsWith: @escaping (Element, Element) -> Bool = { _, _ in false }
    ) -> Bool {
        var items = root[keyPath: keyPath]
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let removed = items.remove(at: index)
        root[keyPath: keyPath] = items
        offer(message) { [weak root] in
            guard let root else { return }
            var items = root[keyPath: keyPath]
            guard !Self.isSuperseded(removed, by: items, conflictsWith: conflictsWith) else { return }
            items.insert(removed, at: min(index, items.count))
            root[keyPath: keyPath] = items
        }
        return true
    }

    /// Empty an array property and offer to bring the elements back.
    ///
    /// Elements added since are kept: undo puts the removed ones ahead of them
    /// and skips any that were superseded (see `remove`).
    func removeAll<Root: AnyObject, Element: Identifiable>(
        from keyPath: ReferenceWritableKeyPath<Root, [Element]>,
        of root: Root,
        message: String,
        conflictsWith: @escaping (Element, Element) -> Bool = { _, _ in false },
        afterUndo: @escaping () -> Void = {}
    ) {
        let removed = root[keyPath: keyPath]
        guard !removed.isEmpty else { return }
        root[keyPath: keyPath] = []
        offer(message) { [weak root] in
            guard let root else { return }
            let current = root[keyPath: keyPath]
            let restorable = removed.filter {
                !Self.isSuperseded($0, by: current, conflictsWith: conflictsWith)
            }
            root[keyPath: keyPath] = restorable + current
            afterUndo()
        }
    }

    private static func isSuperseded<Element: Identifiable>(
        _ element: Element,
        by current: [Element],
        conflictsWith: (Element, Element) -> Bool
    ) -> Bool {
        current.contains { $0.id == element.id || conflictsWith($0, element) }
    }
}
