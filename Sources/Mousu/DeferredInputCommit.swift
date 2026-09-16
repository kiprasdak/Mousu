import Foundation

/// Publish edits immediately; batch disk and hardware work once rapid input settles.
@MainActor
final class DeferredInputCommit {
    private var task: Task<Void, Never>?
    private var pending: (() -> Void)?

    func schedule(_ action: @escaping () -> Void) {
        task?.cancel()
        pending = action
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        let action = pending
        pending = nil
        action?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
