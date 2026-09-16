import Foundation

public struct DeviceIdentityCandidate: Sendable, Equatable {
    public var registryID: UInt64
    public var vendorID: Int64?
    public var productID: Int64?
    public var transport: String
    public var serialNumber: String?
    public var uniqueID: String?
    public var alternateUniqueID: String?

    public init(
        registryID: UInt64, vendorID: Int64? = nil, productID: Int64? = nil,
        transport: String = "", serialNumber: String? = nil, uniqueID: String? = nil, alternateUniqueID: String? = nil
    ) {
        self.registryID = registryID
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.serialNumber = serialNumber
        self.uniqueID = uniqueID
        self.alternateUniqueID = alternateUniqueID
    }

    var stableKey: String? {
        let source: String
        let value: String
        if let uniqueID = Self.cleanIdentifier(uniqueID) ?? Self.cleanIdentifier(alternateUniqueID) {
            source = "uid"
            value = uniqueID
        } else if let serial = Self.cleanIdentifier(serialNumber) {
            source = "serial"
            value = serial
        } else {
            return nil
        }
        // Length-prefixed components make delimiters in manufacturer strings unambiguous.
        let components = [
            String(vendorID ?? -1), String(productID ?? -1),
            transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), source, value,
        ]
        return "hid:" + components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    public static func cleanIdentifier(_ value: String?) -> String? {
        guard let result = value?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty,
            result.utf8.count <= 512,
            !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        let lower = result.lowercased()
        if ["unknown", "none", "null", "(null)", "n/a", "not available", "default", "serialnumber"].contains(lower) {
            return nil
        }
        // Ignore all-zero placeholders regardless of length or UUID formatting.
        let digits = lower.filter { $0 != "-" && $0 != ":" && !$0.isWhitespace }
        if digits.isEmpty || digits.allSatisfy({ $0 == "0" }) { return nil }
        if digits.count >= 8 && digits.allSatisfy({ $0 == "f" }) { return nil }
        return result
    }
}

public struct DeviceIdentityResolver: Sendable {
    public let sessionID: String
    public private(set) var ambiguousKeys: Set<String>

    public init(sessionID: String = UUID().uuidString, knownAmbiguousKeys: Set<String> = []) {
        self.sessionID = sessionID
        ambiguousKeys = knownAmbiguousKeys
    }

    /// Seed before discovery, or merge newly loaded evidence without clearing
    /// identifiers found ambiguous during this process.
    public mutating func distrust(_ keys: Set<String>) {
        ambiguousKeys.formUnion(keys)
    }

    /// Duplicate stable identifiers stay untrusted; persist ambiguousKeys across launches.
    /// A product ID, registry ID or USB location is never treated as a durable identity.
    public mutating func resolve(_ candidates: [DeviceIdentityCandidate]) -> [UInt64: DeviceIdentity] {
        let grouped = Dictionary(
            grouping: candidates.compactMap { candidate -> (String, UInt64)? in
                candidate.stableKey.map { ($0, candidate.registryID) }
            }, by: { $0.0 })
        for (key, entries) in grouped where Set(entries.map { $0.1 }).count > 1 {
            ambiguousKeys.insert(key)
        }
        var result: [UInt64: DeviceIdentity] = [:]
        for candidate in candidates {
            if let key = candidate.stableKey, !ambiguousKeys.contains(key) {
                result[candidate.registryID] = DeviceIdentity(key: key, persistent: true)
            } else {
                result[candidate.registryID] = DeviceIdentity(
                    key: "session:\(sessionID):\(candidate.registryID)", persistent: false
                )
            }
        }
        return result
    }
}
