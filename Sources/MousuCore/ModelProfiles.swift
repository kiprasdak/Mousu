import Foundation

public struct ArchivedSessionProfile: Codable, Equatable, Sendable {
    public var settings: DeviceProfile
    public var isCustomized: Bool

    public init(settings: DeviceProfile, isCustomized: Bool = false) {
        self.settings = settings.normalized()
        self.isCustomized = isCustomized
    }
}

public struct SharedModelProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Exact variants adopted by the captured card or explicitly linked by the user.
    public var fingerprints: [DeviceModelFingerprint]
    public var settings: DeviceProfile
    /// A persistent presentation anchor, not a fabricated physical identity.
    public var cardKey: String?
    public var cardPaused: Bool?
    public var capturesAllMatches: Bool?
    /// Presentation only; older preferences show the explanation by default.
    public var matchingExplanationDismissed: Bool?

    public init(
        id: String = "model:\(UUID().uuidString)", name: String,
        fingerprints: [DeviceModelFingerprint], settings: DeviceProfile
    ) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.fingerprints = fingerprints
        self.settings = settings.normalized()
        self.settings.name = ""  // A profile title must never rename every matching device.
    }
}

public enum ProfileSource: Equatable, Sendable {
    case individual
    case model(String)
    case automatic
    case conflict([String])
}

public struct ResolvedDeviceProfile: Equatable, Sendable {
    public var settings: DeviceProfile
    public var source: ProfileSource
}

public enum ModelProfileError: Error, LocalizedError, Equatable {
    case unavailableFingerprint, unmanagedDevice, alreadyCovered, missingProfile, invalidName, limitReached,
        incompatibleFunction

    public var errorDescription: String? {
        switch self {
        case .unavailableFingerprint:
            "Not enough device information to match reliably."
        case .unmanagedDevice: "Manage this device first."
        case .alreadyCovered: "This model already has settings. Use its existing profile."
        case .missingProfile: "These matching settings are no longer available."
        case .invalidName: "Enter a name."
        case .incompatibleFunction: "Choose a card for the same kind of pointer input."
        case .limitReached: "Too many model profiles. Remove an unused one."
        }
    }
}

extension DeviceProfile {
    /// Capabilities constrain effective settings, never the stored template.
    public func constrained(to capabilities: DeviceCapabilities) -> Self {
        var result = normalized()
        if !capabilities.supportsFlat { result.pointerMode = .system }
        if capabilities.isContinuous { result.scrollMode = .system }
        if !capabilities.supportsScroll {
            result.scrollMode = .system
            result.scrollSpeed = 1
            result.verticalDirection = .system
            result.horizontalDirection = .system
        }
        return result
    }

    /// Merge only edits visible in this editor. A touch-only participant cannot
    /// erase the wheel preset used by another participant in the same profile.
    public func mergingInputChanges(from previous: Self, to draft: Self) -> Self {
        var result = self
        if previous.pointerMode != draft.pointerMode { result.pointerMode = draft.pointerMode }
        if previous.pointerSpeed != draft.pointerSpeed { result.pointerSpeed = draft.pointerSpeed }
        if previous.scrollMode != draft.scrollMode { result.scrollMode = draft.scrollMode }
        if previous.linesPerStep != draft.linesPerStep { result.linesPerStep = draft.linesPerStep }
        if previous.scrollSpeed != draft.scrollSpeed { result.scrollSpeed = draft.scrollSpeed }
        if previous.verticalDirection != draft.verticalDirection { result.verticalDirection = draft.verticalDirection }
        if previous.horizontalDirection != draft.horizontalDirection {
            result.horizontalDirection = draft.horizontalDirection
        }
        if previous.directionsLinked != draft.directionsLinked { result.directionsLinked = draft.directionsLinked }
        if previous.enabled != draft.enabled { result.enabled = draft.enabled }
        return result.normalized()
    }
}

extension Preferences {
    public func matchingModelProfiles(_ fingerprint: DeviceModelFingerprint?) -> [SharedModelProfile] {
        guard let fingerprint, fingerprint.isValid else { return [] }
        return modelProfiles.values.filter { $0.fingerprints.contains(fingerprint) }
            .sorted { $0.id < $1.id }
    }

    public func resolvedProfile(for device: DeviceInfo) -> ResolvedDeviceProfile {
        resolveProfile(key: device.identity.key, model: device.model, capabilities: device.capabilities)
    }

    public func resolvedProfile(
        for record: RememberedDevice, includingArchive: Bool = true
    ) -> ResolvedDeviceProfile {
        resolveProfile(
            key: record.id, model: record.model, capabilities: record.capabilities,
            archive: includingArchive ? archivedSessionProfiles[record.id] : nil)
    }

    private func resolveProfile(
        key: String, model: DeviceModelMetadata?, capabilities: DeviceCapabilities,
        archive: ArchivedSessionProfile? = nil
    ) -> ResolvedDeviceProfile {
        let matches = matchingModelProfiles(model?.fingerprint)
        let stored = profiles[key] ?? archive?.settings
        let source: ProfileSource
        var settings: DeviceProfile
        let capturesAll = matches.count == 1 && matches.first?.capturesAllMatches == true
        let explicitlyExcluded = deviceCatalog[key].map { !$0.isManaged || $0.isHidden } ?? false
        if (individualProfileKeys.contains(key) || archive?.isCustomized == true)
            && (!capturesAll || explicitlyExcluded)
        {
            source = .individual
            settings = stored ?? DeviceProfile()
        } else if matches.count == 1, let match = matches.first {
            source = .model(match.id)
            settings = match.settings
            settings.name = stored?.name ?? ""
        } else if matches.count > 1 {
            // Fail closed if imported/hand-edited preferences contain overlapping rules.
            source = .conflict(matches.map(\.id))
            settings = DeviceProfile(name: stored?.name ?? "")
        } else {
            source = .automatic
            settings = stored ?? DeviceProfile()
        }
        switch source {
        case .model(let id) where modelProfiles[id]?.capturesAllMatches == true:
            if modelProfiles[id]?.cardPaused == true { settings.enabled = false }
        case .model(let id) where modelProfiles[id]?.cardPaused == true:
            settings.enabled = false
        case .conflict: break  // A pause override cannot activate an ambiguous match.
        default:
            if let paused = devicePauseOverrides[key] { settings.enabled = !paused }
        }
        return ResolvedDeviceProfile(settings: settings.constrained(to: capabilities), source: source)
    }

    @discardableResult
    public mutating func createModelProfile(
        for device: DeviceInfo, name: String, devices: [DeviceInfo], replacingExistingOverrides: Bool = false
    ) throws -> String {
        guard isDeviceManaged(device.identity.key) else { throw ModelProfileError.unmanagedDevice }
        guard let fingerprint = device.model.fingerprint, fingerprint.isValid else {
            throw ModelProfileError.unavailableFingerprint
        }
        guard matchingModelProfiles(fingerprint).isEmpty else { throw ModelProfileError.alreadyCovered }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ModelProfileError.invalidName }
        guard modelProfiles.count < 128 else { throw ModelProfileError.limitReached }
        let current = resolvedProfile(for: device).settings
        var template = current
        template.enabled = template.hasCustomInputSettings
        let profile = SharedModelProfile(name: title, fingerprints: [fingerprint], settings: template)
        rememberDevices(devices)
        if current.isDevicePaused { devicePauseOverrides[device.identity.key] = true }
        modelProfiles[profile.id] = profile
        if replacingExistingOverrides {
            for record in deviceCatalog.values
            where record.model?.fingerprint == fingerprint && isDeviceManaged(record.id) {
                if resolvedProfile(for: record).settings.isDevicePaused { devicePauseOverrides[record.id] = true }
                individualProfileKeys.remove(record.id)
            }
        }
        individualProfileKeys.remove(device.identity.key)
        return profile.id
    }

    @discardableResult
    public mutating func updateResolvedProfile(_ draft: DeviceProfile, for device: DeviceInfo) -> Bool {
        let current = resolvedProfile(for: device)
        let valid = draft.normalized()
        guard current.settings != valid else { return false }
        if case .model(let id) = current.source, var model = modelProfiles[id] {
            model.settings = model.settings.mergingInputChanges(from: current.settings, to: valid)
            model.settings.name = ""
            modelProfiles[id] = model
        } else {
            // An explicit edit is a device override, including a System choice.
            profiles[device.identity.key] = (profiles[device.identity.key] ?? current.settings)
                .mergingInputChanges(from: current.settings, to: valid)
            individualProfileKeys.insert(device.identity.key)
        }
        return true
    }

    public mutating func setDevicePaused(_ paused: Bool, device: DeviceInfo) {
        devicePauseOverrides[device.identity.key] = paused
    }

    /// Removing a rule preserves every known participant's current settings as
    /// an individual override. Unseen future devices resume normal defaults.
    public mutating func removeModelProfile(_ id: String, devices: [DeviceInfo]) {
        guard let profile = modelProfiles[id] else { return }
        rememberDevices(devices)
        for record in deviceCatalog.values {
            let resolved = resolvedProfile(for: record)
            if case .model(let sourceID) = resolved.source, sourceID == id {
                preserveIndividualSettings(resolved.settings, for: record, leaving: profile)
            }
        }
        modelProfiles.removeValue(forKey: id)
    }

    /// Detaching a known participant must preserve its effective management
    /// exclusion as well as its input settings. Removing sharing never opts in.
    private mutating func preserveIndividualSettings(
        _ settings: DeviceProfile, for record: RememberedDevice, leaving profile: SharedModelProfile
    ) {
        profiles[record.id] = settings
        individualProfileKeys.insert(record.id)
        if let cardKey = profile.cardKey, let card = deviceCatalog[cardKey],
            !card.isManaged || card.isHidden
        {
            var participant = record
            participant.isManaged = false
            participant.isHidden = participant.isHidden || card.isHidden
            deviceCatalog[record.id] = participant
        }
    }

    /// Ordinary anonymous history is useful briefly, but cannot grow forever.
    /// Explicit edits and organization choices are preserved without a cap.
    public static let maximumOrdinaryAnonymousHistory = 100

    private func isOrdinaryAnonymousHistory(_ record: RememberedDevice, connectedKeys: Set<String>) -> Bool {
        let archive = archivedSessionProfiles[record.id]
        return !record.identity.persistent && !connectedKeys.contains(record.id)
            && !modelProfiles.values.contains(where: { $0.cardKey == record.id })
            && !individualProfileKeys.contains(record.id) && archive?.isCustomized != true
            && devicePauseOverrides[record.id] != true
            && !record.isPinned && !record.isHidden && record.isManaged && record.iconAppearance == nil
            && record.connectionTypeOverride == nil
            && (profiles[record.id]?.name ?? archive?.settings.name ?? "").isEmpty
            && record.name == record.model?.productName
    }

    /// A model-covered anonymous connection needs no permanent history card.
    /// Retain intentional metadata, and bound uncaptured ordinary history too.
    @discardableResult
    public mutating func pruneModelConnectionHistory(connected: [DeviceInfo]) -> Bool {
        let connectedKeys = Set(connected.map { $0.identity.key })
        let disposable = deviceCatalog.values.filter { record in
            isOrdinaryAnonymousHistory(record, connectedKeys: connectedKeys)
                && matchingModelProfiles(record.model?.fingerprint).count == 1
        }.map(\.id)
        for key in disposable { removeRememberedDevice(key, connectedKeys: connectedKeys) }
        let bounded = pruneAnonymousHistory(connected: connected)
        return !disposable.isEmpty || bounded
    }

    @discardableResult
    public mutating func pruneAnonymousHistory(
        connected: [DeviceInfo], limit: Int = Self.maximumOrdinaryAnonymousHistory
    ) -> Bool {
        guard deviceCatalog.count > max(0, limit) else { return false }
        let connectedKeys = Set(connected.map { $0.identity.key })
        let ordinary = orderedDevices(includeHidden: true).filter {
            isOrdinaryAnonymousHistory($0, connectedKeys: connectedKeys)
        }
        let disposable = ordinary.prefix(max(0, ordinary.count - max(0, limit))).map(\.id)
        for key in disposable { removeRememberedDevice(key, connectedKeys: connectedKeys) }
        return !disposable.isEmpty
    }

    mutating func normalizeModelProfiles() {
        individualProfileKeys = Set(individualProfileKeys.filter { !$0.isEmpty })
        // Invalid persisted model rules must fail decoding, not become wildcards.
        modelProfiles = modelProfiles.mapValues { profile in
            var result = profile
            result.name = String(profile.name.prefix(120))
            result.settings.normalize()
            result.settings.name = ""
            return result
        }
    }

    func validateModelProfiles() throws {
        guard ambiguousIdentityKeys.allSatisfy({ $0.hasPrefix("hid:") }),
            archivedSessionProfiles.keys.allSatisfy({ $0.hasPrefix("session:") })
        else { throw PreferencesStoreError.corrupted("Invalid archived settings or identity evidence") }
        guard connectionLabels.allSatisfy({ $0.fingerprint.isValid }),
            Set(connectionLabels.map(\.fingerprint)).count == connectionLabels.count
        else { throw PreferencesStoreError.corrupted("Invalid connection labels") }
        let cardKeys = modelProfiles.values.compactMap(\.cardKey)
        guard Set(cardKeys).count == cardKeys.count,
            cardKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }),
            modelProfiles.count <= 128,
            modelProfiles.allSatisfy({ id, profile in
                id == profile.id && id.hasPrefix("model:") && id.count <= 128 && !profile.name.isEmpty
                    && !profile.fingerprints.isEmpty && profile.fingerprints.count <= 32
                    && Set(profile.fingerprints).count == profile.fingerprints.count
                    && profile.fingerprints.allSatisfy(\.isValid)
            })
        else { throw PreferencesStoreError.corrupted("Invalid model profile rules") }
    }

    mutating func removeSessionProfileState() {
        for (key, profile) in profiles where key.hasPrefix("session:") {
            guard let record = deviceCatalog[key], !record.identity.persistent else { continue }
            var settings = profile
            if let paused = devicePauseOverrides[key] { settings.enabled = !paused }
            archivedSessionProfiles[key] = ArchivedSessionProfile(
                settings: settings,
                isCustomized: individualProfileKeys.contains(key) || devicePauseOverrides[key] == true
                    || archivedSessionProfiles[key]?.isCustomized == true)
        }
        // An archive has no meaning after its history card has been forgotten.
        archivedSessionProfiles = archivedSessionProfiles.filter {
            deviceCatalog[$0.key]?.identity.persistent == false
        }
        profiles = profiles.filter { !$0.key.hasPrefix("session:") }
        individualProfileKeys = Set(individualProfileKeys.filter { !$0.hasPrefix("session:") })
        devicePauseOverrides = devicePauseOverrides.filter { !$0.key.hasPrefix("session:") }
    }
}
