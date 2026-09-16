import Foundation

/// A user-facing label. It never changes the HID transport or matching identity.
public enum DeviceConnectionType: String, Codable, CaseIterable, Sendable {
    case usb, receiver, bluetooth

    public var title: String {
        switch self {
        case .usb: "USB"
        case .receiver: "Receiver"
        case .bluetooth: "Bluetooth"
        }
    }
}

public struct ConnectionLabelOverride: Codable, Equatable, Sendable {
    public let fingerprint: DeviceModelFingerprint
    public var type: DeviceConnectionType

    public init(fingerprint: DeviceModelFingerprint, type: DeviceConnectionType) {
        self.fingerprint = fingerprint
        self.type = type
    }
}

extension Preferences {
    public func connectionTypeOverride(
        for fingerprint: DeviceModelFingerprint?, deviceKey: String
    ) -> DeviceConnectionType? {
        if let fingerprint {
            return connectionLabels.first { $0.fingerprint == fingerprint }?.type
        }
        return deviceCatalog[deviceKey]?.connectionTypeOverride
    }

    public func connectionLabel(for device: DeviceInfo) -> String {
        connectionTypeOverride(for: device.model.fingerprint, deviceKey: device.identity.key)?.title
            ?? (device.transport.isEmpty ? device.kind.rawValue.capitalized : device.transport)
    }

    public func connectionLabel(for record: RememberedDevice) -> String {
        connectionTypeOverride(for: record.model?.fingerprint, deviceKey: record.id)?.title
            ?? (record.transport.isEmpty ? record.kind.rawValue.capitalized : record.transport)
    }

    /// Exact model variants retain labels through anonymous reconnects. A device
    /// without model evidence can only retain a label on its own history record.
    @discardableResult
    public mutating func setConnectionType(
        _ type: DeviceConnectionType?, for key: String, fingerprint: DeviceModelFingerprint?
    ) throws -> Bool {
        guard var record = deviceCatalog[key] else { throw ModelProfileError.unavailableFingerprint }
        if let fingerprint {
            let allowed = modelCardProfile(for: key)?.fingerprints ?? record.model?.fingerprint.map { [$0] } ?? []
            guard fingerprint.isValid, allowed.contains(fingerprint) else {
                throw ModelProfileError.unavailableFingerprint
            }
            let current = connectionLabels.firstIndex { $0.fingerprint == fingerprint }
            guard current.map({ connectionLabels[$0].type }) != type else { return false }
            if let current { connectionLabels.remove(at: current) }
            if let type { connectionLabels.append(.init(fingerprint: fingerprint, type: type)) }
        } else {
            guard record.model?.fingerprint == nil else { throw ModelProfileError.unavailableFingerprint }
            guard record.connectionTypeOverride != type else { return false }
            record.connectionTypeOverride = type
            deviceCatalog[key] = record
        }
        return true
    }

    /// Adopt new fingerprints only into an existing, explicitly captured card.
    /// Names provide discovery evidence; input routing still uses exact fingerprints.
    /// Return aliases before disconnected history is pruned so selections follow the card.
    @discardableResult
    public mutating func automaticallyIncludeMatchingConnections() -> [String: String] {
        let variants = Dictionary(
            grouping: deviceCatalog.values.compactMap { record in
                record.model?.fingerprint.map { ($0, record) }
            }, by: { $0.0 })
        // Decide against a snapshot: discovering one variant must not cause a
        // chain of weaker name matches or make iteration order decide ownership.
        let proposals: [(String, String)] = variants.values.compactMap { variant in
            let records = variant.map { $0.1 }.sorted { $0.id < $1.id }
            guard let fingerprint = variant.first?.0, fingerprint.isValid,
                matchingModelProfiles(fingerprint).isEmpty,
                !records.contains(where: { $0.identity.persistent }),
                let source = records.first(where: { $0.isManaged && !$0.isHidden }),
                let name = source.model.flatMap(Self.specificModelName),
                records.allSatisfy({ $0.model.flatMap(Self.specificModelName) == name }),
                !records.contains(where: {
                    $0.isManaged && !$0.isHidden
                        && (individualProfileKeys.contains($0.id)
                            || archivedSessionProfiles[$0.id]?.isCustomized == true
                            || devicePauseOverrides[$0.id] != nil)
                })
            else { return nil }
            let targets = modelProfiles.values.filter { profile in
                guard profile.capturesAllMatches == true,
                    let key = profile.cardKey, key != profile.id,
                    let anchor = deviceCatalog[key], let metadata = anchor.model,
                    let original = metadata.fingerprint,
                    profile.fingerprints.contains(original)
                else { return false }
                return original.vendorID == fingerprint.vendorID && original.function == fingerprint.function
                    && Self.specificModelName(metadata) == name
            }
            guard targets.count == 1, let target = targets.first,
                let key = target.cardKey, isDeviceManaged(key), target.fingerprints.count < 32
            else { return nil }
            return (source.id, target.id)
        }.sorted { $0.0 < $1.0 }
        var aliases: [String: String] = [:]
        for (key, profileID) in proposals {
            // The total variant limit may be reached by earlier proposals.
            guard (modelProfiles[profileID]?.fingerprints.count ?? 32) < 32 else { continue }
            do {
                try includeRememberedConnection(from: key, in: profileID)
                guard let anchor = modelProfiles[profileID]?.cardKey,
                    let fingerprint = deviceCatalog[key]?.model?.fingerprint
                else { continue }
                for (_, record) in variants[fingerprint] ?? [] where record.isManaged && !record.isHidden {
                    aliases[record.id] = anchor
                }
            } catch {
                // A conflicting or unavailable rule always leaves this connection separate.
                continue
            }
        }
        return aliases
    }

    private static func specificModelName(_ metadata: DeviceModelMetadata) -> String? {
        guard metadata.productNameIsFallback != true else { return nil }
        func normalized(_ text: String) -> String {
            text.lowercased(with: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func words(_ text: String) -> Set<String> {
            Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }
        let name = normalized(metadata.productName)
        let generic = Set([
            "usb", "bluetooth", "ble", "wireless", "wired", "receiver", "dongle", "hid",
            "mouse", "mice", "pointer", "pointing", "device", "input", "optical", "laser",
            "gaming", "ergonomic", "trackball", "trackpad", "touchpad", "2", "4", "2g", "4g",
            "2ghz", "4ghz", "ghz", "generic", "standard", "compatible", "compliant", "unknown", "external",
        ])
        let manufacturer = words(normalized(metadata.manufacturer ?? ""))
        let distinctive = words(name).subtracting(generic).subtracting(manufacturer)
        guard distinctive.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        return name
    }

    /// Explicit linking also handles differently named variants and merging cards.
    /// The destination card and its settings remain authoritative.
    public mutating func includeConnection(
        from key: String, in profileID: String, devices: [DeviceInfo]
    ) throws {
        var updated = self
        updated.rememberDevices(devices)
        try updated.includeRememberedConnection(from: key, in: profileID)
        self = updated
    }

    private mutating func includeRememberedConnection(from key: String, in profileID: String) throws {
        guard let record = deviceCatalog[key], let fingerprint = record.model?.fingerprint,
            fingerprint.isValid
        else { throw ModelProfileError.unavailableFingerprint }
        guard isDeviceManaged(key) else { throw ModelProfileError.unmanagedDevice }
        guard var target = modelProfiles[profileID], target.capturesAllMatches == true,
            let targetKey = target.cardKey, deviceCatalog[targetKey] != nil
        else { throw ModelProfileError.missingProfile }
        guard isDeviceManaged(targetKey) else { throw ModelProfileError.unmanagedDevice }
        let source = modelCardProfile(for: key)
        if source?.id == profileID { return }
        let additions = source?.fingerprints ?? [fingerprint]
        guard Set(additions.map(\.function)).isSubset(of: Set(target.fingerprints.map(\.function))) else {
            throw ModelProfileError.incompatibleFunction
        }
        for addition in additions {
            guard matchingModelProfiles(addition).allSatisfy({ $0.id == profileID || $0.id == source?.id }) else {
                throw ModelProfileError.alreadyCovered
            }
            if !target.fingerprints.contains(addition) { target.fingerprints.append(addition) }
        }
        guard target.fingerprints.count <= 32 else { throw ModelProfileError.limitReached }
        if let source { modelProfiles.removeValue(forKey: source.id) }
        modelProfiles[profileID] = target
        for participant in deviceCatalog.values
        where additions.contains(where: { $0 == participant.model?.fingerprint })
            && participant.isManaged && !participant.isHidden
        {
            individualProfileKeys.remove(participant.id)
            archivedSessionProfiles[participant.id]?.isCustomized = false
            devicePauseOverrides.removeValue(forKey: participant.id)
        }
    }
}
