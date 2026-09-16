import MousuCore
import SwiftUI

extension CatalogDevice {
    /// Keep the identity problem and its resolution consistent in every detail view.
    var matchingDeviceExplanation: String? {
        guard isModelCard || !identityPersistent else { return nil }
        if isModelCard && capturesAllMatches && matchingExplanationDismissed { return nil }
        let identityWarning = identityPersistent ? "" : "This device has no unique identifier. "
        if isModelCard && capturesAllMatches {
            return identityWarning
                + "Mousü matches the model instead. Matching devices share this card and use its settings automatically when they connect."
        }
        if !identityPersistent {
            return
                "This device has no unique identifier. Its next connection will appear as a separate device; these settings won’t be applied automatically."
        }
        return "Its next connection will appear as a separate device; these settings won’t be applied automatically."
    }
}

/// A direct conversion of the current card, without an assignment dialog.
@MainActor
struct DeviceProfileControl: View {
    @Bindable var model: AppModel
    let deviceKey: String
    var compact = false
    var showsExplanation = true
    var alignment: HorizontalAlignment = .leading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var error: String?
    @State private var hoveringExplanation = false
    @FocusState private var dismissFocused: Bool

    private var entry: CatalogDevice? { model.catalogDevices.first { $0.id == deviceKey } }

    var body: some View {
        if let entry {
            let explanation = entry.matchingDeviceExplanation
            let target =
                !entry.isModelCard && !entry.identityPersistent
                ? model.suggestedMatchingCard(for: entry.id) : nil
            if explanation != nil || target != nil {
                VStack(alignment: alignment, spacing: compact ? 5 : 8) {
                    if showsExplanation, let explanation {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if entry.isModelCard && entry.capturesAllMatches {
                                Button {
                                    model.dismissMatchingExplanation(for: entry.id)
                                } label: {
                                    explanationIcon(for: entry, showsDismiss: hoveringExplanation || dismissFocused)
                                }
                                .buttonStyle(.plain)
                                .focused($dismissFocused)
                                .help("Dismiss message")
                                .accessibilityLabel("Dismiss message")
                                .disabled(!model.canOrganizeDevices)
                            } else {
                                explanationIcon(for: entry)
                                    .accessibilityHidden(true)
                            }
                            Text(explanation)
                                .contentTransition(.interpolate)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onHover { hoveringExplanation = $0 }
                    }
                    if let target {
                        Button("Include in “\(target.name)”") {
                            do { try model.includeConnection(entry.id, in: target.id) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        .buttonStyle(.link)
                        .disabled(!model.canOrganizeDevices)
                        .help("Use the existing card’s settings over this connection, now and on reconnect.")
                    }
                    if explanation != nil && (!entry.isModelCard || !entry.capturesAllMatches) {
                        captureButton(entry)
                    }
                }
                .font(.system(size: compact ? 10 : 11))
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: explanation)
                .alert(
                    "Couldn’t match devices",
                    isPresented: Binding(
                        get: { error != nil }, set: { if !$0 { error = nil } }
                    )
                ) {
                    Button("OK") { error = nil }
                } message: {
                    Text(error ?? "")
                }
            }
        }
    }
    private func explanationIcon(for entry: CatalogDevice, showsDismiss: Bool = false) -> some View {
        ZStack {
            Image(systemName: entry.isModelCard && entry.capturesAllMatches ? "square.stack" : "cable.connector")
                .font(.system(size: compact ? 10 : 11))
                .opacity(showsDismiss ? 0 : 1)
            Text("×")
                .font(.system(size: 14, weight: .light))
                .opacity(showsDismiss ? 1 : 0)
        }
        // Both messages use the same icon slot and first-line baseline.
        .frame(width: 14, height: 14)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsDismiss)
    }

    private func captureButton(_ entry: CatalogDevice) -> some View {
        Button("Use for all matching devices") {
            do { try model.captureModelCard(entry.id) } catch { self.error = error.localizedDescription }
        }
        .buttonStyle(.link)
        .disabled(!model.canOrganizeDevices || !entry.isManaged || entry.modelMetadata?.fingerprint == nil)
        .help(
            entry.modelMetadata?.fingerprint == nil
                ? (entry.isConnected
                    ? "This device does not expose enough model information to match safely."
                    : "This old card has no model information. Reconnect the device and use this action on its new card.")
                : "Keep this card and apply its settings to all devices with the same model identity, now and on reconnect. Hidden devices remain excluded."
        )
    }

}
