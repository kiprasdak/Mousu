import Foundation

public struct DeviceIconAppearance: Codable, Equatable, Sendable {
    public var shape: String
    public var color: String

    public init(shape: String = "automatic", color: String = "automatic") {
        self.shape = shape
        self.color = color
    }
}

/// Display metadata and user choices survive disconnects; live service IDs never do.
/// A nonpersistent identity is history of one connection, not a reconnection hint.
public struct RememberedDevice: Codable, Equatable, Identifiable, Sendable {
    public var identity: DeviceIdentity
    public var id: String { identity.key }
    public var name: String
    public var transport: String
    public var kind: DeviceKind
    public var capabilities: DeviceCapabilities
    public var isManaged: Bool
    public var isHidden: Bool
    public var iconAppearance: DeviceIconAppearance?
    public var isPinned: Bool
    public var model: DeviceModelMetadata?
    public var connectionTypeOverride: DeviceConnectionType?

    public init(
        identity: DeviceIdentity, name: String, transport: String,
        kind: DeviceKind, capabilities: DeviceCapabilities,
        isManaged: Bool = true, isHidden: Bool = false, isPinned: Bool = false,
        model: DeviceModelMetadata? = nil
    ) {
        self.identity = identity
        self.name = String(name.prefix(120))
        self.transport = transport
        self.kind = kind
        self.capabilities = capabilities
        self.isManaged = isManaged && !isHidden
        self.isHidden = isHidden
        self.isPinned = isPinned
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case identity, name, transport, kind, capabilities, isManaged, isHidden, isPinned, iconAppearance, model
        case connectionTypeOverride
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identity: try container.decode(DeviceIdentity.self, forKey: .identity),
            name: try container.decode(String.self, forKey: .name),
            transport: try container.decode(String.self, forKey: .transport),
            kind: try container.decode(DeviceKind.self, forKey: .kind),
            capabilities: try container.decode(DeviceCapabilities.self, forKey: .capabilities),
            isManaged: try container.decodeIfPresent(Bool.self, forKey: .isManaged) ?? true,
            isHidden: try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false,
            isPinned: try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false,
            model: try container.decodeIfPresent(DeviceModelMetadata.self, forKey: .model)
        )
        iconAppearance = try container.decodeIfPresent(DeviceIconAppearance.self, forKey: .iconAppearance)
        connectionTypeOverride = try container.decodeIfPresent(
            DeviceConnectionType.self, forKey: .connectionTypeOverride)
    }
}

extension Preferences {
    /// Version one saved settings but no discovery metadata. Preserve those devices
    /// as disconnected entries until an exact durable identity supplies the facts.
    mutating func rememberLegacyProfiles() {
        for key in profiles.keys.sorted() where key.hasPrefix("hid:") && deviceCatalog[key] == nil {
            let name = profiles[key]?.name ?? ""
            deviceCatalog[key] = RememberedDevice(
                identity: .init(key: key, persistent: true),
                name: name.isEmpty ? "Saved pointer device" : name, transport: "",
                kind: .other, capabilities: .init()
            )
            deviceOrder.append(key)
        }
        normalizeDeviceCatalog()
    }

    /// Remember exact identities only. Never infer a device from its name or model.
    @discardableResult
    public mutating func rememberDevices(_ devices: [DeviceInfo]) -> Bool {
        let previousCatalog = deviceCatalog
        let previousOrder = deviceOrder
        normalizeDeviceCatalog()
        for device in devices where !device.identity.key.isEmpty {
            let key = device.identity.key
            let profileName = profiles[key]?.name ?? ""
            var record =
                deviceCatalog[key]
                ?? RememberedDevice(
                    identity: device.identity, name: device.name, transport: device.transport,
                    kind: device.kind, capabilities: device.capabilities
                )
            record.identity = device.identity
            // A retained matching card owns its display name independently of
            // whichever physical connection originally supplied its anchor.
            if modelCardProfile(for: key) == nil {
                record.name = String((profileName.isEmpty ? device.name : profileName).prefix(120))
            }
            record.transport = device.transport
            record.kind = device.kind
            record.capabilities = device.capabilities
            record.model = device.model
            if deviceCatalog[key] == nil { deviceOrder.append(key) }
            deviceCatalog[key] = record
        }
        return deviceCatalog != previousCatalog || deviceOrder != previousOrder
    }

    public func orderedDevices(includeHidden: Bool = false) -> [RememberedDevice] {
        var normalized = self
        normalized.normalizeDeviceCatalog()
        let records = normalized.deviceOrder.compactMap { normalized.deviceCatalog[$0] }
            .filter { includeHidden || !$0.isHidden }
        return records.filter(\.isPinned) + records.filter { !$0.isPinned }
    }

    public func isDeviceManaged(_ key: String) -> Bool {
        guard let record = deviceCatalog[key] else { return true }
        guard record.isManaged && !record.isHidden else { return false }
        if case .model(let id) = resolvedProfile(for: record, includingArchive: false).source,
            let cardKey = modelProfiles[id]?.cardKey, let card = deviceCatalog[cardKey]
        {
            return card.isManaged && !card.isHidden
        }
        return true
    }

    @discardableResult
    public mutating func setDeviceHiddenAndUnmanaged(_ key: String) -> Bool {
        guard var record = deviceCatalog[key], !record.isHidden || record.isManaged else { return false }
        record.isHidden = true
        record.isManaged = false
        deviceCatalog[key] = record
        return true
    }

    /// Restore visibility and management without replacing the user's saved settings.
    @discardableResult
    public mutating func manageAndShowDevice(_ key: String) -> Bool {
        guard var record = deviceCatalog[key], record.isHidden || !record.isManaged else { return false }
        record.isHidden = false
        record.isManaged = true
        deviceCatalog[key] = record
        return true
    }

    @discardableResult
    public mutating func setDevicePinned(_ key: String, pinned: Bool) -> Bool {
        guard var record = deviceCatalog[key], record.isPinned != pinned else { return false }
        record.isPinned = pinned
        deviceCatalog[key] = record
        return true
    }

    /// Pinning defines the two groups. Reordering never silently changes the pin choice.
    @discardableResult
    public mutating func moveDevice(_ key: String, before target: String?) -> Bool {
        guard let record = deviceCatalog[key], target != key else { return false }
        if let target {
            guard let destination = deviceCatalog[target], destination.isPinned == record.isPinned else {
                return false
            }
        }
        let previousOrder = deviceOrder
        let keys = orderedDevices(includeHidden: true).map(\.id)
        var group = keys.filter { deviceCatalog[$0]?.isPinned == record.isPinned && $0 != key }
        if let target, let index = group.firstIndex(of: target) {
            group.insert(key, at: index)
        } else {
            group.append(key)
        }
        let otherGroup = keys.filter { deviceCatalog[$0]?.isPinned != record.isPinned }
        deviceOrder = record.isPinned ? group + otherGroup : otherGroup + group
        return previousOrder != deviceOrder
    }

    @discardableResult
    public mutating func removeRememberedDevice(_ key: String, connectedKeys: Set<String>) -> Bool {
        guard !connectedKeys.contains(key), deviceCatalog[key] != nil else { return false }
        deviceCatalog.removeValue(forKey: key)
        profiles.removeValue(forKey: key)
        archivedSessionProfiles.removeValue(forKey: key)
        individualProfileKeys.remove(key)
        devicePauseOverrides.removeValue(forKey: key)
        deviceOrder.removeAll { $0 == key }
        return true
    }

    mutating func normalizeDeviceCatalog() {
        let original = deviceCatalog
        var canonical: [String: RememberedDevice] = [:]
        // An exact dictionary key wins over aliases; remaining collisions resolve consistently.
        let sourceKeys = original.keys.sorted {
            let firstIsCanonical = original[$0]?.id == $0
            let secondIsCanonical = original[$1]?.id == $1
            if firstIsCanonical != secondIsCanonical { return firstIsCanonical }
            return $0 < $1
        }
        for sourceKey in sourceKeys {
            guard var record = original[sourceKey], !record.id.isEmpty, canonical[record.id] == nil else {
                continue
            }
            record.name = String(record.name.prefix(120))
            if record.isHidden { record.isManaged = false }
            canonical[record.id] = record
        }
        var seen: Set<String> = []
        var normalizedOrder: [String] = []
        for sourceKey in deviceOrder {
            let key = canonical[sourceKey] != nil ? sourceKey : original[sourceKey]?.id ?? sourceKey
            if canonical[key] != nil, seen.insert(key).inserted { normalizedOrder.append(key) }
        }
        normalizedOrder.append(contentsOf: canonical.keys.filter { !seen.contains($0) }.sorted())
        deviceCatalog = canonical
        deviceOrder = normalizedOrder
    }
}
