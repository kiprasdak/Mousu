import Foundation

/// This is a model match, never a physical device identity. Bluetooth spelling
/// variants are equivalent, but USB and Bluetooth are separate scopes.
public enum DeviceTransport: String, Codable, Sendable {
    case usb, bluetooth

    public init?(hidValue: String) {
        switch hidValue.lowercased().filter({ !$0.isWhitespace && $0 != "-" }) {
        case "usb": self = .usb
        case "bluetooth", "bluetoothlowenergy", "ble": self = .bluetooth
        default: return nil
        }
    }

    public var title: String { self == .usb ? "USB" : "Bluetooth" }
}

public enum PointerFunction: String, Codable, Sendable {
    case relativePointer, touchpad, genericPointer
}

public struct DeviceModelFingerprint: Codable, Hashable, Sendable {
    public let transport: DeviceTransport
    public let vendorID: Int64
    public let productID: Int64
    public let function: PointerFunction

    public init?(transport: String, vendorID: Int64?, productID: Int64?, function: PointerFunction) {
        guard let transport = DeviceTransport(hidValue: transport),
            let vendorID, (1...65535).contains(vendorID),
            let productID, (1...65535).contains(productID)
        else { return nil }
        self.transport = transport
        self.vendorID = vendorID
        self.productID = productID
        self.function = function
    }

    public var isValid: Bool {
        (1...65535).contains(vendorID) && (1...65535).contains(productID)
    }

    public var summary: String {
        "\(transport.title) · " + String(format: "%04X:%04X", vendorID, productID)
    }
}

public struct DeviceModelMetadata: Codable, Equatable, Sendable {
    public var fingerprint: DeviceModelFingerprint?
    /// The discovered product name is distinct from a user's display name.
    public var productName: String
    /// Discovery marks catalog/default labels so they cannot authorize automatic grouping.
    public var productNameIsFallback: Bool?
    public var manufacturer: String?
    public var classificationSource: String?

    public init(
        fingerprint: DeviceModelFingerprint? = nil, productName: String = "",
        manufacturer: String? = nil, classificationSource: String? = nil, productNameIsFallback: Bool? = nil
    ) {
        self.fingerprint = fingerprint
        self.productName = String(productName.prefix(256))
        self.productNameIsFallback = productNameIsFallback
        self.manufacturer = manufacturer.map { String($0.prefix(256)) }
        self.classificationSource = classificationSource
    }
}

/// HID collection information and observed event behavior are the only inputs
/// to capability decisions. Model catalog entries affect presentation only.
public struct PointerHardwareFacts: Equatable, Sendable {
    public var isTouchpad: Bool
    public var hasRelativeAxes: Bool
    public var supportsLinearScaling: Bool
    public var reportsScroll: Bool
    public var observedContinuousScroll: Bool

    public init(
        isTouchpad: Bool = false, hasRelativeAxes: Bool = false,
        supportsLinearScaling: Bool = false, reportsScroll: Bool = false,
        observedContinuousScroll: Bool = false
    ) {
        self.isTouchpad = isTouchpad
        self.hasRelativeAxes = hasRelativeAxes
        self.supportsLinearScaling = supportsLinearScaling
        self.reportsScroll = reportsScroll
        self.observedContinuousScroll = observedContinuousScroll
    }

    public var function: PointerFunction {
        isTouchpad ? .touchpad : hasRelativeAxes ? .relativePointer : .genericPointer
    }

    public var capabilities: DeviceCapabilities {
        let flat = hasRelativeAxes && supportsLinearScaling && !isTouchpad
        return DeviceCapabilities(
            supportsFlat: flat, supportsPointerSpeed: flat,
            supportsScroll: reportsScroll || isTouchpad || observedContinuousScroll,
            isContinuous: isTouchpad || observedContinuousScroll)
    }
}
