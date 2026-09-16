/// Event-thread-owned lifecycle decisions, separated from Quartz and permission prompts.
public struct TapRecoveryPolicy: Sendable {
    public enum BlockReason: Equatable, Sendable {
        case tapUnavailable
        case sourceUnavailable
        case repeatedTimeouts
        case userDisabled
    }

    public enum State: Equatable, Sendable {
        case inactive
        case permissionNeeded
        case blocked(BlockReason)
        case active
    }

    private var blockReason: BlockReason?
    private var timeoutTimes: [Double] = []

    public init() {}

    /// An explicit retry resets the circuit breaker, but never bypasses permission or idle state.
    public mutating func desiredState(
        needsTap: Bool, accessibilityGranted: Bool, retry: Bool = false
    ) -> State {
        if retry {
            blockReason = nil
            timeoutTimes.removeAll(keepingCapacity: true)
        }
        guard needsTap else { return .inactive }
        guard accessibilityGranted else { return .permissionNeeded }
        if let blockReason { return .blocked(blockReason) }
        return .active
    }

    /// Re-enable at most three times within a rolling 60-second window.
    /// `now` is monotonic uptime, not wall-clock time; denied or stale callbacks cannot re-enable.
    public mutating func timedOut(
        at now: Double, needsTap: Bool, accessibilityGranted: Bool
    ) -> State {
        let state = desiredState(needsTap: needsTap, accessibilityGranted: accessibilityGranted)
        guard state == .active else { return state }
        timeoutTimes.removeAll { now - $0 >= 60 }
        timeoutTimes.append(now)
        guard timeoutTimes.count <= 3 else { return block(.repeatedTimeouts) }
        return .active
    }

    @discardableResult
    public mutating func block(_ reason: BlockReason) -> State {
        blockReason = reason
        return .blocked(reason)
    }
}
