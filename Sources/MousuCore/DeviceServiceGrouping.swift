/// Registry ancestry is evidence for a physical connection, never a durable profile identity.
public struct PointerServiceIdentity: Sendable {
    public var candidate: DeviceIdentityCandidate
    public var physicalDeviceID: UInt64?
    public var usbDeviceID: UInt64?
    public var isTouchpad: Bool

    public init(
        candidate: DeviceIdentityCandidate, physicalDeviceID: UInt64? = nil, usbDeviceID: UInt64? = nil,
        isTouchpad: Bool = false
    ) {
        self.candidate = candidate
        self.physicalDeviceID = physicalDeviceID
        self.usbDeviceID = usbDeviceID
        self.isTouchpad = isTouchpad
    }
}

public struct DeviceServiceGroup: Sendable, Equatable {
    public var candidate: DeviceIdentityCandidate
    public var serviceIDs: [UInt64]
}

public enum DeviceServiceGrouping {
    /// A composite USB mouse can publish several pointer interfaces. They share
    /// one USB device ancestor. Different physical devices, or contradictory
    /// identity evidence beneath a receiver, must remain separate.
    public static func groups(_ services: [PointerServiceIdentity]) -> [DeviceServiceGroup] {
        let connections = Dictionary(grouping: services) { service in
            if DeviceTransport(hidValue: service.candidate.transport) == .usb, let usb = service.usbDeviceID, usb != 0 {
                return "usb:\(usb)"
            }
            if let physical = service.physicalDeviceID, physical != 0 {
                return "hid:\(physical)"
            }
            return "service:\(service.candidate.registryID)"
        }
        return connections.values.flatMap { members -> [DeviceServiceGroup] in
            let ordered = members.sorted { $0.candidate.registryID < $1.candidate.registryID }
            let keys = Set(ordered.map { $0.candidate.stableKey })
            let vendors = Set(ordered.map { $0.candidate.vendorID })
            let products = Set(ordered.map { $0.candidate.productID })
            let transports = Set(ordered.map { $0.candidate.transport })
            let functions = Set(ordered.map(\.isTouchpad))
            guard keys.count == 1, vendors.count == 1, products.count == 1, transports.count == 1, functions.count == 1,
                let first = ordered.first
            else {
                return ordered.map {
                    DeviceServiceGroup(candidate: $0.candidate, serviceIDs: [$0.candidate.registryID])
                }
            }
            return [DeviceServiceGroup(candidate: first.candidate, serviceIDs: ordered.map { $0.candidate.registryID })]
        }.sorted { $0.candidate.registryID < $1.candidate.registryID }
    }

    /// Event routing uses every sender ID, even though the UI presents one device.
    public static func routedProfiles(devices: [DeviceInfo], profilesByDevice: [UInt64: DeviceProfile]) -> [UInt64:
        DeviceProfile]
    {
        var result: [UInt64: DeviceProfile] = [:]
        for device in devices {
            guard let profile = profilesByDevice[device.id] else { continue }
            for service in device.serviceIDs { result[service] = profile }
        }
        return result
    }
}
