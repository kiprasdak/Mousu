import AppKit
import ApplicationServices
import Foundation
import MousuCore
import MousuNative

struct EventStatistics: Sendable {
    var received = 0
    var transformed = 0
    var unidentified = 0
    var missingRaw = 0
    var timeouts = 0
    var continuousDevices: Set<UInt64> = []
    var rawDevices: Set<UInt64> = []
    var lastSender: UInt64?
    var durations: [Double] = []

    var p99Microseconds: Double {
        guard !durations.isEmpty else { return 0 }
        let sorted = durations.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
    }
}

/// The run loop owns the tap and transformer. Only immutable profile snapshots
/// and small aggregate counters cross the lock; no HID property I/O runs here.
final class EventWorker: @unchecked Sendable {
    private let lock = NSLock()
    private var loop: CFRunLoop?
    private var configuration = ScrollConfiguration()
    private var statusValue = "Inactive"
    private var stats = EventStatistics()
    private var terminate = false
    private var restartAllowed = false

    // Event thread only.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var transformer = ScrollTransformer()
    private var recoveryPolicy = TapRecoveryPolicy()

    init() {
        let thread = Thread { [self] in run() }
        thread.name = "Mousu.ScrollEvents"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    var status: String { lock.withLock { statusValue } }
    var statistics: EventStatistics { lock.withLock { stats } }

    func retainDeviceStatistics(_ active: Set<UInt64>) {
        lock.withLock {
            stats.continuousDevices.formIntersection(active)
            stats.rawDevices.formIntersection(active)
            if let last = stats.lastSender, !active.contains(last) { stats.lastSender = nil }
        }
    }

    func configure(_ newProfiles: [UInt64: DeviceProfile], retry: Bool = false) {
        let runLoop = lock.withLock { () -> CFRunLoop? in
            configuration.replaceProfiles(newProfiles)
            restartAllowed = restartAllowed || retry
            return loop
        }
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in reconcile() }
        CFRunLoopWakeUp(runLoop)
    }

    func shutdown() {
        let runLoop = lock.withLock { () -> CFRunLoop? in
            terminate = true
            configuration.replaceProfiles([:])
            return loop
        }
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(runLoop) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func setStatus(_ value: String) { lock.withLock { statusValue = value } }

    private func run() {
        let current = CFRunLoopGetCurrent()!
        var context = CFRunLoopSourceContext()
        context.perform = { _ in }
        guard let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context) else {
            setStatus("Event loop unavailable")
            return
        }
        CFRunLoopAddSource(current, keepAlive, .commonModes)
        lock.withLock { loop = current }
        reconcile()
        if !lock.withLock({ terminate }) { CFRunLoopRun() }
        removeTap()
        CFRunLoopRemoveSource(current, keepAlive, .commonModes)
        lock.withLock { loop = nil }
    }

    private func reconcile() {
        let snapshot = lock.withLock { () -> (stop: Bool, retry: Bool, scroll: ScrollConfiguration.Snapshot) in
            let retry = restartAllowed
            restartAllowed = false
            return (configuration.profiles.isEmpty || terminate, retry, configuration.consume())
        }
        snapshot.scroll.applyInvalidations(to: &transformer)
        let state = recoveryPolicy.desiredState(
            needsTap: !snapshot.stop, accessibilityGranted: AXIsProcessTrusted(), retry: snapshot.retry)
        guard applyDesiredState(state) else { return }
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let worker = Unmanaged<EventWorker>.fromOpaque(context).takeUnretainedValue()
            return worker.receive(type, event)
        }
        guard
            let created = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            _ = applyDesiredState(recoveryPolicy.block(.tapUnavailable))
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            _ = applyDesiredState(recoveryPolicy.block(.sourceUnavailable))
            return
        }
        tap = created
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        setStatus("Active")
    }

    private func removeTap() {
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), tapSource, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tapSource = nil
        tap = nil
    }

    private func resetAfterInterruption() {
        let snapshot = lock.withLock {
            configuration.invalidateAll()
            return configuration.consume()
        }
        snapshot.applyInvalidations(to: &transformer)
    }

    /// Every non-active decision tears down the tap, including permission revocation.
    private func applyDesiredState(_ state: TapRecoveryPolicy.State) -> Bool {
        guard state != .active else { return true }
        resetAfterInterruption()
        removeTap()
        switch state {
        case .inactive: setStatus("Inactive")
        case .permissionNeeded: setStatus("Accessibility needed")
        case .blocked(.tapUnavailable): setStatus("Scroll tap unavailable — retry in Mousü")
        case .blocked(.sourceUnavailable): setStatus("Scroll source unavailable")
        case .blocked(.repeatedTimeouts): setStatus("Paused after repeated event timeouts")
        case .blocked(.userDisabled): setStatus("macOS disabled scrolling — retry in Mousü")
        case .active: break
        }
        return false
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            // Even an immediately recovered timeout may have dropped part of a gesture.
            resetAfterInterruption()
            lock.withLock { stats.timeouts += 1 }
            let needsTap = lock.withLock { !configuration.profiles.isEmpty && !terminate }
            let state = recoveryPolicy.timedOut(
                at: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000,
                needsTap: needsTap, accessibilityGranted: AXIsProcessTrusted())
            if applyDesiredState(state), let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                setStatus("Active")
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            _ = applyDesiredState(recoveryPolicy.block(.userDisabled))
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000
            lock.withLock {
                if stats.durations.count >= 512 { stats.durations.removeFirst(256) }
                stats.durations.append(duration)
            }
        }
        let source = MousuGetEventSource(event)
        let snapshot = lock.withLock { () -> ScrollConfiguration.Snapshot in
            stats.received += 1
            if source.senderID == 0 { stats.unidentified += 1 }
            return configuration.consume()
        }
        // A callback can run before the configure block queued on this run loop.
        snapshot.applyInvalidations(to: &transformer)
        let currentProfiles = snapshot.profiles
        guard source.senderID != 0, let profile = currentProfiles[source.senderID], profile.enabled else {
            return Unmanaged.passUnretained(event)
        }
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let natural = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        let input = ScrollEvent(
            x: ScrollAxis(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis2),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)),
            y: ScrollAxis(
                line: event.getIntegerValueField(.scrollWheelEventDeltaAxis1),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                point: event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)),
            isContinuous: continuous, isNatural: natural,
            phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
            momentumPhase: event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        )
        lock.withLock {
            stats.lastSender = source.senderID
            if continuous { stats.continuousDevices.insert(source.senderID) }
            if source.hasRawScroll { stats.rawDevices.insert(source.senderID) }
            if !continuous && profile.scrollMode == .fixed && !source.hasRawScroll { stats.missingRaw += 1 }
        }
        // The raw HID parent predates system direction inversion. Match CG signs
        // independently on each axis; do not guess a device from event timing.
        func aligned(_ raw: Double, _ axis: ScrollAxis) -> Double {
            let sign = axis.point != 0 ? Double(axis.point) : (axis.fixed != 0 ? axis.fixed : Double(axis.line))
            if sign != 0 { return abs(raw) * (sign < 0 ? -1 : 1) }
            return raw * (natural ? -1 : 1)
        }
        let output = transformer.transform(
            input, senderID: source.senderID, profiles: currentProfiles,
            rawX: source.hasRawScroll ? aligned(source.rawX, input.x) : nil,
            rawY: source.hasRawScroll ? aligned(source.rawY, input.y) : nil
        )
        guard output != input else { return Unmanaged.passUnretained(event) }
        // Setting integer line deltas changes the other representations in CG.
        // Write fixed and point deltas afterward, preserving phase metadata.
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: output.y.line)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: output.x.line)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: output.y.fixed)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: output.x.fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: output.y.point)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: output.x.point)
        func factor(_ direction: ScrollDirection) -> Double {
            let reversed = direction == .natural ? !natural : (direction == .traditional ? natural : false)
            return profile.scrollSpeed * (reversed ? -1 : 1)
        }
        let fixed = !continuous && profile.scrollMode == .fixed && source.hasRawScroll
        MousuSyncScroll(
            event, fixed, fixed ? output.x.fixed : factor(profile.horizontalDirection),
            fixed ? output.y.fixed : factor(profile.verticalDirection))
        lock.withLock { stats.transformed += 1 }
        return Unmanaged.passUnretained(event)
    }
}
