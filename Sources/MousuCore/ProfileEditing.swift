extension DeviceProfile {
    /// Stored slider presets do not change input while their mode is System.
    public var hasCustomInputSettings: Bool {
        pointerMode == .flat || scrollMode == .fixed || scrollSpeed != 1
            || verticalDirection != .system || horizontalDirection != .system
    }

    public var isDevicePaused: Bool { hasCustomInputSettings && !enabled }

    /// Editing is the user's instruction to apply a setting. Explicit pauses
    /// require Resume; rename and no-op edits never activate device control.
    public func applyingInputEdit(_ draft: Self, globallyPaused: Bool) -> Self {
        guard !globallyPaused, !isDevicePaused else { return self }
        var result = draft.normalized()
        if result.directionsLinked {
            if !directionsLinked || result.verticalDirection != verticalDirection {
                result.horizontalDirection = result.verticalDirection
            } else if result.horizontalDirection != horizontalDirection {
                result.verticalDirection = result.horizontalDirection
            }
        }
        var oldInput = normalized()
        var newInput = result
        oldInput.name = ""
        newInput.name = ""
        oldInput.enabled = false
        newInput.enabled = false
        // Linking itself is only an editing preference, not an input change.
        oldInput.directionsLinked = false
        newInput.directionsLinked = false
        result.enabled = oldInput != newInput ? true : enabled
        return result
    }
}
