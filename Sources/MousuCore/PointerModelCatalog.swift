import Darwin
import Foundation

/// A small, immutable catalog loaded once. Nothing here runs in an input callback.
/// Imported rules classify presentation; they never enable a hardware capability.
public struct PointerModelCatalog: Sendable {
    public struct Rule: Codable, Equatable, Sendable {
        public let pattern: String
        public let kind: DeviceKind

        public init(pattern: String, kind: DeviceKind) {
            self.pattern = pattern
            self.kind = kind
        }
    }

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let source: String
        let rules: [Rule]
    }

    private struct USBNames: Decodable, Sendable {
        var vendors: [String: String] = [:]
        var products: [String: String] = [:]
    }

    public let source: String
    public let rules: [Rule]
    public var isAvailable: Bool { !rules.isEmpty }

    public init(source: String, rules: [Rule]) {
        self.source = source
        self.rules = rules
    }

    private static let resourceURL: URL? = {
        // SwiftPM's accessor knows the command-line build path. In an app,
        // use only packaged resources so missing data cannot crash or silently
        // fall back to the developer's checkout.
        if Bundle.main.bundleURL.pathExtension != "app" { return Bundle.module.bundleURL }
        let locations = [Bundle.main.resourceURL, Bundle.main.bundleURL]
        return locations.compactMap { $0?.appendingPathComponent("Mousu_MousuCore.bundle") }
            .first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("PointerModels.json").path) }
    }()

    public static let bundled: Self = {
        guard let url = resourceURL?.appendingPathComponent("PointerModels.json"),
            let data = try? Data(contentsOf: url),
            let catalog = try? JSONDecoder().decode(Catalog.self, from: data), catalog.schemaVersion == 1
        else { return Self(source: "Unavailable", rules: []) }
        return Self(source: catalog.source, rules: catalog.rules)
    }()

    // Name fallback is loaded lazily, independently from the much smaller type catalog.
    private static let usbNames: USBNames = {
        guard let url = resourceURL?.appendingPathComponent("USBNames.json"),
            let data = try? Data(contentsOf: url),
            let names = try? JSONDecoder().decode(USBNames.self, from: data)
        else { return USBNames() }
        return names
    }()

    public func kind(
        transport: String, vendorID: Int64?, productID: Int64?, productName: String,
        hardware: PointerHardwareFacts
    ) -> (kind: DeviceKind, source: String?) {
        if hardware.isTouchpad { return (.trackpad, "HID touchpad capability") }
        guard let bus = DeviceTransport(hidValue: transport) else { return (.mouse, nil) }
        let ids = String(format: "v%04xp%04x", Int(vendorID ?? 0), Int(productID ?? 0))
        let key = "mouse:\(bus.rawValue):\(ids):name:\(productName):"
        let matches = rules.filter { rule in
            rule.pattern.withCString { pattern in key.withCString { fnmatch(pattern, $0, 0) == 0 } }
        }
        // Conflicting external facts never produce a confident classification.
        let kinds = Set(matches.map { $0.kind.rawValue })
        if kinds.count == 1, let match = matches.first { return (match.kind, source) }
        return (.mouse, nil)
    }

    public static var usbProductNameCount: Int { usbNames.products.count }

    public static func fallbackUSBName(vendorID: Int64?, productID: Int64?) -> String? {
        guard let vendorID, (1...65535).contains(vendorID) else { return nil }
        let vendor = String(format: "%04x", Int(vendorID))
        if let productID, (1...65535).contains(productID),
            let product = usbNames.products[vendor + ":" + String(format: "%04x", Int(productID))]
        {
            return product
        }
        return usbNames.vendors[vendor].map { "\($0) pointer" }
    }
}
