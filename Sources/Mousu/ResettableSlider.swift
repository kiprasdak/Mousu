import AppKit
import QuartzCore
import SwiftUI

/// Preserve native Liquid Glass tracking with immediate reset and stepped wheel adjustments.
@MainActor
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var quantize: (Double) -> Double = { $0 }
    /// Commits a semantic value step and returns its native thumb position.
    var onWheelStep: ((Int) -> Double)?
    var onTrackingChanged: (Bool) -> Void = { _ in }
    var onReset: (() -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> SliderHostView { SliderHostView() }

    func updateNSView(_ host: SliderHostView, context: Context) {
        let slider = host.slider
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        slider.quantize = quantize
        slider.onWheelStep = onWheelStep
        slider.defaultValue = defaultValue
        slider.isEnabled = isEnabled
        slider.synchronize(value)
        slider.onTrackingChanged = onTrackingChanged
        slider.commit = { proposed, immediate in
            var transaction = Transaction(animation: nil)
            // Reset is immediate; native thumb press and release effects remain AppKit-owned.
            transaction.disablesAnimations = immediate
            withTransaction(transaction) {
                if immediate, let onReset { onReset() } else { value = proposed }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SliderHostView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: nsView.slider.intrinsicContentSize.height)
    }
}

/// Keep SwiftUI's representable stable while discarding native presentation state on reset.
@MainActor
final class SliderHostView: NSView {
    private(set) var slider = ResettableSliderControl()

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure(slider)
        addSubview(slider)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ control: ResettableSliderControl) {
        control.frame = bounds
        control.autoresizingMask = [.width, .height]
        control.controlSize = .small
        control.isContinuous = true
        control.target = control
        control.action = #selector(ResettableSliderControl.valueChanged)
        control.onResetVisual = { [weak self] in self?.replaceResetControl() }
    }

    private func replaceResetControl() {
        let previous = slider
        let replacement = ResettableSliderControl()
        configure(replacement)
        replacement.minValue = previous.minValue
        replacement.maxValue = previous.maxValue
        replacement.defaultValue = previous.defaultValue
        replacement.doubleValue = previous.defaultValue
        replacement.isEnabled = previous.isEnabled
        replacement.quantize = previous.quantize
        replacement.onWheelStep = previous.onWheelStep
        replacement.commit = previous.commit
        replacement.onTrackingChanged = previous.onTrackingChanged
        replacement.setAccessibilityLabel(previous.accessibilityLabel())
        replacement.setAccessibilityHelp(previous.accessibilityHelp())
        let hadFocus = window?.firstResponder === previous
        slider = replacement
        replaceSubview(previous, with: replacement)
        previous.commit = nil
        previous.onWheelStep = nil
        previous.onTrackingChanged = nil
        previous.onResetVisual = nil
        previous.target = nil
        if hadFocus { window?.makeFirstResponder(replacement) }
        needsDisplay = true
    }
}

@MainActor
final class ResettableSliderControl: NSSlider {
    var quantize: (Double) -> Double = { $0 }
    var onWheelStep: ((Int) -> Double)?
    private var preciseWheelRemainder = 0.0
    private var lastWheelTimestamp: TimeInterval?
    var defaultValue = 1.0
    var commit: ((Double, Bool) -> Void)?
    private(set) var isTrackingPointer = false
    var onTrackingChanged: ((Bool) -> Void)?
    var onResetVisual: (() -> Void)?

    func beginTracking() {
        guard !isTrackingPointer else { return }
        isTrackingPointer = true
        onTrackingChanged?(true)
    }

    func endTracking() {
        guard isTrackingPointer else { return }
        // Keep native tracking ownership until the final local value has been published.
        onTrackingChanged?(false)
        isTrackingPointer = false
    }

    func synchronize(_ value: Double) {
        // The pointer owns its thumb until mouse-up. Quantized SwiftUI echoes must not pull it backwards.
        guard !isTrackingPointer, doubleValue != value else { return }
        setPositionImmediately(value)
    }

    @objc func valueChanged() {
        guard isEnabled else { return }
        // Snap the native thumb itself, not just the value SwiftUI displays.
        let snapped = quantize(doubleValue)
        if snapped != doubleValue { setPositionImmediately(snapped) }
        commit?(doubleValue, false)
    }

    func resetToDefault() {
        guard isEnabled else { return }
        setPositionImmediately(defaultValue)
        commit?(defaultValue, true)
        onResetVisual?()
    }

    private func setPositionImmediately(_ position: Double) {
        // Position is input feedback, not a transition. Keep this scope separate from
        // native mouse tracking so the glass press/release effect still animates.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            doubleValue = position
            // The modern slider owns separate native component views. Invalidating
            // the outer view alone can leave its glass thumb at the old position
            // until window activation updates the cell. Refresh that cell now.
            if let cell { updateCell(cell) }
            needsLayout = true
            layoutSubtreeIfNeeded()
            needsDisplay = true
            displayIfNeeded()
        }
        CATransaction.commit()
    }

    func jumpToTrackPoint(_ point: NSPoint) {
        let thumb = currentThumbRect
        let travel = bounds.width - thumb.width
        guard travel > 0 else { return }
        let fraction = min(1, max(0, (point.x - bounds.minX - thumb.width / 2) / travel))
        setPositionImmediately(quantize(minValue + fraction * (maxValue - minValue)))
        commit?(doubleValue, false)
    }

    var currentThumbRect: NSRect {
        guard let sliderCell = cell as? NSSliderCell else { return .zero }
        var knob = sliderCell.knobRect(flipped: isFlipped)
        // AppKit can retain the last-drawn knob origin after doubleValue changes.
        // Preserve native sizing, but derive its current hit position from the live value.
        let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
        knob.origin.x = bounds.minX + max(0, bounds.width - knob.width) * fraction
        return knob
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, let onWheelStep else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        guard !isTrackingPointer, event.momentumPhase.isEmpty else { return }
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        guard delta.isFinite, delta != 0 else { return }
        let steps: Int
        if event.hasPreciseScrollingDeltas {
            // High-resolution wheels/trackpads need accumulated travel, not one
            // setting change for every tiny pixel event. Never continue on momentum.
            if event.phase.contains(.began)
                || lastWheelTimestamp.map({ event.timestamp - $0 > 0.25 }) != false
                || preciseWheelRemainder * delta < 0
            {
                preciseWheelRemainder = 0
            }
            preciseWheelRemainder += delta
            steps = Int(preciseWheelRemainder / 10)
            preciseWheelRemainder -= Double(steps) * 10
        } else {
            // Mouse scroll-line settings and acceleration must not multiply the
            // slider increment. Each wheel event advances one existing value step.
            preciseWheelRemainder = 0
            steps = delta > 0 ? 1 : -1
        }
        lastWheelTimestamp = event.timestamp
        guard steps != 0 else { return }
        let proposed = onWheelStep(steps)
        guard proposed.isFinite else { return }
        let position = min(maxValue, max(minValue, proposed))
        guard position != doubleValue else { return }
        setPositionImmediately(position)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let onThumb = currentThumbRect.insetBy(dx: -2, dy: -2).contains(point)
        if onThumb, event.clickCount >= 2, event.clickCount.isMultiple(of: 2) {
            resetToDefault()
            return
        }
        beginTracking()
        defer { endTracking() }
        if !onThumb {
            // Put the thumb under the pointer before native tracking begins. This
            // avoids AppKit's animated travel from the old value on a track click.
            jumpToTrackPoint(point)
        }
        // AppKit owns the glass thumb, press/drag animation, and normal focus behavior.
        // Do not force first responder or replace its mouseDragged/mouseUp handling.
        super.mouseDown(with: event)
    }
}
