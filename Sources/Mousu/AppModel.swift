import AppKit
import ApplicationServices
import Foundation
import MousuCore
import MousuNative
import Observation
import ServiceManagement

struct CatalogDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let transport: String
    let kind: DeviceKind
    let capabilities: DeviceCapabilities
    let connection: DeviceInfo?
    let connections: [DeviceInfo]
    let modelProfileID: String?
    let capturesAllMatches: Bool
    let matchingExplanationDismissed: Bool
    let profile: DeviceProfile
    let isManaged: Bool
    let isHidden: Bool
    let isPinned: Bool
    let iconAppearance: DeviceIconAppearance
    let identityPersistent: Bool
    let modelMetadata: DeviceModelMetadata?
    let profileSource: ProfileSource

    var isConnected: Bool { !connections.isEmpty }
    var isModelCard: Bool { modelProfileID != nil }
    var connectionCount: Int { connections.count }
    var connectionDescription: String {
        if isModelCard {
            return connectionCount == 0
                ? "No devices connected"
                : "\(connectionCount) device\(connectionCount == 1 ? "" : "s") connected"
        }
        return isConnected ? "Connected" : "Disconnected"
    }
    var catalogRank: Int { isConnected ? (isManaged ? 0 : 1) : 2 }

    init(
        _ remembered: RememberedDevice, connection: DeviceInfo?, profile: DeviceProfile,
        source: ProfileSource = .individual, connections: [DeviceInfo]? = nil, modelProfileID: String? = nil,
        capturesAllMatches: Bool = false, matchingExplanationDismissed: Bool = false,
        transportLabel: String? = nil
    ) {
        iconAppearance = remembered.iconAppearance ?? DeviceIconAppearance()
        id = remembered.id
        name = profile.name.isEmpty ? remembered.name : profile.name
        transport = transportLabel ?? remembered.transport
        kind = remembered.kind
        capabilities = remembered.capabilities
        self.connections = connections ?? connection.map { [$0] } ?? []
        self.modelProfileID = modelProfileID
        self.capturesAllMatches = capturesAllMatches
        self.matchingExplanationDismissed = matchingExplanationDismissed
        if modelProfileID != nil, var presentation = connection {
            presentation.identity = remembered.identity
            presentation.name = name
            self.connection = presentation
        } else {
            self.connection = connection
        }
        self.profile = profile
        isManaged = remembered.isManaged
        isHidden = remembered.isHidden
        isPinned = remembered.isPinned
        identityPersistent = remembered.identity.persistent
        modelMetadata = remembered.model
        profileSource = source
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var devices: [DeviceInfo] = [] { didSet { invalidateCatalog() } }
    var selectedID: UInt64? { didSet { if selectedID != oldValue { invalidateCatalog() } } }
    private var selectedCatalogKey: String?
    private var lastMenuDeviceKey: String?
    private var catalogDisplayOrder: [String] = [] { didSet { invalidateCatalog() } }
    private var catalogAliases: [String: String] = [:]
    var showHiddenDevices = false {
        didSet {
            if oldValue != showHiddenDevices { reconcileCatalogSelection() }
        }
    }
    var settingsPresented = false
    var permissionGranted: Bool { setupFlow.permissionGranted }
    var requiresSetup: Bool { setupFlow.isPresented }
    var canContinueSetup: Bool { setupFlow.canContinue && storageHealthy }
    private(set) var accessibilityRequested = false
    private(set) var hasBuiltInTrackpad = false
    var bridgeAvailable = false
    var status = "Ready"
    var detail = "Settings apply to external pointer devices."
    var errorMessage: String?
    private(set) var settingsStorageError: String?
    private(set) var retryingSettingsStorage = false
    var canRetrySettingsStorage: Bool { store != nil && lockFD >= 0 && !quitInProgress && !stopped }
    private var storageHealthy: Bool { settingsStorageError == nil }
    private var preferences = Preferences() { didSet { invalidateCatalog() } }
    private var catalogRevision: UInt64 = 0
    @ObservationIgnored private var cachedCatalog: (revision: UInt64, entries: [CatalogDevice])?

    private func invalidateCatalog() { catalogRevision &+= 1 }
    private var setupFlow = SetupFlow(hasCompletedSetup: false, permissionGranted: AXIsProcessTrusted())

    @ObservationIgnored private let access: DeviceAccess
    @ObservationIgnored private var worker: EventWorker?
    @ObservationIgnored private var pointer: PointerController?
    @ObservationIgnored private var store: PreferencesStore?
    @ObservationIgnored private var preferencesWriter: PreferencesWriter?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshPending = false
    @ObservationIgnored private var permissionRecoveryPending = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let inputEditCommit = DeferredInputCommit()
    @ObservationIgnored private var accessibilityFocusTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var quitInProgress = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var preferencesLoaded = false
    @ObservationIgnored private var settingsRecoveryTask: Task<Void, Never>?
    @ObservationIgnored private var nextSettingsRetry = Date.distantPast
    @ObservationIgnored private var lockFD: Int32 = -1

    var selectedDevice: DeviceInfo? { devices.first { $0.id == selectedID } }
    func profile(for id: UInt64) -> DeviceProfile? {
        guard let device = devices.first(where: { $0.id == id }) else { return nil }
        return preferences.resolvedProfile(for: device).settings
    }

    var sharedModelProfiles: [SharedModelProfile] {
        preferences.modelProfiles.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    @discardableResult
    func captureModelCard(_ key: String) throws -> String {
        guard canOrganizeDevices else { throw ModelProfileError.unmanagedDevice }
        let previousCards = sharedModelProfiles.compactMap(\.cardKey)
        let id = try preferences.captureModelCard(for: key, devices: devices)
        let included = preferences.automaticallyIncludeMatchingConnections()
        catalogAliases.merge(included) { _, destination in destination }
        for record in preferences.deviceCatalog.values {
            if case .model(let source) = preferences.resolvedProfile(for: record).source, source == id {
                catalogAliases[record.id] = key
            }
        }
        for old in previousCards where preferences.modelCardProfile(for: old) == nil {
            catalogAliases[old] = key
        }
        if let selectedCatalogKey, canonicalCatalogKey(selectedCatalogKey) == key {
            self.selectedCatalogKey = key
        }
        retryModelParticipants(id)
        finishProfileAssignment()
        return id
    }

    func matchingCardChoices(for key: String) -> [SharedModelProfile] {
        guard let record = preferences.deviceCatalog[key], let fingerprint = record.model?.fingerprint,
            preferences.isDeviceManaged(key)
        else { return [] }
        let source = preferences.modelCardProfile(for: key)
        let additions = source?.fingerprints ?? [fingerprint]
        return sharedModelProfiles.filter { target in
            guard target.id != source?.id, target.capturesAllMatches == true,
                let targetKey = target.cardKey, preferences.isDeviceManaged(targetKey),
                Set(additions.map(\.function)).isSubset(of: Set(target.fingerprints.map(\.function)))
            else { return false }
            return additions.allSatisfy { addition in
                preferences.matchingModelProfiles(addition).allSatisfy { $0.id == target.id || $0.id == source?.id }
            } && Set(target.fingerprints + additions).count <= 32
        }
    }

    /// Manufacturer labels only rank an explicit action; they never match input.
    func suggestedMatchingCard(for key: String) -> SharedModelProfile? {
        guard let record = preferences.deviceCatalog[key], let fingerprint = record.model?.fingerprint else {
            return nil
        }
        let product = record.model?.productName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !product.isEmpty else { return nil }
        let choices = matchingCardChoices(for: key).filter { target in
            preferences.deviceCatalog.values.contains { candidate in
                guard let model = candidate.model, let variant = model.fingerprint else { return false }
                return target.fingerprints.contains(variant) && variant.vendorID == fingerprint.vendorID
                    && model.productName.trimmingCharacters(in: .whitespacesAndNewlines)
                        .caseInsensitiveCompare(product) == .orderedSame
            }
        }
        return choices.count == 1 ? choices.first : nil
    }

    func includeConnection(_ key: String, in profileID: String) throws {
        guard canOrganizeDevices else { throw ModelProfileError.unmanagedDevice }
        guard let targetKey = preferences.modelProfiles[profileID]?.cardKey else {
            throw ModelProfileError.missingProfile
        }
        try preferences.includeConnection(from: key, in: profileID, devices: devices)
        for record in preferences.deviceCatalog.values {
            if case .model(let source) = preferences.resolvedProfile(for: record).source, source == profileID {
                catalogAliases[record.id] = targetKey
            }
        }
        catalogAliases[key] = targetKey
        if selectedCatalogKey == key { selectedCatalogKey = targetKey }
        if lastMenuDeviceKey == key { lastMenuDeviceKey = targetKey }
        retryModelParticipants(profileID)
        finishProfileAssignment()
    }

    func connectionOptions(for key: String) -> [CatalogConnectionOption] {
        guard let record = preferences.deviceCatalog[key] else { return [] }
        let fingerprints =
            preferences.modelCardProfile(for: key)?.fingerprints
            ?? record.model?.fingerprint.map { [$0] } ?? []
        if fingerprints.isEmpty {
            return [
                .init(
                    fingerprint: nil,
                    detected: record.transport.isEmpty ? record.kind.rawValue.capitalized : record.transport,
                    override: record.connectionTypeOverride, isConnected: devices.contains { $0.identity.key == key })
            ]
        }
        return fingerprints.map { fingerprint in
            let live = devices.first { $0.model.fingerprint == fingerprint }
            let detected =
                live?.transport
                ?? (record.model?.fingerprint == fingerprint ? record.transport : fingerprint.transport.title)
            return .init(
                fingerprint: fingerprint, detected: detected.isEmpty ? fingerprint.transport.title : detected,
                override: preferences.connectionTypeOverride(for: fingerprint, deviceKey: key), isConnected: live != nil
            )
        }
    }

    func setConnectionType(_ type: DeviceConnectionType?, key: String, fingerprint: DeviceModelFingerprint?) {
        guard canOrganizeDevices else { return }
        do {
            if try preferences.setConnectionType(type, for: key, fingerprint: fingerprint) { persist() }
        } catch { errorMessage = error.localizedDescription }
    }

    private func connectionSummary(
        for connections: [DeviceInfo], fallback: RememberedDevice, preferences: Preferences
    ) -> String {
        var labels: [String] = []
        for device in connections {
            let label = preferences.connectionLabel(for: device)
            if !labels.contains(label) { labels.append(label) }
        }
        return labels.isEmpty ? preferences.connectionLabel(for: fallback) : labels.joined(separator: " / ")
    }

    func dismissMatchingExplanation(for key: String) {
        guard canOrganizeDevices, preferences.dismissMatchingExplanation(for: key) else { return }
        persist()
    }

    func canonicalCatalogKey(_ key: String) -> String? {
        if catalogDevices.contains(where: { $0.id == key }) { return key }
        let visible = Set(catalogDevices.map(\.id))
        var candidate = key
        var seen: Set<String> = []
        while let alias = catalogAliases[candidate], seen.insert(candidate).inserted {
            if visible.contains(alias) { return alias }
            candidate = alias
        }
        if let record = preferences.deviceCatalog[key],
            case .model(let id) = preferences.resolvedProfile(for: record).source,
            let anchor = preferences.modelProfiles[id]?.cardKey,
            catalogDevices.contains(where: { $0.id == anchor })
        {
            return anchor
        }
        return nil
    }

    func setCatalogCardPaused(_ paused: Bool, key: String) {
        guard canOrganizeDevices, let entry = catalogDevices.first(where: { $0.id == key }) else { return }
        if let profileID = entry.modelProfileID {
            preferences.setModelCardPaused(paused, profileID: profileID)
            inputEditCommit.cancel()
            persist()
            apply(retry: true)
        } else if let id = entry.connection?.id {
            setDevicePaused(paused, for: id)
        }
    }

    func stopMatchingDevices(_ key: String) {
        guard canOrganizeDevices, let profile = preferences.modelCardProfile(for: key) else { return }
        let connection = catalogDevices.first { $0.id == key }?.connections.first
        deleteSharedProfile(profile.id)
        if let connection {
            catalogAliases[key] = connection.identity.key
            if selectedCatalogKey == key { selectCatalogDevice(connection.identity.key) }
        }
    }

    func deleteSharedProfile(_ id: String) {
        guard canOrganizeDevices else { return }
        preferences.removeModelProfile(id, devices: devices)
        finishProfileAssignment()
    }

    private func retryModelParticipants(_ profileID: String) {
        for device in devices where preferences.isDeviceManaged(device.identity.key) {
            if case .model(let id) = preferences.resolvedProfile(for: device).source, id == profileID {
                pointer?.retry(device)
            }
        }
    }

    private func finishProfileAssignment() {
        inputEditCommit.cancel()
        persist()
        apply(retry: true)
        syncCatalog()
        reconcileCatalogSelection()
    }

    private var catalogSnapshot: Preferences {
        var snapshot = preferences
        snapshot.rememberDevices(devices)
        return snapshot
    }

    var catalogDevices: [CatalogDevice] { catalogEntries(includeHidden: showHiddenDevices) }
    var hiddenDeviceCount: Int { catalogEntries(includeHidden: true).filter(\.isHidden).count }
    var canOrganizeDevices: Bool { !stopped && !requiresSetup && storageHealthy }

    var selectedCatalogDevice: CatalogDevice? {
        if let selectedID, let entry = catalogDevices.first(where: { $0.connections.contains { $0.id == selectedID } })
        {
            return entry
        }
        return catalogDevices.first { $0.id == selectedCatalogKey }
    }

    var connectedDeviceCount: Int { catalogDevices.reduce(0) { $0 + $1.connectionCount } }

    private func catalogEntries(includeHidden: Bool) -> [CatalogDevice] {
        if let cachedCatalog, cachedCatalog.revision == catalogRevision {
            return includeHidden ? cachedCatalog.entries : cachedCatalog.entries.filter { !$0.isHidden }
        }
        let snapshot = catalogSnapshot
        let records = snapshot.orderedDevices(includeHidden: true)
        var followers: [String: [DeviceInfo]] = [:]
        for device in devices {
            if case .model(let id) = snapshot.resolvedProfile(for: device).source,
                let record = snapshot.deviceCatalog[device.identity.key], record.isManaged && !record.isHidden
            {
                followers[id, default: []].append(device)
            }
        }
        let entries = records.compactMap { remembered -> CatalogDevice? in
            if let shared = snapshot.modelCardProfile(for: remembered.id) {
                let connections = (followers[shared.id] ?? []).sorted { $0.id < $1.id }
                let connection = connections.first(where: { $0.id == selectedID }) ?? connections.first
                var profile = shared.settings
                profile.name = remembered.name
                if shared.cardPaused == true { profile.enabled = false }
                // Legacy per-device pauses remain visible until the group pause button is used.
                if !connections.isEmpty
                    && connections.allSatisfy({ snapshot.resolvedProfile(for: $0).settings.isDevicePaused })
                {
                    profile.enabled = false
                }
                return CatalogDevice(
                    remembered, connection: connection, profile: profile,
                    source: .model(shared.id), connections: connections, modelProfileID: shared.id,
                    capturesAllMatches: shared.capturesAllMatches == true,
                    matchingExplanationDismissed: shared.matchingExplanationDismissed == true,
                    transportLabel: connectionSummary(for: connections, fallback: remembered, preferences: snapshot))
            }
            let connection = devices.first { $0.identity.key == remembered.id }
            let resolved =
                connection.map { snapshot.resolvedProfile(for: $0) }
                ?? snapshot.resolvedProfile(for: remembered)
            if case .model(let id) = resolved.source,
                snapshot.modelProfiles[id]?.cardKey != nil, remembered.isManaged && !remembered.isHidden
            {
                return nil
            }
            return CatalogDevice(
                remembered, connection: connection, profile: resolved.settings, source: resolved.source,
                transportLabel: connection.map { snapshot.connectionLabel(for: $0) }
                    ?? snapshot.connectionLabel(for: remembered))
        }
        let displayIndices = Dictionary(uniqueKeysWithValues: catalogDisplayOrder.enumerated().map { ($1, $0) })
        let ordered = entries.enumerated().sorted { lhs, rhs in
            if lhs.element.isPinned != rhs.element.isPinned { return lhs.element.isPinned }
            if lhs.element.catalogRank != rhs.element.catalogRank {
                return lhs.element.catalogRank < rhs.element.catalogRank
            }
            let lhsIndex = displayIndices[lhs.element.id] ?? (catalogDisplayOrder.count + lhs.offset)
            let rhsIndex = displayIndices[rhs.element.id] ?? (catalogDisplayOrder.count + rhs.offset)
            return lhsIndex < rhsIndex
        }.map(\.element)
        cachedCatalog = (catalogRevision, ordered)
        return includeHidden ? ordered : ordered.filter { !$0.isHidden }
    }

    func selectCatalogDevice(_ key: String) {
        guard let entry = catalogDevices.first(where: { $0.id == key }) else { return }
        selectedCatalogKey = entry.id
        selectedID = entry.connection?.id
    }

    // Remember the widget independently of the main window, for this launch only.
    var restoredMenuDeviceKey: String? {
        lastMenuDeviceKey.flatMap(canonicalCatalogKey)
    }

    func rememberMenuDevice(_ key: String?) {
        lastMenuDeviceKey = key.flatMap(canonicalCatalogKey)
    }

    private func reconcileCatalogSelection() {
        let entries = catalogDevices
        let key = selectedCatalogKey.flatMap(canonicalCatalogKey) ?? selectedDevice?.identity.key
        let entry = entries.first { $0.id == key } ?? entries.first
        if selectedCatalogKey != entry?.id { selectedCatalogKey = entry?.id }
        if selectedID != entry?.connection?.id { selectedID = entry?.connection?.id }
    }

    private func retainCatalogDisplayOrder() {
        // Connection status can change groups without sending a card behind older
        // disconnected devices solely because it was discovered later.
        let order = catalogEntries(includeHidden: true).map(\.id)
        if catalogDisplayOrder != order { catalogDisplayOrder = order }
    }

    private func syncCatalog() {
        // Calling a mutating method on the observed property publishes even when
        // rememberDevices reports no change. Stage it before touching UI state.
        var updated = preferences
        let remembered = updated.rememberDevices(devices)
        let anchored = updated.ensureModelCards(devices: devices)
        let included = updated.automaticallyIncludeMatchingConnections()
        catalogAliases.merge(included) { _, destination in destination }
        let pruned = updated.pruneModelConnectionHistory(connected: devices)
        if remembered || anchored || !included.isEmpty || pruned {
            preferences = updated
            persist()
        }
    }

    func deviceIconAppearance(_ key: String) -> DeviceIconAppearance {
        preferences.deviceCatalog[key]?.iconAppearance ?? DeviceIconAppearance()
    }

    func setDeviceIconAppearance(_ key: String, appearance: DeviceIconAppearance) {
        guard canOrganizeDevices else { return }
        preferences.rememberDevices(devices)
        guard var record = preferences.deviceCatalog[key] else { return }
        record.iconAppearance = appearance == DeviceIconAppearance() ? nil : appearance
        preferences.deviceCatalog[key] = record
        persist()
    }

    func renameCatalogDevice(_ key: String, name: String) {
        guard canOrganizeDevices, preferences.deviceCatalog[key] != nil else { return }
        if preferences.renameModelCard(key, name: name) {
            persist()
            return
        }
        var profile = preferences.profiles[key] ?? DeviceProfile()
        let normalizedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard profile.name != normalizedName else { return }
        profile.name = normalizedName
        preferences.profiles[key] = profile
        persist()
    }

    func hideDevice(_ key: String) {
        guard canOrganizeDevices else { return }
        preferences.rememberDevices(devices)
        guard preferences.setDeviceHiddenAndUnmanaged(key) else { return }
        reconcileCatalogSelection()
        persist()
        apply()
    }

    func manageAndShowDevice(_ key: String) {
        guard canOrganizeDevices else { return }
        preferences.rememberDevices(devices)
        guard preferences.manageAndShowDevice(key) else { return }
        reconcileCatalogSelection()
        persist()
        apply(retry: true)
    }

    var hasDeviceSelection: Bool { !selectedDeviceKeys.isEmpty }
    var canClearDeviceSelection: Bool {
        hasDeviceSelection && selectedDeviceKeys != Set([selectedCatalogKey].compactMap { $0 })
    }

    func canSelectDevicesForCleanup(disconnectedOnly: Bool) -> Bool {
        let target = Set(catalogDevices.filter { !disconnectedOnly || !$0.isConnected }.map(\.id))
        let current = hasDeviceSelection ? selectedDeviceKeys : Set([selectedCatalogKey].compactMap { $0 })
        return !target.isEmpty && target != current
    }
    var selectedDeviceKeys: Set<String> = []
    private var selectionAnchor: String?

    var selectedCatalogEntries: [CatalogDevice] {
        catalogDevices.filter { selectedDeviceKeys.contains($0.id) }
    }

    func clearDeviceSelection() {
        selectedDeviceKeys = []
        selectionAnchor = nil
    }

    func selectDeviceForCleanup(_ key: String, range: Bool = false, additive: Bool = false) {
        let ids = catalogDevices.map(\.id)
        guard ids.contains(key) else { return }
        if range, let anchor = selectionAnchor, let start = ids.firstIndex(of: anchor),
            let end = ids.firstIndex(of: key)
        {
            let keys = Set(ids[min(start, end)...max(start, end)])
            selectedDeviceKeys = additive ? selectedDeviceKeys.union(keys) : keys
        } else {
            if selectedDeviceKeys.contains(key) {
                selectedDeviceKeys.remove(key)
            } else {
                selectedDeviceKeys.insert(key)
            }
            selectionAnchor = key
        }
    }

    func selectDevicesForCleanup(disconnectedOnly: Bool) {
        selectedDeviceKeys = Set(catalogDevices.filter { !disconnectedOnly || !$0.isConnected }.map(\.id))
        selectionAnchor = catalogDevices.first(where: { selectedDeviceKeys.contains($0.id) })?.id
    }

    func forgetSelectedDevices() {
        guard canOrganizeDevices else { return }
        let connectedKeys = Set(devices.map { $0.identity.key })
        for entry in selectedCatalogEntries where !entry.isConnected {
            forgetCatalogEntry(entry, connectedKeys: connectedKeys)
        }
        clearDeviceSelection()
        reconcileCatalogSelection()
        persist()
    }

    func hideSelectedDevices() {
        guard canOrganizeDevices else { return }
        preferences.rememberDevices(devices)
        for entry in selectedCatalogEntries { preferences.setDeviceHiddenAndUnmanaged(entry.id) }
        clearDeviceSelection()
        reconcileCatalogSelection()
        persist()
        apply()
    }

    func removeDevice(_ key: String) {
        guard canOrganizeDevices else { return }
        let connectedKeys = Set(devices.map { $0.identity.key })
        guard let entry = catalogEntries(includeHidden: true).first(where: { $0.id == key }), !entry.isConnected else {
            return
        }
        forgetCatalogEntry(entry, connectedKeys: connectedKeys)
        reconcileCatalogSelection()
        persist()
    }

    private func forgetCatalogEntry(_ entry: CatalogDevice, connectedKeys: Set<String>) {
        var keys: Set<String> = [entry.id]
        if let id = entry.modelProfileID {
            for record in preferences.deviceCatalog.values where record.isManaged && !record.isHidden {
                if case .model(let source) = preferences.resolvedProfile(for: record).source, source == id {
                    keys.insert(record.id)
                }
            }
            preferences.removeModelProfile(id, devices: devices)
        }
        for key in keys { preferences.removeRememberedDevice(key, connectedKeys: connectedKeys) }
    }

    func toggleDevicePin(_ key: String) {
        guard canOrganizeDevices else { return }
        preferences.rememberDevices(devices)
        guard let entry = preferences.deviceCatalog[key],
            preferences.setDevicePinned(key, pinned: !entry.isPinned)
        else { return }
        persist()
    }

    func moveDevice(_ key: String, before target: String?) {
        guard canOrganizeDevices, let entry = catalogDevices.first(where: { $0.id == key }), !entry.isPinned else {
            return
        }
        if let target, !reorderGroup(for: key).contains(where: { $0.id == target }) { return }
        var updated = preferences
        updated.rememberDevices(devices)
        updated.deviceOrder = catalogEntries(includeHidden: true).map(\.id)
        guard updated.moveDevice(key, before: target) else { return }
        preferences = updated
        catalogDisplayOrder = updated.deviceOrder
        persist()
    }

    private func reorderGroup(for key: String) -> [CatalogDevice] {
        guard let entry = catalogDevices.first(where: { $0.id == key }), !entry.isPinned else { return [] }
        return catalogDevices.filter { $0.isPinned == entry.isPinned && $0.catalogRank == entry.catalogRank }
    }

    func canMoveDeviceUp(_ key: String) -> Bool {
        guard canOrganizeDevices, let index = reorderGroup(for: key).firstIndex(where: { $0.id == key }) else {
            return false
        }
        return index > 0
    }

    func canMoveDeviceDown(_ key: String) -> Bool {
        let group = reorderGroup(for: key)
        guard canOrganizeDevices, let index = group.firstIndex(where: { $0.id == key }) else { return false }
        return index + 1 < group.count
    }

    func moveDeviceUp(_ key: String) {
        let group = reorderGroup(for: key)
        guard let index = group.firstIndex(where: { $0.id == key }), index > 0 else { return }
        moveDevice(key, before: group[index - 1].id)
    }

    func moveDeviceDown(_ key: String) {
        let group = reorderGroup(for: key)
        guard let index = group.firstIndex(where: { $0.id == key }), index + 1 < group.count else { return }
        moveDevice(key, before: index + 2 < group.count ? group[index + 2].id : nil)
    }

    var paused: Bool {
        get { preferences.paused }
        set {
            guard newValue != preferences.paused else { return }
            preferences.paused = newValue
            AppIcon.update(paused: newValue)
            persist()
            apply(retry: true)
        }
    }
    var menuBarVisible: Bool {
        get { preferences.menuBarVisible }
        set {
            guard newValue != preferences.menuBarVisible else { return }
            preferences.menuBarVisible = newValue
            persist()
        }
    }
    var hideDockWhenClosed: Bool {
        get { preferences.hideDockWhenClosed }
        set {
            guard newValue != preferences.hideDockWhenClosed else { return }
            preferences.hideDockWhenClosed = newValue
            AppPresence.shared.hideDockWhenClosed = newValue
            persist()
        }
    }

    var automaticallySetUpDevices: Bool {
        get {
            setupFlow.hasCompletedSetup ? preferences.automaticallySetUpDevices : setupFlow.automaticallySetUpDevices
        }
        set {
            guard storageHealthy, newValue != automaticallySetUpDevices else { return }
            setupFlow.automaticallySetUpDevices = newValue
            guard setupFlow.hasCompletedSetup else { return }
            preferences.automaticallySetUpDevices = newValue
            preferences.prepareAutomaticProfiles(for: devices)
            persist()
            apply()
        }
    }
    var launchAtLogin: Bool {
        get { preferences.launchAtLogin }
        set {
            guard newValue != preferences.launchAtLogin else { return }
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
                if SMAppService.mainApp.status == .requiresApproval {
                    errorMessage =
                        "Enable Mousü in System Settings → General → Login Items."
                }
                persist()
            } catch { errorMessage = "Couldn’t change launch at login.\n\n\(error.localizedDescription)" }
        }
    }

    init() {
        access = DeviceAccess()
        if CommandLine.arguments.contains("--verify-device-database") {
            let catalog = PointerModelCatalog.bundled
            let nameCount = PointerModelCatalog.usbProductNameCount
            print("Device catalog: \(catalog.rules.count) classification rules; \(nameCount) USB product names")
            exit(catalog.isAvailable && nameCount > 0 ? 0 : 1)
        }
        if CommandLine.arguments.contains("--diagnose") {
            diagnose()
            exit(0)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mousu", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            lockFD = Darwin.open(directory.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0 else {
                throw SessionLockError.operationFailed(errno)
            }
            if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                let lockError = errno
                Darwin.close(lockFD)
                lockFD = -1
                if SessionLockError.isContention(lockError) {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.kiprasdak.Mousu")
                        .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                        .activate(options: [.activateAllWindows])
                    exit(0)
                }
                throw SessionLockError.operationFailed(lockError)
            }
            let created = PreferencesStore(url: directory.appendingPathComponent("preferences.json"))
            store = created
            preferencesWriter = PreferencesWriter(store: created) { [weak self] message in
                Task { @MainActor [weak self] in self?.preferencesSaveFailed(message) }
            }
            preferences = try created.load()
            preferencesLoaded = true
        } catch {
            settingsStorageError = error.localizedDescription
        }
        setupFlow = SetupFlow(
            hasCompletedSetup: preferences.hasCompletedSetup, permissionGranted: AXIsProcessTrusted(),
            automaticallySetUpDevices: preferences.automaticallySetUpDevices)
        access.distrustIdentifiers(preferences.ambiguousIdentityKeys)
        devices = access.discover()
        preferences.ambiguousIdentityKeys.formUnion(access.ambiguousIdentityKeys)
        hasBuiltInTrackpad = access.hasBuiltInTrackpad
        bridgeAvailable = access.available
        selectedID = devices.first?.id
        syncCatalog()
        reconcileCatalogSelection()
        pointer = PointerController(access: access, directory: directory)
        pointer?.recover()
        worker = EventWorker()
        preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        observers.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.suspended = false
                    self?.refresh()
                }
            })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        apply()
        persist()
    }

    func editProfileSettings(_ profile: DeviceProfile, for id: UInt64) {
        guard !requiresSetup, permissionGranted, bridgeAvailable, storageHealthy,
            let device = devices.first(where: { $0.id == id }),
            preferences.isDeviceManaged(device.identity.key)
        else { return }
        let previous = preferences.resolvedProfile(for: device).settings
        updateProfile(previous.applyingInputEdit(profile, globallyPaused: paused), for: id, coalesce: true)
    }

    func setDevicePaused(_ shouldPause: Bool, for id: UInt64) {
        guard !requiresSetup, let device = devices.first(where: { $0.id == id }),
            preferences.isDeviceManaged(device.identity.key)
        else { return }
        preferences.setDevicePaused(shouldPause, device: device)
        inputEditCommit.cancel()
        persist()
        apply(retry: true)
    }

    func updateProfile(_ profile: DeviceProfile, for id: UInt64, coalesce: Bool = false) {
        guard !requiresSetup, let device = devices.first(where: { $0.id == id }),
            preferences.isDeviceManaged(device.identity.key)
        else { return }
        guard preferences.updateResolvedProfile(profile, for: device) else { return }
        preferences.rememberDevices(devices)
        if case .model(let profileID) = preferences.resolvedProfile(for: device).source {
            retryModelParticipants(profileID)
        } else {
            pointer?.retry(device)
        }
        if coalesce {
            inputEditCommit.schedule { [weak self] in
                guard let self, !self.stopped else { return }
                self.persist()
                self.apply(retry: true)
            }
        } else {
            inputEditCommit.cancel()
            persist()
            apply(retry: true)
        }
    }

    private func updatePermission(_ granted: Bool) {
        guard setupFlow.permissionGranted != granted else { return }
        if setupFlow.updatePermission(granted) { permissionRecoveryPending = true }
    }

    func presentSetup() {
        guard !stopped else { return }
        updatePermission(AXIsProcessTrusted())
        apply()
    }

    func continueSetup() {
        guard !stopped, storageHealthy else { return }
        updatePermission(AXIsProcessTrusted())
        guard setupFlow.canContinue else {
            apply()
            return
        }
        preferences.automaticallySetUpDevices = setupFlow.automaticallySetUpDevices
        preferences.hasCompletedSetup = true
        persist()
        if let failure = preferencesWriter?.flush() {
            preferencesSaveFailed(failure)
            return
        }
        guard storageHealthy else {
            apply()
            return
        }
        _ = setupFlow.continueSetup()
        apply(retry: true)
    }

    func requestControl() {
        guard !stopped else { return }
        updatePermission(AXIsProcessTrusted())
        guard !permissionGranted else {
            apply()
            return
        }
        accessibilityFocusTask?.cancel()
        if accessibilityRequested {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            accessibilityRequested = true
            // macOS presents this helper asynchronously. Cooperatively hand it
            // activation rather than opening a second window over the prompt.
            let promptID = "com.apple.accessibility.universalAccessAuthWarn"
            if let prompt = NSRunningApplication.runningApplications(withBundleIdentifier: promptID).first {
                NSApp.yieldActivation(to: prompt)
            } else {
                NSApp.yieldActivation(toApplicationWithBundleIdentifier: promptID)
            }
            updatePermission(MousuRequestAccessibility())
            accessibilityFocusTask = Task { @MainActor [weak self] in
                // A helper already running may not bring its new alert forward.
                // Make one activation request when ready; never keep stealing focus.
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, !self.stopped, !self.permissionGranted,
                        !AXIsProcessTrusted()
                    else { return }
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == promptID { return }
                    // Respect an intentional switch to another app while waiting.
                    guard NSApp.isActive else { return }
                    if let prompt = NSRunningApplication.runningApplications(withBundleIdentifier: promptID).first,
                        prompt.isFinishedLaunching
                    {
                        _ = prompt.activate(from: .current, options: [])
                        return
                    }
                }
            }
        }
        apply(retry: true)
    }

    func refresh() {
        guard !stopped else { return }
        if !suspended && Date() >= nextSettingsRetry { retrySettingsStorage() }
        // Permission loss stops control immediately, without waiting for discovery.
        let granted = AXIsProcessTrusted()
        if setupFlow.permissionGranted != granted {
            updatePermission(granted)
            apply()
        }
        guard refreshTask == nil else {
            refreshPending = true
            return
        }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let newDevices = await access.discoverInBackground(
                continuous: worker?.statistics.continuousDevices ?? [])
            guard !Task.isCancelled, !stopped else { return }
            refreshTask = nil
            let learned = access.ambiguousIdentityKeys.subtracting(preferences.ambiguousIdentityKeys)
            if !learned.isEmpty {
                preferences.ambiguousIdentityKeys.formUnion(learned)
                persist()
            }
            updateDiscoveredState(
                permissionGranted: AXIsProcessTrusted(), devices: newDevices,
                hasBuiltInTrackpad: access.hasBuiltInTrackpad, bridgeAvailable: access.available)
            if access.discoveryError == nil {
                let activeIDs = Set(devices.flatMap(\.serviceIDs))
                pointer?.releaseDisconnected(active: activeIDs)
                worker?.retainDeviceStatistics(activeIDs)
            }
            pointer?.checkOwnership()
            apply()
            if refreshPending {
                refreshPending = false
                refresh()
            }
        }
    }

    func updateDiscoveredState(
        permissionGranted granted: Bool, devices discovered: [DeviceInfo],
        hasBuiltInTrackpad builtInTrackpad: Bool, bridgeAvailable available: Bool
    ) {
        if setupFlow.permissionGranted != granted { updatePermission(granted) }
        if hasBuiltInTrackpad != builtInTrackpad { hasBuiltInTrackpad = builtInTrackpad }
        if bridgeAvailable != available { bridgeAvailable = available }
        if devices != discovered {
            retainCatalogDisplayOrder()
            devices = discovered
        }
        syncCatalog()
        reconcileCatalogSelection()
    }

    func resetSettings(for id: UInt64) {
        guard var profile = profile(for: id) else { return }
        profile.pointerMode = .system
        profile.pointerSpeed = 1
        profile.scrollMode = .system
        profile.linesPerStep = 3
        profile.scrollSpeed = 1
        profile.verticalDirection = .system
        profile.horizontalDirection = .system
        profile.directionsLinked = true
        updateProfile(profile, for: id)
    }

    private func persist() {
        guard storageHealthy else { return }
        preferencesWriter?.submit(preferences)
    }

    private func preferencesSaveFailed(_ message: String) {
        guard !stopped else { return }
        if settingsStorageError != message { NSLog("Mousü settings unavailable: %@", message) }
        settingsStorageError = message
        nextSettingsRetry = Date().addingTimeInterval(5)
        inputEditCommit.cancel()
        apply()
    }

    func retrySettingsStorage() {
        guard !storageHealthy, canRetrySettingsStorage, !retryingSettingsStorage,
            let store, let preferencesWriter
        else { return }
        retryingSettingsStorage = true
        nextSettingsRetry = Date().addingTimeInterval(5)
        settingsRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                retryingSettingsStorage = false
                settingsRecoveryTask = nil
            }
            guard !stopped, !quitInProgress, !Task.isCancelled else { return }
            do {
                if preferencesLoaded {
                    if let failure = await preferencesWriter.retry(preferences) {
                        preferencesSaveFailed(failure)
                        return
                    }
                } else {
                    // Never save the default in-memory model over an unreadable
                    // startup file. Load and validate the original first.
                    let loaded = try await preferencesWriter.reload(from: store)
                    guard !Task.isCancelled, !stopped else { return }
                    preferences = loaded
                    preferencesLoaded = true
                    setupFlow = SetupFlow(
                        hasCompletedSetup: loaded.hasCompletedSetup, permissionGranted: AXIsProcessTrusted(),
                        automaticallySetUpDevices: loaded.automaticallySetUpDevices)
                    preferences.launchAtLogin = SMAppService.mainApp.status == .enabled
                    access.distrustIdentifiers(loaded.ambiguousIdentityKeys)
                    AppPresence.shared.hideDockWhenClosed = loaded.hideDockWhenClosed
                    AppIcon.update(paused: loaded.paused)
                }
                guard !Task.isCancelled, !stopped else { return }
                settingsStorageError = nil
                syncCatalog()
                reconcileCatalogSelection()
                // Discovery or a pause action may have updated the model while
                // retrying. Keep those newer changes after the recovered write.
                persist()
                apply(retry: true)
            } catch {
                preferencesSaveFailed(error.localizedDescription)
            }
        }
    }

    private func apply(retry: Bool = false) {
        guard !stopped else { return }
        if !requiresSetup && storageHealthy {
            var updated = preferences
            if updated.prepareAutomaticProfiles(for: devices) {
                preferences = updated
                persist()
            }
        }
        let active =
            !requiresSetup && !preferences.paused && !suspended && !quitInProgress && permissionGranted
            && bridgeAvailable
            && storageHealthy
        var scrollProfiles: [UInt64: DeviceProfile] = [:]
        for device in devices {
            let profile = preferences.resolvedProfile(for: device).settings
            if active && profile.enabled && preferences.isDeviceManaged(device.identity.key) {
                if profile.pointerMode == .flat && device.capabilities.supportsFlat {
                    pointer?.applyFlat(device, gain: profile.pointerSpeed)
                } else {
                    pointer?.restore(device)
                }
                if device.capabilities.supportsScroll
                    && (profile.scrollMode == .fixed || profile.scrollSpeed != 1 || profile.verticalDirection != .system
                        || profile.horizontalDirection != .system)
                {
                    scrollProfiles[device.id] = profile
                }
            } else {
                pointer?.restore(device)
            }
        }
        if !active { pointer?.restoreAll() }
        worker?.configure(
            DeviceServiceGrouping.routedProfiles(devices: devices, profilesByDevice: scrollProfiles),
            retry: retry || permissionRecoveryPending)
        permissionRecoveryPending = false
        if !storageHealthy {
            status = "Settings need attention"
            detail = "Device control is paused. " + (settingsStorageError ?? "Settings could not be saved.")
            if let issue = pointer?.error { detail += " " + issue }
            return
        } else if let issue = pointer?.error {
            status = "Pointer settings need attention"
            detail = issue
            return
        } else if !bridgeAvailable {
            status = access.discoveryError == nil ? "macOS bridge unavailable" : "Device discovery unavailable"
            detail = access.discoveryError ?? "The macOS input bridge is unavailable. Input remains unchanged."
            return
        } else if requiresSetup {
            status = permissionGranted ? "Ready to continue" : "Accessibility needed"
            detail =
                permissionGranted ? "Choose Continue to finish setup." : "Grant Accessibility in Mousü to finish setup."
            return
        } else if preferences.paused || suspended || quitInProgress {
            status = "Paused"
        } else if !permissionGranted {
            status = "Accessibility needed"
        } else if worker?.status != "Active", !scrollProfiles.isEmpty {
            status = worker?.status ?? "Starting"
        } else {
            status = "Ready"
        }
        let stats = worker?.statistics ?? EventStatistics()
        detail = "\(stats.transformed) scroll events adjusted"
        if hasBuiltInTrackpad { detail = "Built-in trackpad untouched · " + detail }
        if !stats.durations.isEmpty { detail += String(format: " · p99 %.0f µs", stats.p99Microseconds) }
        if stats.missingRaw > 0 { detail += " · Some wheel events lacked original step counts and passed through" }
    }

    private func suspend() {
        suspended = true
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        apply()
    }

    /// Finish the last edit and make input safe before waiting for durable preferences.
    /// A failed save remains visible while the user decides whether to exit.
    func prepareToQuit() -> String? {
        guard !stopped else { return nil }
        quitInProgress = true
        inputEditCommit.flush()
        worker?.configure([:])
        pointer?.restoreAll()
        let saveFailure = preferencesWriter?.flush()
        if let saveFailure { preferencesSaveFailed(saveFailure) }
        let issues = [saveFailure, pointer?.restorationIssue].compactMap { $0 }
        return issues.isEmpty ? nil : issues.joined(separator: "\n\n")
    }

    func cancelQuit() {
        if pointer?.restorationIssue != nil {
            preferences.paused = true
            AppIcon.update(paused: true)
            persist()
        }
        quitInProgress = false
        apply()
    }

    func shutdown() {
        guard !stopped else { return }
        inputEditCommit.flush()
        stopped = true
        settingsRecoveryTask?.cancel()
        accessibilityFocusTask?.cancel()
        refreshTask?.cancel()
        timer?.invalidate()
        worker?.configure([:])
        worker?.shutdown()
        pointer?.restoreAll()
        if let failure = preferencesWriter?.flush() {
            NSLog("Mousü could not save settings during shutdown: %@", failure)
        }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if lockFD >= 0 {
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    private func diagnose() {
        let devices = access.discover()
        let rows: [[String: Any]] = devices.map {
            [
                "name": $0.name, "registryID": $0.id, "transport": $0.transport,
                "serviceIDs": $0.serviceIDs,
                "persistentIdentity": $0.identity.persistent,
                "flatPointer": $0.capabilities.supportsFlat, "scroll": $0.capabilities.supportsScroll,
                "continuous": $0.capabilities.isContinuous,
                "kind": $0.kind.rawValue,
                "modelMatch": $0.model.fingerprint?.summary ?? "unavailable",
                "modelFunction": $0.model.fingerprint?.function.rawValue ?? "unavailable",
                "classificationSource": $0.model.classificationSource ?? "generic HID pointer",
            ]
        }
        let result: [String: Any] = [
            "accessibility": AXIsProcessTrusted(), "bridge": access.available, "externalDevices": rows,
            "hasBuiltInTrackpad": access.hasBuiltInTrackpad,
            "excludedBuiltInServices": access.allRows.filter { ($0["External"] as? NSNumber)?.boolValue != true }.count,
            "runtimeNetwork": false, "inputMonitoringRequested": false,
            "serviceProperties": access.allRows.map { row in
                row.filter {
                    [
                        "Product", "HIDPointerAccelerationType", "HIDUseLinearScalingMouseAcceleration",
                        "HIDMouseAcceleration", "HIDPointerResolution",
                    ].contains($0.key)
                }
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        {
            print(text)
        }
    }

}
