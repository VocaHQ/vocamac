// ModelUsageLog.swift
// VocaMac
//
// When each downloaded model was last in use, for Settings › Models: the
// On this Mac list shows it, and Free up space offers the models nobody
// has used for a while.

import Foundation

/// A speech or writing model, as one list of downloads shows them.
enum DownloadedModelID: Hashable, Sendable {
    case speech(ModelSize)
    case writing(CleanupModelKind)

    /// The key the usage log stores it under: “speech.parakeet-v3”.
    var storageKey: String {
        switch self {
        case .speech(let size): return "speech.\(size.rawValue)"
        case .writing(let kind): return "writing.\(kind.rawValue)"
        }
    }
}

/// When each model was last in use, kept in UserDefaults.
///
/// A model counts as used while it is loaded, so it is stamped when it
/// loads and again when another model replaces it. Models already on disk
/// before the log existed have no last use; they are stamped as first seen
/// instead, so a model the log never saw is offered for removal only after
/// a full idle period on its watch, never at once.
struct ModelUsageLog {
    struct Entry: Codable, Equatable, Sendable {
        var lastUsed: Date?
        var firstSeen: Date
    }

    /// How long a model sits unused before Free up space offers it.
    static let idleDays = 30

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every entry, by `DownloadedModelID.storageKey`.
    func entries() -> [String: Entry] {
        guard let data = defaults.data(forKey: PreferenceKey.modelUsageLog),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    func entry(for model: DownloadedModelID) -> Entry? {
        entries()[model.storageKey]
    }

    /// Stamp `models` as in use at `date`.
    func markUsed(_ models: [DownloadedModelID], at date: Date = Date()) {
        guard !models.isEmpty else { return }
        var all = entries()
        for model in models {
            all[model.storageKey, default: Entry(lastUsed: nil, firstSeen: date)].lastUsed = date
        }
        save(all)
    }

    /// Start the idle clock for downloaded models the log hasn't seen yet.
    func noteSeen(_ models: [DownloadedModelID], at date: Date = Date()) {
        var all = entries()
        let unseen = models.filter { all[$0.storageKey] == nil }
        guard !unseen.isEmpty else { return }
        for model in unseen {
            all[model.storageKey] = Entry(lastUsed: nil, firstSeen: date)
        }
        save(all)
    }

    /// Drop a removed model, so a later download starts a fresh clock.
    func forget(_ model: DownloadedModelID) {
        var all = entries()
        guard all.removeValue(forKey: model.storageKey) != nil else { return }
        save(all)
    }

    /// Whether a model has gone `idleDays` without use, counting from its
    /// last use or, never used, from when the log first saw it. A model the
    /// log has no entry for is never idle: when unsure, keep it.
    static func isIdle(_ entry: Entry?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let entry else { return false }
        let since = entry.lastUsed ?? entry.firstSeen
        let days = calendar.dateComponents([.day], from: since, to: now).day ?? 0
        return days >= idleDays
    }

    private func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: PreferenceKey.modelUsageLog)
    }
}
