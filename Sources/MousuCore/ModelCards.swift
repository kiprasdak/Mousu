import Foundation

extension Preferences {
    public func modelCardProfile(for key: String) -> SharedModelProfile? {
        modelProfiles.values.first { $0.cardKey == key }
    }

    @discardableResult
    public mutating func dismissMatchingExplanation(for key: String) -> Bool {
        guard var profile = modelCardProfile(for: key), profile.capturesAllMatches == true,
            profile.matchingExplanationDismissed != true
        else { return false }
        profile.matchingExplanationDismissed = true
        modelProfiles[profile.id] = profile
        return true
    }

    /// Upgrade the chosen card in place. The explicit action adopts its current
    /// settings for this model; hidden devices keep their individual exclusions.
    @discardableResult
    public mutating func captureModelCard(for key: String, devices: [DeviceInfo]) throws -> String {
        rememberDevices(devices)
        guard let record = deviceCatalog[key], let fingerprint = record.model?.fingerprint else {
            throw ModelProfileError.unavailableFingerprint
        }
        guard isDeviceManaged(key) else { throw ModelProfileError.unmanagedDevice }
        if let existing = modelCardProfile(for: key), existing.capturesAllMatches == true { return existing.id }
        let matches = matchingModelProfiles(fingerprint)
        guard matches.count <= 1 else { throw ModelProfileError.alreadyCovered }
        let current = resolvedProfile(for: record).settings
        let source =
            devices.first { $0.identity.key == key }
            ?? DeviceInfo(
                id: 0, identity: record.identity, name: record.name, transport: record.transport,
                kind: record.kind, capabilities: record.capabilities, model: record.model ?? .init())
        let id: String
        if let existing = matches.first {
            id = existing.id
        } else {
            id = try createModelProfile(
                for: source, name: record.name.isEmpty ? "Pointer device" : record.name,
                devices: devices, replacingExistingOverrides: true)
        }
        guard var profile = modelProfiles[id] else { throw ModelProfileError.missingProfile }
        if let oldKey = profile.cardKey, let old = deviceCatalog[oldKey], var anchor = deviceCatalog[key] {
            anchor.isPinned = anchor.isPinned || old.isPinned
            if anchor.iconAppearance == nil { anchor.iconAppearance = old.iconAppearance }
            deviceCatalog[key] = anchor
        }
        profile.settings = current
        profile.settings.name = ""
        profile.settings.enabled = current.hasCustomInputSettings
        profile.cardPaused = current.isDevicePaused
        profile.capturesAllMatches = true
        profile.cardKey = key
        modelProfiles[id] = profile
        for participant in deviceCatalog.values
        where profile.fingerprints.contains(where: { $0 == participant.model?.fingerprint })
            && participant.isManaged && !participant.isHidden
        {
            individualProfileKeys.remove(participant.id)
            // Explicit adoption also replaces an inert historical override.
            archivedSessionProfiles[participant.id]?.isCustomized = false
            devicePauseOverrides.removeValue(forKey: participant.id)
        }
        return id
    }

    /// Older saved model rules become visible cards too, even with no live device.
    @discardableResult
    public mutating func ensureModelCards(devices: [DeviceInfo] = []) -> Bool {
        var changed = false
        for id in modelProfiles.keys.sorted() {
            guard var profile = modelProfiles[id] else { continue }
            if let key = profile.cardKey, var card = deviceCatalog[key],
                case .model(let source) = resolvedProfile(for: card).source, source == id
            {
                if let connected = devices.sorted(by: { $0.id < $1.id }).first(where: {
                    if case .model(let source) = resolvedProfile(for: $0).source { return source == id }
                    return false
                }) {
                    let previous = card
                    card.kind = connected.kind
                    card.capabilities = connected.capabilities
                    if card.model == nil { card.model = connected.model }
                    deviceCatalog[key] = card
                    changed = changed || previous != card
                }
                continue
            }
            let candidate = orderedDevices(includeHidden: true).first { record in
                guard case .model(let source) = resolvedProfile(for: record).source else { return false }
                return source == id && record.isManaged && !record.isHidden
                    && !modelProfiles.values.contains { $0.id != id && $0.cardKey == record.id }
            }
            if let candidate {
                profile.cardKey = candidate.id
            } else if let fingerprint = profile.fingerprints.first {
                // This is explicitly a model card. It does not claim to be a physical unit.
                let key = profile.id
                deviceCatalog[key] = RememberedDevice(
                    identity: .init(key: key, persistent: false),
                    name: profile.name, transport: fingerprint.transport.title,
                    kind: fingerprint.function == .touchpad ? .trackpad : .mouse, capabilities: .init(),
                    model: .init(fingerprint: fingerprint, productName: profile.name))
                deviceOrder.append(key)
                profile.cardKey = key
            }
            modelProfiles[id] = profile
            changed = true
        }
        return changed
    }

    @discardableResult
    public mutating func renameModelCard(_ key: String, name: String) -> Bool {
        guard var profile = modelCardProfile(for: key), var card = deviceCatalog[key] else { return false }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        let product = card.model?.productName ?? ""
        let title = trimmed.isEmpty ? (product.isEmpty ? "Pointer device" : product) : trimmed
        card.name = title
        profile.name = title
        deviceCatalog[key] = card
        modelProfiles[profile.id] = profile
        if var individual = profiles[key] {
            individual.name = title
            profiles[key] = individual
        }
        return true
    }

    public mutating func setModelCardPaused(_ paused: Bool, profileID: String) {
        guard var profile = modelProfiles[profileID] else { return }
        profile.cardPaused = paused
        modelProfiles[profileID] = profile
        for record in deviceCatalog.values {
            if case .model(let id) = resolvedProfile(for: record).source, id == profileID {
                devicePauseOverrides.removeValue(forKey: record.id)
            }
        }
    }
}
