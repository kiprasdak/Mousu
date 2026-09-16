import MousuCore
import SwiftUI

struct CatalogConnectionOption: Equatable, Identifiable {
    let fingerprint: DeviceModelFingerprint?
    let detected: String
    let override: DeviceConnectionType?
    var isConnected = false
    var label: String { override?.title ?? detected }
    var id: String { fingerprint.map { "\($0.summary) \($0.function.rawValue)" } ?? "unknown" }
}

@MainActor
struct DeviceConnectionLabel: View {
    @Bindable var model: AppModel
    let deviceKey: String

    var body: some View {
        if let entry = model.catalogDevices.first(where: { $0.id == deviceKey }) {
            Menu {
                DeviceConnectionActions(model: model, deviceKey: deviceKey)
            } label: {
                Text(entry.transport)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!model.canOrganizeDevices)
            .help("Change the connection label")
            .accessibilityLabel("Connection type: \(entry.transport)")
        }
    }
}

@MainActor
struct DeviceConnectionActions: View {
    @Bindable var model: AppModel
    let deviceKey: String

    var body: some View {
        let options = model.connectionOptions(for: deviceKey)
        if options.count == 1, let option = options.first {
            choices(option)
        } else {
            ForEach(options) { option in
                // IDs disambiguate two USB connections that have the same label.
                Menu(
                    "\(option.label)\(option.isConnected ? " — Connected" : "") · \(option.fingerprint.map { String(format: "%04X:%04X", $0.vendorID, $0.productID) } ?? "")"
                ) {
                    choices(option)
                }
            }
        }
    }

    private func choices(_ option: CatalogConnectionOption) -> some View {
        Picker(
            "Connection type",
            selection: Binding(
                get: { option.override },
                set: { model.setConnectionType($0, key: deviceKey, fingerprint: option.fingerprint) }
            )
        ) {
            Text("Automatic (\(option.detected))").tag(DeviceConnectionType?.none)
            ForEach(DeviceConnectionType.allCases, id: \.self) { type in
                Text(type.title).tag(Optional(type))
            }
        }
        .pickerStyle(.inline)
    }
}

@MainActor
struct IncludeConnectionMenu: View {
    @Bindable var model: AppModel
    let deviceKey: String

    var body: some View {
        let choices = model.matchingCardChoices(for: deviceKey)
        if !choices.isEmpty {
            Menu("Add to matching card", systemImage: "square.stack.3d.up.badge.plus") {
                ForEach(choices) { target in
                    Button(target.name) {
                        do { try model.includeConnection(deviceKey, in: target.id) } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                    .help("Use this card’s settings for this connection and future matches.")
                }
            }
            .disabled(!model.canOrganizeDevices)
        }
    }
}
