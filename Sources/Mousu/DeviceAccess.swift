import Foundation
import MousuCore
import MousuNative

@MainActor
protocol PointerPropertyAccess {
    func read(_ id: UInt64, _ key: String) -> Int64?
    func write(_ id: UInt64, _ key: String, _ value: Int64) -> Bool
}

private final class HIDPropertyContext: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    deinit { MousuHIDDestroy(pointer) }
}

private struct HIDDiscoverySnapshot: @unchecked Sendable {
    // The native snapshot contains immutable scalar property values. Ownership of
    // its property client transfers to the main actor together with these rows.
    let rows: [[String: Any]]
    let properties: HIDPropertyContext
}

private actor HIDDiscoveryWorker {
    private var context: HIDPropertyContext?

    func scan() -> HIDDiscoverySnapshot? {
        if context == nil, let pointer = MousuHIDCreate() {
            context = HIDPropertyContext(pointer)
        }
        guard let context, let devices = MousuCopyDevices(context.pointer),
            let rows = (devices as NSArray) as? [[String: Any]],
            let properties = MousuHIDTakePropertyContext(context.pointer)
        else { return nil }
        return HIDDiscoverySnapshot(
            rows: rows, properties: HIDPropertyContext(properties))
    }
}

@MainActor
final class DeviceAccess: PointerPropertyAccess {
    private var context: HIDPropertyContext?
    private let backgroundDiscovery = HIDDiscoveryWorker()
    private var resolver = DeviceIdentityResolver()
    private var lastDevices: [DeviceInfo] = []
    private(set) var allRows: [[String: Any]] = []
    private(set) var discoveryError: String?
    var available: Bool { context != nil && discoveryError == nil && MousuEventBridgeAvailable() }
    var hasBuiltInTrackpad: Bool { Self.containsBuiltInTrackpad(in: allRows) }
    var ambiguousIdentityKeys: Set<String> { resolver.ambiguousKeys }

    init() { ensureContext() }

    func distrustIdentifiers(_ keys: Set<String>) { resolver.distrust(keys) }

    private func ensureContext() {
        guard context == nil else { return }
        if let pointer = MousuHIDCreate() {
            context = HIDPropertyContext(pointer)
        }
    }

    /// Presentation metadata only; never infer a trackpad from the computer name
    /// or from a combined keyboard/trackpad product label.
    static func containsBuiltInTrackpad(in rows: [[String: Any]]) -> Bool {
        rows.contains {
            ($0["Built-In"] as? NSNumber)?.boolValue == true
                && ($0["HIDPointerAccelerationType"] as? String) == "HIDTrackpadAcceleration"
        }
    }

    func discover(continuous: Set<UInt64> = []) -> [DeviceInfo] {
        ensureContext()
        guard let context, let snapshot = MousuCopyDevices(context.pointer),
            let snapshotRows = (snapshot as NSArray) as? [[String: Any]]
        else {
            discoveryError =
                "Device discovery is temporarily unavailable. Control is paused until the next successful scan."
            return lastDevices
        }
        return publish(snapshotRows, continuous: continuous)
    }

    /// Slow service discovery runs serially away from the UI. A successful scan
    /// transfers its fresh property client, so hotplug never leaves writes using
    /// an older client's cached inventory. Failed scans preserve the old owner.
    func discoverInBackground(continuous: Set<UInt64> = []) async -> [DeviceInfo] {
        let snapshot = await backgroundDiscovery.scan()
        guard !Task.isCancelled else { return lastDevices }
        guard let snapshot else {
            discoveryError =
                "Device discovery is temporarily unavailable. Control is paused until the next successful scan."
            return lastDevices
        }
        context = snapshot.properties
        return publish(snapshot.rows, continuous: continuous)
    }

    private func publish(_ rows: [[String: Any]], continuous: Set<UInt64>) -> [DeviceInfo] {
        discoveryError = nil
        allRows = rows
        lastDevices = Self.resolveDevices(rows: rows, continuous: continuous, resolver: &resolver)
        return lastDevices
    }

    /// Resolves immutable discovery rows without retaining native IOKit objects.
    static func resolveDevices(
        rows snapshot: [[String: Any]], continuous: Set<UInt64> = [], resolver: inout DeviceIdentityResolver,
        catalog: PointerModelCatalog = .bundled
    ) -> [DeviceInfo] {
        let rows = snapshot.filter {
            ($0["External"] as? NSNumber)?.boolValue == true && ($0["Built-In"] as? NSNumber)?.boolValue != true
        }
        let services = rows.compactMap { row -> PointerServiceIdentity? in
            guard let id = (row["RegistryID"] as? NSNumber)?.uint64Value else { return nil }
            let candidate = DeviceIdentityCandidate(
                registryID: id, vendorID: (row["VendorID"] as? NSNumber)?.int64Value,
                productID: (row["ProductID"] as? NSNumber)?.int64Value,
                transport: row["Transport"] as? String ?? "Unknown",
                serialNumber: row["SerialNumber"] as? String,
                uniqueID: row["PhysicalDeviceUniqueID"] as? String,
                alternateUniqueID: row["DeviceUID"] as? String)
            return PointerServiceIdentity(
                candidate: candidate,
                physicalDeviceID: (row["PhysicalDeviceRegistryID"] as? NSNumber)?.uint64Value,
                usbDeviceID: (row["USBDeviceRegistryID"] as? NSNumber)?.uint64Value,
                isTouchpad: (row["IsTouchpad"] as? NSNumber)?.boolValue == true)
        }
        let groups = DeviceServiceGrouping.groups(services)
        let identities = resolver.resolve(groups.map(\.candidate))
        let indexedRows = Dictionary(
            rows.compactMap { row -> (UInt64, [String: Any])? in
                (row["RegistryID"] as? NSNumber).map { ($0.uint64Value, row) }
            }, uniquingKeysWith: { first, _ in first })
        return groups.compactMap { group in
            let id = group.candidate.registryID
            let members = group.serviceIDs.compactMap { indexedRows[$0] }
            guard let row = members.first, let identity = identities[id] else { return nil }
            let transport = group.candidate.transport
            let product = (row["Product"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let hardware = PointerHardwareFacts(
                isTouchpad: members.contains {
                    ($0["IsTouchpad"] as? NSNumber)?.boolValue == true
                        || ($0["HIDPointerAccelerationType"] as? String) == "HIDTrackpadAcceleration"
                },
                hasRelativeAxes: members.allSatisfy { ($0["RelativePointer"] as? NSNumber)?.boolValue == true },
                supportsLinearScaling: members.allSatisfy {
                    ($0["HIDPointerAccelerationType"] as? String) == "HIDMouseAcceleration"
                        && $0["HIDUseLinearScalingMouseAcceleration"] is NSNumber
                        && $0["HIDMouseAcceleration"] is NSNumber
                },
                reportsScroll: members.contains { $0["HIDScrollAccelerationType"] != nil },
                observedContinuousScroll: !continuous.isDisjoint(with: group.serviceIDs))
            let classification = catalog.kind(
                transport: transport, vendorID: group.candidate.vendorID, productID: group.candidate.productID,
                productName: product, hardware: hardware)
            let fallback =
                product.isEmpty && DeviceTransport(hidValue: transport) == .usb
                ? PointerModelCatalog.fallbackUSBName(
                    vendorID: group.candidate.vendorID, productID: group.candidate.productID) : nil
            let name = product.isEmpty ? (fallback ?? "External pointer") : product
            return DeviceInfo(
                id: id, identity: identity, name: name, transport: transport,
                kind: classification.kind, capabilities: hardware.capabilities, serviceIDs: group.serviceIDs,
                model: DeviceModelMetadata(
                    fingerprint: DeviceModelFingerprint(
                        transport: transport, vendorID: group.candidate.vendorID, productID: group.candidate.productID,
                        function: hardware.function), productName: product,
                    manufacturer: row["Manufacturer"] as? String,
                    classificationSource: classification.source, productNameIsFallback: product.isEmpty))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func read(_ id: UInt64, _ key: String) -> Int64? {
        guard let context else { return nil }
        var value: Int64 = 0
        return MousuReadNumber(context.pointer, id, key, &value) ? value : nil
    }

    func write(_ id: UInt64, _ key: String, _ value: Int64) -> Bool {
        guard let context else { return false }
        return MousuWriteNumber(context.pointer, id, key, value) && read(id, key) == value
    }
}

struct RecoveryRecord: Codable, Equatable {
    var registryID: UInt64
    var bootSession: String
    var property: String
    var original: Int64
    var applied: Int64
    var previousApplied: Int64?
}

/// Write-ahead records survive a crash, and are meaningful only within the same
/// boot + registry lifetime. External changes relinquish ownership.
@MainActor
final class PointerController {
    private let access: any PointerPropertyAccess
    private let url: URL
    private let bootSession: String
    private var records: [RecoveryRecord] = []
    // Compound devices expose independent HID services but have one user-facing policy.
    // Journal records remain per-service so recovery never relies on a reconstructed group.
    private var serviceGroups: [UInt64: Set<UInt64>] = [:]
    private(set) var conflicts: Set<UInt64> = []
    private var conflictMessages: [UInt64: String] = [:]
    private var recoveryFailures: [UInt64: String] = [:]
    private var loadError: String?
    private var journalError: String?
    private var writable = true

    /// Cleanup failures need acknowledgment before exit; a released competing
    /// utility conflict does not imply that Mousü still owns a changed value.
    var restorationIssue: String? {
        if let loadError { return loadError }
        if let journalError { return journalError }
        if let id = recoveryFailures.keys.min() { return recoveryFailures[id] }
        return nil
    }

    var error: String? {
        if let restorationIssue { return restorationIssue }
        if let id = conflicts.min() {
            return conflictMessages[id] ?? "Pointer control is paused for a device; edit its settings to retry."
        }
        return nil
    }

    init(access: any PointerPropertyAccess, directory: URL, bootSession: String? = nil) {
        self.access = access
        url = directory.appendingPathComponent("recovery.json")
        if let bootSession {
            self.bootSession = bootSession
        } else {
            var length = 0
            sysctlbyname("kern.bootsessionuuid", nil, &length, nil, 0)
            var bytes = [CChar](repeating: 0, count: max(length, 1))
            let result = sysctlbyname("kern.bootsessionuuid", &bytes, &length, nil, 0)
            self.bootSession =
                result == 0
                ? String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                : "unavailable-\(UUID().uuidString)"
        }
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                records = try JSONDecoder().decode([RecoveryRecord].self, from: Data(contentsOf: url))
                guard records.count <= 512,
                    records.allSatisfy({
                        ["HIDMouseAcceleration", "HIDUseLinearScalingMouseAcceleration"].contains($0.property)
                    })
                else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                loadError = "Recovery file could not be read. Pointer changes are disabled; the file was preserved."
                writable = false
            }
        }
    }

    func retry(_ id: UInt64) {
        conflicts.remove(id)
        conflictMessages.removeValue(forKey: id)
    }

    func retry(_ device: DeviceInfo) {
        for id in rememberGroup(device) { retry(id) }
    }

    func recover() {
        guard writable else { return }
        records.removeAll { $0.bootSession != bootSession }
        restoreAll()
    }

    func checkOwnership() {
        let changed = records.filter {
            guard let current = access.read($0.registryID, $0.property) else { return false }
            return current != $0.applied && current != $0.previousApplied
        }
        let affected = changed.reduce(into: Set<UInt64>()) { ids, record in
            ids.formUnion(serviceGroups[record.registryID] ?? [record.registryID])
        }
        conflicts.formUnion(affected)
        for id in affected.sorted() { restore(id) }
        for id in affected {
            conflictMessages[id] =
                "Another setting changed pointer behavior. Mousü released this device; edit its settings to retry."
        }
    }

    func applyFlat(_ device: DeviceInfo, gain: Double) {
        guard writable, gain.isFinite, device.capabilities.supportsFlat else { return }
        let members = rememberGroup(device)
        // A failed rollback must finish before a later edit acquires these properties again.
        for id in members.sorted() where recoveryFailures[id] != nil { restore(id) }
        guard members.allSatisfy({ recoveryFailures[$0] == nil }) else { return }
        guard members.isDisjoint(with: conflicts) else {
            conflicts.formUnion(members)
            return
        }
        let desired: [(String, Int64)] = [
            ("HIDUseLinearScalingMouseAcceleration", 1),
            (
                "HIDMouseAcceleration",
                Int64(
                    (min(DeviceProfile.speedEntryRange.upperBound, max(DeviceProfile.speedEntryRange.lowerBound, gain))
                        * 65_536).rounded())
            ),
        ]
        if members.allSatisfy({ id in
            desired.allSatisfy { key, value in
                records.contains {
                    $0.registryID == id && $0.property == key && $0.applied == value && $0.previousApplied == nil
                }
            }
        }) {
            return
        }
        var pending = records
        for id in members.sorted() {
            for (key, value) in desired {
                guard let current = access.read(id, key) else {
                    inhibit(members, message: "Pointer properties are unavailable for \(device.name).")
                    return
                }
                if let index = pending.firstIndex(where: { $0.registryID == id && $0.property == key }) {
                    // A fresh external write never becomes our new baseline.
                    guard current == pending[index].applied else {
                        inhibit(members, message: "Another app changed pointer settings. Mousü released the device.")
                        return
                    }
                    pending[index].previousApplied = pending[index].applied
                    pending[index].applied = value
                } else {
                    guard MousuNumberIsRestorable(key, current) else {
                        inhibit(
                            members,
                            message:
                                "Pointer settings for \(device.name) have an unsupported original value. Mousü left them unchanged."
                        )
                        return
                    }
                    pending.append(
                        RecoveryRecord(
                            registryID: id, bootSession: bootSession,
                            property: key, original: current, applied: value, previousApplied: nil))
                }
            }
        }
        guard save(pending) else { return }
        records = pending
        for id in members.sorted() {
            for (key, value) in desired {
                let current = access.read(id, key)
                if current == value { continue }
                guard let record = records.first(where: { $0.registryID == id && $0.property == key }),
                    current == (record.previousApplied ?? record.original)
                else {
                    inhibit(
                        members,
                        message: "Another app changed pointer settings during the update. Mousü released the device.")
                    return
                }
                guard access.write(id, key, value) else {
                    inhibit(
                        members,
                        message:
                            "macOS did not accept the pointer change for \(device.name). Original settings were restored where possible."
                    )
                    return
                }
            }
        }
        for index in records.indices where members.contains(records[index].registryID) {
            records[index].previousApplied = nil
        }
        guard save(records) else { return }
        for id in members { conflictMessages.removeValue(forKey: id) }
    }

    private func rememberGroup(_ device: DeviceInfo) -> Set<UInt64> {
        let members = Set(device.serviceIDs).union([device.id])
        for id in members { serviceGroups[id] = members }
        return members
    }

    private func inhibit(_ members: Set<UInt64>, message: String) {
        conflicts.formUnion(members)
        for id in members { conflictMessages[id] = message }
        for id in members.sorted() { restore(id) }
    }

    func restore(_ device: DeviceInfo) {
        for id in rememberGroup(device).sorted() { restore(id) }
    }

    func restore(_ id: UInt64) {
        guard writable, records.contains(where: { $0.registryID == id }) else { return }
        var retained: [RecoveryRecord] = []
        // Restore gain before switching the acceleration mode back.
        for record in records.reversed() {
            guard record.registryID == id else {
                retained.append(record)
                continue
            }
            guard record.bootSession == bootSession else { continue }
            guard let current = access.read(id, record.property) else {
                retained.append(record)  // Preserve failed/offline recovery for later.
                recoveryFailures[id] =
                    "A pointer setting is unavailable for restoration. Mousü will retry when it is accessible."
                continue
            }
            if (current == record.applied || current == record.previousApplied) && current != record.original {
                if !access.write(id, record.property, record.original) {
                    retained.append(record)
                    recoveryFailures[id] = "A pointer setting could not be restored. Mousü will retry recovery."
                }
            }
        }
        records = retained.reversed()
        if !records.contains(where: { $0.registryID == id }) { recoveryFailures.removeValue(forKey: id) }
        _ = save(records)
    }

    func restoreAll() {
        for id in Set(records.map(\.registryID)) { restore(id) }
    }

    func releaseDisconnected(active: Set<UInt64>) {
        // Registry IDs are unique for a service lifetime. An absent service no
        // longer has properties to restore; never transfer them to its replacement.
        let filtered = records.filter { active.contains($0.registryID) }
        if filtered != records {
            records = filtered
            _ = save(records)
        }
        conflicts.formIntersection(active)
        conflictMessages = conflictMessages.filter { active.contains($0.key) }
        recoveryFailures = recoveryFailures.filter { active.contains($0.key) }
        serviceGroups = serviceGroups.reduce(into: [:]) { result, entry in
            if active.contains(entry.key) { result[entry.key] = entry.value.intersection(active) }
        }
    }

    private func save(_ values: [RecoveryRecord]) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(values)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            journalError = nil
            return true
        } catch {
            journalError = "Recovery state could not be saved. No new pointer changes will be applied."
            return false
        }
    }
}
