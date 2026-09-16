import Foundation

public struct ScrollAxis: Equatable, Sendable {
    public var line: Int64
    public var fixed: Double
    public var point: Int64

    public init(line: Int64 = 0, fixed: Double = 0, point: Int64 = 0) {
        self.line = line
        self.fixed = fixed
        self.point = point
    }
}

/// A value representation of scroll fields; native code edits only returned delta fields.
public struct ScrollEvent: Equatable, Sendable {
    public var x: ScrollAxis
    public var y: ScrollAxis
    public var isContinuous: Bool
    public var isNatural: Bool
    public var phase: Int64
    public var momentumPhase: Int64

    public init(
        x: ScrollAxis = ScrollAxis(), y: ScrollAxis = ScrollAxis(),
        isContinuous: Bool = false, isNatural: Bool = false,
        phase: Int64 = 0, momentumPhase: Int64 = 0
    ) {
        self.x = x
        self.y = y
        self.isContinuous = isContinuous
        self.isNatural = isNatural
        self.phase = phase
        self.momentumPhase = momentumPhase
    }
}

/// Owned by the event-processing thread. It performs no I/O and takes no locks.
public struct ScrollTransformer: Sendable {
    public static let pointsPerLine: Double = 10

    private struct AxisState: Sendable {
        var rawRemainder: Double = 0
        var lineRemainder: Double = 0
        var pointRemainder: Double = 0
    }

    private struct DeviceState: Sendable {
        var profile: DeviceProfile
        var continuous: Bool
        var natural: Bool
        var x = AxisState()
        var y = AxisState()
    }

    private var states: [UInt64: DeviceState] = [:]

    public init() {}

    public mutating func reset(deviceID: UInt64? = nil) {
        if let deviceID {
            states.removeValue(forKey: deviceID)
        } else {
            states.removeAll(keepingCapacity: true)
        }
    }

    /// `rawX` and `rawY` are unaccelerated HID wheel counts already aligned to CGEvent signs.
    /// Fixed mode requires both raw axes to be authenticated to this exact event, including zeros.
    /// Unknown, disabled and untrusted senders always pass through unchanged.
    public mutating func transform(
        _ event: ScrollEvent, senderID: UInt64?, profiles: [UInt64: DeviceProfile],
        rawX: Double? = nil, rawY: Double? = nil
    ) -> ScrollEvent {
        guard let senderID, let storedProfile = profiles[senderID], storedProfile.enabled else {
            if let senderID { states.removeValue(forKey: senderID) }
            return event
        }
        let profile = storedProfile.normalized()
        guard event.x.fixed.isFinite, event.y.fixed.isFinite else {
            states.removeValue(forKey: senderID)
            return event
        }
        let fixed = profile.scrollMode == .fixed && !event.isContinuous
        if fixed && (rawX == nil || rawY == nil || rawX?.isFinite != true || rawY?.isFinite != true) {
            states.removeValue(forKey: senderID)
            return event
        }
        var state: DeviceState
        if let previous = states[senderID], previous.profile == profile,
            previous.continuous == event.isContinuous, previous.natural == event.isNatural
        {
            state = previous
        } else {
            state = DeviceState(profile: profile, continuous: event.isContinuous, natural: event.isNatural)
        }
        // A new touch gesture must not inherit rounding fractions from an earlier gesture.
        if event.isContinuous && event.phase & 1 != 0 {
            state.x = AxisState()
            state.y = AxisState()
        }
        let xFactor = directionFactor(profile.horizontalDirection, isNatural: event.isNatural)
        let yFactor = directionFactor(profile.verticalDirection, isNatural: event.isNatural)
        var result = event
        let x: ScrollAxis?
        let y: ScrollAxis?
        if fixed, let rawX, let rawY {
            x = fixedAxis(rawX, factor: xFactor, linesPerStep: profile.linesPerStep, state: &state.x)
            y = fixedAxis(rawY, factor: yFactor, linesPerStep: profile.linesPerStep, state: &state.y)
        } else {
            x = scaledAxis(event.x, factor: xFactor * profile.scrollSpeed, state: &state.x)
            y = scaledAxis(event.y, factor: yFactor * profile.scrollSpeed, state: &state.y)
        }
        guard let x, let y else {
            states.removeValue(forKey: senderID)
            return event
        }
        result.x = x
        result.y = y
        states[senderID] = state
        return result
    }

    private func directionFactor(_ direction: ScrollDirection, isNatural: Bool) -> Double {
        switch direction {
        case .system: 1
        case .natural: isNatural ? 1 : -1
        case .traditional: isNatural ? -1 : 1
        }
    }

    private func fixedAxis(
        _ raw: Double, factor: Double, linesPerStep: Double, state: inout AxisState
    ) -> ScrollAxis? {
        let total = raw + state.rawRemainder
        guard total.isFinite else { return nil }
        let steps = total.rounded(.towardZero)
        state.rawRemainder = total - steps
        let fixed = steps * linesPerStep * factor
        guard let line = quantize(fixed, remainder: &state.lineRemainder),
            let point = quantize(fixed * Self.pointsPerLine, remainder: &state.pointRemainder)
        else { return nil }
        return ScrollAxis(line: line, fixed: fixed, point: point)
    }

    private func scaledAxis(_ axis: ScrollAxis, factor: Double, state: inout AxisState) -> ScrollAxis? {
        // Avoid converting integers through Double for the overwhelmingly common identity path.
        guard factor != 1 else { return axis }
        let fixed = axis.fixed * factor
        guard fixed.isFinite,
            let line = quantize(Double(axis.line) * factor, remainder: &state.lineRemainder),
            let point = quantize(Double(axis.point) * factor, remainder: &state.pointRemainder)
        else { return nil }
        return ScrollAxis(line: line, fixed: fixed, point: point)
    }

    private func quantize(_ value: Double, remainder: inout Double) -> Int64? {
        let accumulated = value + remainder
        let integral = accumulated.rounded(.towardZero)
        guard integral.isFinite, integral >= Double(Int64.min), integral < Double(Int64.max) else {
            return nil
        }
        remainder = accumulated - integral
        return Int64(integral)
    }
}
