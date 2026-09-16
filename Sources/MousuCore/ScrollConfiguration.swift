/// Cross-thread configuration state. Its owner must serialize updates and consumption.
/// Invalidations accumulate even when several edits return to the original profile.
public struct ScrollConfiguration: Sendable {
    public struct Snapshot: Sendable {
        public let profiles: [UInt64: DeviceProfile]
        public let invalidatedDeviceIDs: Set<UInt64>
        public let resetsAllDevices: Bool

        /// Call on the event thread before using this snapshot for transformation.
        public func applyInvalidations(to transformer: inout ScrollTransformer) {
            if resetsAllDevices {
                transformer.reset()
            } else {
                for deviceID in invalidatedDeviceIDs { transformer.reset(deviceID: deviceID) }
            }
        }
    }

    public private(set) var profiles: [UInt64: DeviceProfile] = [:]
    private var invalidatedDeviceIDs: Set<UInt64> = []
    private var resetsAllDevices = false

    public init() {}

    public mutating func replaceProfiles(_ newProfiles: [UInt64: DeviceProfile]) {
        for deviceID in Set(profiles.keys).union(newProfiles.keys)
        where profiles[deviceID] != newProfiles[deviceID] {
            invalidatedDeviceIDs.insert(deviceID)
        }
        // Remember an all-stop even if control resumes before the worker runs.
        if !profiles.isEmpty && newProfiles.isEmpty { invalidateAll() }
        profiles = newProfiles
    }

    /// No gesture may carry fractions across a lost tap, permission, or other input gap.
    public mutating func invalidateAll() { resetsAllDevices = true }

    public mutating func consume() -> Snapshot {
        let snapshot = Snapshot(
            profiles: profiles, invalidatedDeviceIDs: invalidatedDeviceIDs,
            resetsAllDevices: resetsAllDevices)
        invalidatedDeviceIDs.removeAll(keepingCapacity: true)
        resetsAllDevices = false
        return snapshot
    }
}
