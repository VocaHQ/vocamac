// ModelKeepAlive.swift
// VocaMac
//
// Unloads the speech model after a configurable idle timeout.
// Mac adapter for VocaLinux model keep-alive / idle unload (#592).

import Foundation

/// Schedules idle unload of the speech model after inactivity.
@MainActor
final class ModelKeepAlive: ObservableObject {

    nonisolated static let defaultIdleTimeoutSeconds: TimeInterval = 300
    nonisolated static let minIdleTimeoutSeconds: TimeInterval = 60
    nonisolated static let maxIdleTimeoutSeconds: TimeInterval = 3600

    /// Re-read on each bump so Settings changes apply without restart.
    var getConfig: () -> (enabled: Bool, idleTimeoutSeconds: TimeInterval)

    /// Called once when the idle timeout elapses and unload is safe.
    var onIdleUnload: (() -> Void)?

    /// Unload only runs when this returns true (idle + not auto-paused + model loaded).
    var isSafeToUnload: () -> Bool

    /// When false, tests drive `fireIfDue()` without a real Timer.
    var useTimer: Bool

    @Published private(set) var isArmed: Bool = false
    private(set) var isRunning: Bool = false

    private var timer: Timer?

    init(
        getConfig: @escaping () -> (enabled: Bool, idleTimeoutSeconds: TimeInterval) = {
            (false, defaultIdleTimeoutSeconds)
        },
        onIdleUnload: (() -> Void)? = nil,
        isSafeToUnload: @escaping () -> Bool = { true },
        useTimer: Bool = true
    ) {
        self.getConfig = getConfig
        self.onIdleUnload = onIdleUnload
        self.isSafeToUnload = isSafeToUnload
        self.useTimer = useTimer
    }

    deinit {
        timer?.invalidate()
    }

    /// Mark the helper as running. Safe to call if already started.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        VocaLogger.info(.general, "Model keep-alive started")
    }

    /// Cancel any pending timer and mark stopped.
    func stop() {
        isRunning = false
        cancel()
        VocaLogger.info(.general, "Model keep-alive stopped")
    }

    /// Reset the idle deadline from now (call when recognition becomes idle).
    func bump() {
        guard isRunning else { return }

        let (enabled, timeout) = readConfig()
        guard enabled else {
            cancel()
            return
        }

        schedule(timeout)
    }

    /// Cancel any pending idle unload (call while recording/processing/auto-paused).
    func cancel() {
        timer?.invalidate()
        timer = nil
        isArmed = false
    }

    /// Manually run the idle unload path (tests / non-timer). Returns true if fired.
    @discardableResult
    func fireIfDue() -> Bool {
        guard isRunning, isArmed else { return false }
        return fireUnload()
    }

    static func clampIdleTimeout(_ seconds: TimeInterval) -> TimeInterval {
        let value = seconds.isFinite ? seconds : defaultIdleTimeoutSeconds
        return min(maxIdleTimeoutSeconds, max(minIdleTimeoutSeconds, value))
    }

    private func readConfig() -> (Bool, TimeInterval) {
        let config = getConfig()
        return (config.enabled, Self.clampIdleTimeout(config.idleTimeoutSeconds))
    }

    private func schedule(_ timeoutSeconds: TimeInterval) {
        cancel()
        isArmed = true

        guard useTimer else { return }

        let delay = max(1, timeoutSeconds)
        let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timer = nil
                _ = self?.fireUnload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @discardableResult
    private func fireUnload() -> Bool {
        guard isRunning else {
            isArmed = false
            return false
        }

        let (enabled, _) = readConfig()
        guard enabled else {
            isArmed = false
            return false
        }

        guard isSafeToUnload() else {
            VocaLogger.debug(.general, "Keep-alive unload skipped: not safe to unload")
            isArmed = false
            return false
        }

        isArmed = false
        VocaLogger.info(.general, "Model keep-alive idle timeout reached: unloading model")
        onIdleUnload?()
        return true
    }
}
