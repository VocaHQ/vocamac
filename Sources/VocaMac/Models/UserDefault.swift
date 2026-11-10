// UserDefault.swift
// VocaMac
//
// A UserDefaults-backed setting on an ObservableObject that publishes only
// when its own value changes.
//
// SwiftUI's `@AppStorage` inside an `ObservableObject` sends the object's
// `objectWillChange` whenever *any* key in UserDefaults changes, once per
// `@AppStorage` property. `AppState` has about seventy of them, so every
// defaults write anywhere in the app (the window remembering its page or
// frame, a tip being dismissed, the update checker's cache) sent seventy
// changes and redrew every view that reads `AppState`. This wrapper stores
// values the same way `@AppStorage` does, so existing settings read back
// unchanged, but compares its own value before publishing.

import Combine
import Foundation

// MARK: - Stored values

/// A value `@UserDefault` can store, in the same format `@AppStorage` uses.
protocol UserDefaultValue: Equatable {
    /// The stored value, or nil when there is none (or it has the wrong type).
    static func read(from store: UserDefaults, key: String) -> Self?
    /// Store the value.
    func write(to store: UserDefaults, key: String)
}

extension Bool: UserDefaultValue {
    static func read(from store: UserDefaults, key: String) -> Bool? { store.object(forKey: key) as? Bool }
    func write(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension Int: UserDefaultValue {
    static func read(from store: UserDefaults, key: String) -> Int? { store.object(forKey: key) as? Int }
    func write(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension Double: UserDefaultValue {
    static func read(from store: UserDefaults, key: String) -> Double? { store.object(forKey: key) as? Double }
    func write(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension String: UserDefaultValue {
    static func read(from store: UserDefaults, key: String) -> String? { store.object(forKey: key) as? String }
    func write(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension Optional: UserDefaultValue where Wrapped: UserDefaultValue {
    /// `.some(nil)` never comes back: a missing value reads as nil, which
    /// falls back to the default (itself nil for an optional setting).
    static func read(from store: UserDefaults, key: String) -> Wrapped?? {
        Wrapped.read(from: store, key: key).map { .some($0) }
    }

    func write(to store: UserDefaults, key: String) {
        if let self { self.write(to: store, key: key) } else { store.removeObject(forKey: key) }
    }
}

/// Enums and option sets are stored by raw value, as `@AppStorage` does.
protocol RawUserDefaultValue: UserDefaultValue, RawRepresentable where RawValue: UserDefaultValue {}

extension RawUserDefaultValue {
    static func read(from store: UserDefaults, key: String) -> Self? {
        RawValue.read(from: store, key: key).flatMap(Self.init(rawValue:))
    }

    func write(to store: UserDefaults, key: String) { rawValue.write(to: store, key: key) }
}

extension ActivationMode: RawUserDefaultValue {}
extension HotKeyModifiers: RawUserDefaultValue {}
extension DictationTone: RawUserDefaultValue {}
extension OverlayStyle: RawUserDefaultValue {}
extension OverlayPosition: RawUserDefaultValue {}
extension WritingStyle: RawUserDefaultValue {}
extension WritingIntent: RawUserDefaultValue {}
extension CleanupLevel: RawUserDefaultValue {}
extension HistoryRetention: RawUserDefaultValue {}
extension CommandReviewMode: RawUserDefaultValue {}
extension LearnCorrectionsMode: RawUserDefaultValue {}

// MARK: - Property wrapper

/// An object whose `@UserDefault` settings live somewhere other than the
/// store each setting was declared with. AppState gives its tests their own
/// store this way, so runs in parallel (or in other checkouts) can't read
/// each other's settings.
@MainActor
protocol UserDefaultsStoreProviding: AnyObject {
    var userDefaultsStore: UserDefaults { get }
}

/// A setting stored in UserDefaults on an `ObservableObject`. Setting it
/// publishes the object's change; so does a write to its key from anywhere
/// else (another view's `@AppStorage`, a settings import), but only when
/// the value actually differs.
///
/// ```swift
/// @UserDefault(PreferenceKey.historyEnabled) var historyEnabled: Bool = true
/// ```
@MainActor
@propertyWrapper
struct UserDefault<Value: UserDefaultValue> {
    private let key: String
    private let watcher: UserDefaultWatcher<Value>

    /// `store` is used unless the owner provides its own
    /// (`UserDefaultsStoreProviding`).
    init(wrappedValue: Value, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.watcher = UserDefaultWatcher(key: key, defaultValue: wrappedValue, store: store)
    }

    /// An optional setting with no default.
    init<Wrapped>(_ key: String, store: UserDefaults = .standard) where Value == Wrapped? {
        self.init(wrappedValue: nil, key, store: store)
    }

    static subscript<Instance: ObservableObject>(
        _enclosingInstance instance: Instance,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<Instance, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<Instance, Self>
    ) -> Value where Instance.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.watcher.resolveStore(for: instance)
            wrapper.watcher.watch(for: instance.objectWillChange)
            return wrapper.watcher.current()
        }
        set {
            let wrapper = instance[keyPath: storageKeyPath]
            let store = wrapper.watcher.resolveStore(for: instance)
            wrapper.watcher.watch(for: instance.objectWillChange)
            instance.objectWillChange.send()
            // Remembered before the write, so the change notification the
            // write posts doesn't publish a second time.
            wrapper.watcher.remember(newValue)
            newValue.write(to: store, key: wrapper.key)
        }
    }

    @available(*, unavailable, message: "@UserDefault is only for properties of an ObservableObject class")
    var wrappedValue: Value {
        get { fatalError("@UserDefault is only for properties of an ObservableObject class") }
        // Never called (the subscript above is used instead), but a settable
        // property needs a settable `wrappedValue` to exist.
        // swiftlint:disable:next unused_setter_value
        set { fatalError("@UserDefault is only for properties of an ObservableObject class") }
    }
}

/// Watches one key for writes made elsewhere and publishes the owner's
/// change when its value differs from the last one seen.
@MainActor
final class UserDefaultWatcher<Value: UserDefaultValue> {
    private let key: String
    private let defaultValue: Value
    /// The store the setting was declared with, until `resolveStore(for:)`
    /// settles on the owner's.
    private var store: UserDefaults
    private var isStoreResolved = false
    /// The value last read or written, to tell a real change from a write
    /// to some other key.
    private var lastSeen: Value?
    private weak var publisher: ObservableObjectPublisher?
    /// Set once on the main actor in `watch(for:)` and only read again in
    /// `deinit`, when nothing else can reach this object.
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init(key: String, defaultValue: Value, store: UserDefaults) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
    }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    /// Settle once on the store to use: the owner's own, when it provides
    /// one, otherwise the declared store. Always before watching, so the
    /// watch is on the right store.
    @discardableResult
    func resolveStore(for owner: AnyObject) -> UserDefaults {
        if !isStoreResolved {
            isStoreResolved = true
            if let provider = owner as? UserDefaultsStoreProviding {
                store = provider.userDefaultsStore
            }
        }
        return store
    }

    /// The stored value, or the default.
    func current() -> Value {
        let value = Value.read(from: store, key: key) ?? defaultValue
        lastSeen = value
        return value
    }

    func remember(_ value: Value) {
        lastSeen = value
    }

    /// Start publishing `publisher` when the key changes. Only a value that
    /// has been read needs watching: until then nothing depends on it.
    func watch(for publisher: ObservableObjectPublisher) {
        guard token == nil else { return }
        self.publisher = publisher
        // Delivered on the main queue: settings are read on the main actor,
        // and a write from another thread is noticed there.
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.storeDidChange() }
        }
    }

    private func storeDidChange() {
        let value = Value.read(from: store, key: key) ?? defaultValue
        guard value != lastSeen else { return }
        lastSeen = value
        publisher?.send()
    }
}
