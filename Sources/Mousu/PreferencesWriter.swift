import Foundation
import MousuCore

/// Serializes durable writes off the UI thread and keeps only the newest waiting snapshot.
/// The recovery journal remains synchronous: this queue owns only user preferences.
final class PreferencesWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mousu.Preferences", qos: .utility)
    private let lock = NSLock()
    private let save: @Sendable (Preferences) throws -> Void
    private let onFailure: @Sendable (String) -> Void
    private var pending: Preferences?
    private var draining = false
    private var failure: String?

    init(
        store: PreferencesStore,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.save = { try store.save($0) }
        self.onFailure = onFailure
    }

    init(
        save: @escaping @Sendable (Preferences) throws -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.save = save
        self.onFailure = onFailure
    }

    func submit(_ preferences: Preferences) {
        let start = lock.withLock {
            guard failure == nil else { return false }
            pending = preferences
            guard !draining else { return false }
            draining = true
            return true
        }
        if start { queue.async { self.drain() } }
    }

    /// Used at normal shutdown, before releasing the single-instance lock.
    @discardableResult
    func flush() -> String? {
        queue.sync {}
        return lock.withLock { failure }
    }

    /// Retry the current in-memory settings after a failure. Clearing the failure
    /// is conditional on a successful durable write, never just a readable file.
    func retry(_ preferences: Preferences) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.lock.withLock({ self.failure != nil }) else {
                    continuation.resume(returning: nil)
                    return
                }
                let message: String?
                do {
                    try self.save(preferences)
                    message = nil
                } catch {
                    message = error.localizedDescription
                }
                self.lock.withLock { self.failure = message }
                continuation.resume(returning: message)
            }
        }
    }

    /// Startup recovery uses the same queue so shutdown waits for it before
    /// releasing the single-instance lock, just as it does for ordinary writes.
    func reload(from store: PreferencesStore) async throws -> Preferences {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let preferences = try store.load()
                    try self.save(preferences)
                    self.lock.withLock { self.failure = nil }
                    continuation.resume(returning: preferences)
                } catch {
                    self.lock.withLock { self.failure = error.localizedDescription }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func drain() {
        while let snapshot = lock.withLock({ () -> Preferences? in
            guard let next = pending else {
                draining = false
                return nil
            }
            pending = nil
            return next
        }) {
            do { try save(snapshot) } catch {
                let message = error.localizedDescription
                lock.withLock {
                    failure = message
                    pending = nil
                    draining = false
                }
                onFailure(message)
                return
            }
        }
    }
}
