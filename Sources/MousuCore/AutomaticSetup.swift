extension DeviceProfile {
    /// Capability checks preserve touch scrolling and absolute pointer behavior.
    public static func automaticDefaults(for capabilities: DeviceCapabilities) -> Self {
        var profile = Self(
            pointerMode: capabilities.supportsFlat ? .flat : .system,
            scrollMode: capabilities.supportsScroll && !capabilities.isContinuous ? .fixed : .system,
            verticalDirection: capabilities.supportsScroll ? .traditional : .system,
            horizontalDirection: capabilities.supportsScroll ? .traditional : .system
        )
        profile.enabled = profile.hasCustomInputSettings
        return profile
    }
}

extension Preferences {
    /// Discovery supplies only external pointers. Seed a connection's profile once;
    /// a saved System choice or pause is just as deliberate as a custom setting.
    @discardableResult
    public mutating func prepareAutomaticProfiles(for devices: [DeviceInfo]) -> Bool {
        guard hasCompletedSetup, automaticallySetUpDevices else { return false }
        var changed = false
        for device in devices
        where profiles[device.identity.key] == nil && isDeviceManaged(device.identity.key)
            && matchingModelProfiles(device.model.fingerprint).isEmpty
            && !individualProfileKeys.contains(device.identity.key)
        {
            profiles[device.identity.key] = .automaticDefaults(for: device.capabilities)
            changed = true
        }
        return changed
    }
}
