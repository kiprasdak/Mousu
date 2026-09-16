import Foundation

public enum PointerMode: String, Codable, CaseIterable, Sendable {
    case system, flat
}

public enum ScrollMode: String, Codable, CaseIterable, Sendable {
    case system, fixed
}

public enum ScrollDirection: String, Codable, CaseIterable, Sendable {
    case system, natural, traditional
}

public enum DeviceKind: String, Codable, CaseIterable, Sendable {
    case mouse, trackball, trackpad, other
}

public struct DeviceProfile: Codable, Equatable, Sendable {
    public var name: String
    public var enabled: Bool
    public var pointerMode: PointerMode
    public var pointerSpeed: Double
    public var scrollMode: ScrollMode
    public var linesPerStep: Double
    public var scrollSpeed: Double
    public var verticalDirection: ScrollDirection
    public var horizontalDirection: ScrollDirection
    public var directionsLinked: Bool

    public init(
        name: String = "", enabled: Bool = false,
        pointerMode: PointerMode = .system, pointerSpeed: Double = 1,
        scrollMode: ScrollMode = .system, linesPerStep: Double = 3,
        scrollSpeed: Double = 1, verticalDirection: ScrollDirection = .system,
        horizontalDirection: ScrollDirection = .system, directionsLinked: Bool = true
    ) {
        self.name = name
        self.enabled = enabled
        self.pointerMode = pointerMode
        self.pointerSpeed = pointerSpeed
        self.scrollMode = scrollMode
        self.linesPerStep = linesPerStep
        self.scrollSpeed = scrollSpeed
        self.verticalDirection = verticalDirection
        self.horizontalDirection = horizontalDirection
        self.directionsLinked = directionsLinked
        normalize()
    }

    public static let speedEntryRange = 0.01...10.0
    public static let stepEntryRange = 0.1...100.0

    /// Validate at every boundary: public mutable fields can also be changed by UI bindings.
    public mutating func normalize() {
        name = String(name.prefix(120))
        pointerSpeed = Self.clamped(pointerSpeed, in: Self.speedEntryRange, fallback: 1)
        linesPerStep = Self.clamped(linesPerStep, in: Self.stepEntryRange, fallback: 3)
        scrollSpeed = Self.clamped(scrollSpeed, in: Self.speedEntryRange, fallback: 1)
    }

    public func normalized() -> Self {
        var result = self
        result.normalize()
        return result
    }

    private static func clamped(_ value: Double, in bounds: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(bounds.upperBound, max(bounds.lowerBound, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case name, enabled, pointerMode, pointerSpeed, scrollMode, linesPerStep
        case scrollSpeed, verticalDirection, horizontalDirection, directionsLinked
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let vertical = try container.decodeIfPresent(ScrollDirection.self, forKey: .verticalDirection) ?? .system
        let horizontal = try container.decodeIfPresent(ScrollDirection.self, forKey: .horizontalDirection) ?? .system
        // Existing independent choices survive migration; new profiles start linked.
        let linked = try container.decodeIfPresent(Bool.self, forKey: .directionsLinked) ?? (vertical == horizontal)
        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "",
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            pointerMode: try container.decodeIfPresent(PointerMode.self, forKey: .pointerMode) ?? .system,
            pointerSpeed: try container.decodeIfPresent(Double.self, forKey: .pointerSpeed) ?? 1,
            scrollMode: try container.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) ?? .system,
            linesPerStep: try container.decodeIfPresent(Double.self, forKey: .linesPerStep) ?? 3,
            scrollSpeed: try container.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1,
            verticalDirection: vertical, horizontalDirection: horizontal, directionsLinked: linked
        )
    }
}

public struct DeviceIdentity: Codable, Hashable, Sendable {
    public var key: String
    public var persistent: Bool

    public init(key: String, persistent: Bool) {
        self.key = key
        self.persistent = persistent
    }
}

public struct DeviceCapabilities: Codable, Equatable, Sendable {
    public var supportsFlat: Bool
    public var supportsPointerSpeed: Bool
    public var supportsScroll: Bool
    public var isContinuous: Bool

    public init(
        supportsFlat: Bool = false, supportsPointerSpeed: Bool = false,
        supportsScroll: Bool = false, isContinuous: Bool = false
    ) {
        self.supportsFlat = supportsFlat
        self.supportsPointerSpeed = supportsPointerSpeed
        self.supportsScroll = supportsScroll
        self.isContinuous = isContinuous
    }
}

public struct DeviceInfo: Identifiable, Equatable, Sendable {
    public var id: UInt64
    /// All event-service senders belonging to this physical connection.
    public var serviceIDs: [UInt64]
    public var identity: DeviceIdentity
    public var name: String
    public var transport: String
    public var kind: DeviceKind
    public var capabilities: DeviceCapabilities
    public var model: DeviceModelMetadata

    public init(
        id: UInt64, identity: DeviceIdentity, name: String, transport: String,
        kind: DeviceKind, capabilities: DeviceCapabilities, serviceIDs: [UInt64]? = nil,
        model: DeviceModelMetadata = .init()
    ) {
        self.id = id
        self.serviceIDs = Array(Set(serviceIDs ?? [id])).sorted()
        self.identity = identity
        self.name = name
        self.transport = transport
        self.kind = kind
        self.capabilities = capabilities
        self.model = model
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public static let currentVersion = 5
    public var version: Int
    public var profiles: [String: DeviceProfile]
    public var menuBarVisible: Bool
    public var hideDockWhenClosed: Bool
    public var launchAtLogin: Bool
    public var paused: Bool
    public var automaticallySetUpDevices: Bool
    public var hasCompletedSetup: Bool
    public var deviceCatalog: [String: RememberedDevice]
    public var deviceOrder: [String]
    public var modelProfiles: [String: SharedModelProfile]
    public var connectionLabels: [ConnectionLabelOverride]
    /// Legacy saved profiles migrate as individual overrides. Newly seeded
    /// automatic defaults do not block a later explicitly created model rule.
    public var individualProfileKeys: Set<String>
    /// Pause belongs to a device, even when its input settings are shared.
    public var devicePauseOverrides: [String: Bool]
    /// Identifiers proven non-unique must not regain trust on the next launch.
    public var ambiguousIdentityKeys: Set<String>
    /// Inert historical settings. These are never consulted for a live connection.
    public var archivedSessionProfiles: [String: ArchivedSessionProfile]

    public init(
        version: Int = Self.currentVersion, profiles: [String: DeviceProfile] = [:],
        menuBarVisible: Bool = true, hideDockWhenClosed: Bool = true, launchAtLogin: Bool = false, paused: Bool = false,
        automaticallySetUpDevices: Bool = true, hasCompletedSetup: Bool = false,
        deviceCatalog: [String: RememberedDevice] = [:], deviceOrder: [String] = [],
        modelProfiles: [String: SharedModelProfile] = [:], individualProfileKeys: Set<String>? = nil,
        devicePauseOverrides: [String: Bool] = [:], ambiguousIdentityKeys: Set<String> = [],
        archivedSessionProfiles: [String: ArchivedSessionProfile] = [:],
        connectionLabels: [ConnectionLabelOverride] = []
    ) {
        self.version = version
        self.profiles = profiles.mapValues { $0.normalized() }
        self.menuBarVisible = menuBarVisible
        self.hideDockWhenClosed = hideDockWhenClosed
        self.launchAtLogin = launchAtLogin
        self.paused = paused
        self.automaticallySetUpDevices = automaticallySetUpDevices
        self.hasCompletedSetup = hasCompletedSetup
        self.deviceCatalog = deviceCatalog
        self.deviceOrder = deviceOrder
        self.modelProfiles = modelProfiles
        self.connectionLabels = connectionLabels
        self.individualProfileKeys = individualProfileKeys ?? Set(profiles.keys.filter { !$0.hasPrefix("session:") })
        self.devicePauseOverrides = devicePauseOverrides
        self.ambiguousIdentityKeys = ambiguousIdentityKeys
        self.archivedSessionProfiles = archivedSessionProfiles
        normalize()
    }

    private enum CodingKeys: String, CodingKey {
        case version, profiles, menuBarVisible, hideDockWhenClosed, launchAtLogin, paused, automaticallySetUpDevices
        case hasCompletedSetup, deviceCatalog, deviceOrder, modelProfiles, individualProfileKeys, devicePauseOverrides
        case ambiguousIdentityKeys, archivedSessionProfiles, connectionLabels
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .version)
        guard (1...Self.currentVersion).contains(storedVersion) else {
            throw PreferencesStoreError.unsupportedVersion(storedVersion)
        }
        self.init(
            version: Self.currentVersion,
            profiles: try container.decode([String: DeviceProfile].self, forKey: .profiles),
            menuBarVisible: try container.decode(Bool.self, forKey: .menuBarVisible),
            hideDockWhenClosed: try container.decodeIfPresent(Bool.self, forKey: .hideDockWhenClosed) ?? true,
            launchAtLogin: try container.decode(Bool.self, forKey: .launchAtLogin),
            paused: try container.decode(Bool.self, forKey: .paused),
            automaticallySetUpDevices: try container.decodeIfPresent(Bool.self, forKey: .automaticallySetUpDevices)
                ?? false,
            hasCompletedSetup: try container.decodeIfPresent(Bool.self, forKey: .hasCompletedSetup) ?? false,
            deviceCatalog: try container.decodeIfPresent([String: RememberedDevice].self, forKey: .deviceCatalog)
                ?? [:],
            deviceOrder: try container.decodeIfPresent([String].self, forKey: .deviceOrder) ?? [],
            modelProfiles: try container.decodeIfPresent([String: SharedModelProfile].self, forKey: .modelProfiles)
                ?? [:],
            individualProfileKeys: try container.decodeIfPresent(Set<String>.self, forKey: .individualProfileKeys),
            devicePauseOverrides: try container.decodeIfPresent([String: Bool].self, forKey: .devicePauseOverrides)
                ?? [:],
            ambiguousIdentityKeys: try container.decodeIfPresent(Set<String>.self, forKey: .ambiguousIdentityKeys)
                ?? [],
            archivedSessionProfiles: try container.decodeIfPresent(
                [String: ArchivedSessionProfile].self, forKey: .archivedSessionProfiles) ?? [:],
            connectionLabels: try container.decodeIfPresent([ConnectionLabelOverride].self, forKey: .connectionLabels)
                ?? []
        )
        if storedVersion == 1 { rememberLegacyProfiles() }
    }

    public mutating func normalize() {
        profiles = profiles.mapValues { $0.normalized() }
        normalizeDeviceCatalog()
        normalizeModelProfiles()
        archivedSessionProfiles = archivedSessionProfiles.mapValues {
            var archive = $0
            archive.settings.normalize()
            return archive
        }
    }
}
