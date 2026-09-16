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
