import AppKit
import Metal
import MousuCore
import QuartzCore
import SwiftUI

private enum AppCopy {
    static let tagline = "Unweird your pointer :)"
}

private enum Palette {
    static let blue = Color(red: 0.22, green: 0.46, blue: 0.98)
    static let quiet = Color.primary.opacity(0.045)
    static let border = Color.primary.opacity(0.065)
}

private struct CompactToolbarButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

enum MainWindowSize {
    static let intro = main
    static let main = CGSize(width: 1020, height: 650)
}

@MainActor
struct MainView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.displayScale) private var displayScale
    private let sidebarWidth: CGFloat = 240
    @State private var sidebarCardWidth: CGFloat?
    @State private var noticeHeight: CGFloat = 0
    @State private var crtPlayback = CRTPlaybackState()
    @State private var refreshAnimation = 0
    @State private var hoveringRefresh = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !model.requiresSetup {
                HStack(spacing: 0) {
                    sidebar
                    mainContent
                }
            } else {
                PermissionOnboarding(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Palette.blue)
        .frame(
            minWidth: model.requiresSetup ? MainWindowSize.intro.width : MainWindowSize.main.width,
            minHeight: model.requiresSetup ? MainWindowSize.intro.height : MainWindowSize.main.height
        )
        .modifier(CatalogDragOverlay(model: model))
        .toolbar {
            if !model.requiresSetup {
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 4) {
                        if !model.paused {
                            Button {
                                model.paused = true
                            } label: {
                                Label("Pause all", systemImage: "pause.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 6)
                                    .frame(height: 28)
                            }
                            .labelStyle(.titleAndIcon)
                            .help("Restore system settings and pause all devices")
                        }
                        Button {
                            model.settingsPresented = true
                        } label: {
                            Image(systemName: model.settingsPresented ? "gearshape.fill" : "gearshape")
                                .font(.system(size: 16))
                                .frame(width: 28, height: 28)
                        }
                        .disabled(model.settingsPresented)
                        .accessibilityLabel("Mousü settings")
                        .help(model.settingsPresented ? "Mousü settings are already open" : "Mousü settings")
                    }
                    .buttonStyle(CompactToolbarButtonStyle())
                    .padding(4)
                    .glassEffect(.regular, in: Capsule())
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .background(
            SettingsSheetAlignment(sidebarWidth: sidebarWidth, isPresented: { model.settingsPresented })
        )
        .sheet(isPresented: $model.settingsPresented) {
            AppSettingsSheet(model: model)
        }
        .onAppear {
            MousuAppDelegate.reopenWindow = { openWindow(id: "main") }
            model.presentSetup()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        .onChange(of: model.requiresSetup) { _, requiresSetup in
            if requiresSetup { model.settingsPresented = false }
        }
        .onDisappear { model.settingsPresented = false }
        .alert(
            "Couldn’t complete the action",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AppMark(size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mousü").font(.system(size: 19, weight: .semibold, design: .rounded))
                    Text(AppCopy.tagline)
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 21)
            .padding(.top, 21)
            .padding(.bottom, 34)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    Text("YOUR DEVICES").font(.system(size: 10, weight: .semibold)).tracking(1.2)
                    Spacer()
                    CatalogVisibilityMenu(model: model)
                    Button {
                        refreshAnimation += 1
                        model.refresh()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .medium))
                            .symbolEffect(
                                .rotate, options: .nonRepeating.speed(1.5), value: reduceMotion ? 0 : refreshAnimation
                            )
                            .frame(width: 22, height: 22)
                            .background(
                                Color.primary.opacity(hoveringRefresh ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringRefresh = $0 }
                    .help("Refresh connected devices")
                    .accessibilityLabel("Refresh connected devices")
                }
                if model.catalogDevices.isEmpty && model.hiddenDeviceCount > 0 {
                    Text("\(model.hiddenDeviceCount) hidden")
                        .font(.system(size: 10))
                } else {
                    Text("\(model.connectedDeviceCount) connected")
                        .font(.system(size: 10))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.leading, 23)
            .padding(.trailing, max(11, sidebarWidth - 11 - (sidebarCardWidth ?? (sidebarWidth - 22))))
            .padding(.bottom, 11)

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 8) {
                        DeviceCatalogGrid(
                            model: model, columns: 1,
                            selectedID: model.selectedCatalogDevice?.id,
                            selectionHelp: { _ in "Show device settings" }
                        ) { entry in
                            model.selectCatalogDevice(entry.id)
                        }
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width
                        } action: { width in
                            // Measure the actual card column after macOS reserves scrollbar space.
                            sidebarCardWidth = width
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.bottom, 16)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .contentShape(Rectangle())
                    .contextMenu { CatalogVisibilityActions(model: model) }
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(.hidden)
                .clipped()
            }

        }
        .frame(width: sidebarWidth)
        .background {
            Rectangle().fill(.regularMaterial)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Palette.border).frame(width: 1 / displayScale)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    private var mainContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.paused {
                        GlobalPauseBanner(model: model)
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                noticeHeight = $0
                            }
                    }

                    if let entry = model.selectedCatalogDevice {
                        if let device = entry.connection {
                            DeviceEditor(
                                model: model, device: device, profile: entry.profile, isManaged: entry.isManaged,
                                crtPlayback: crtPlayback)
                        } else {
                            DisconnectedDeviceDetail(model: model, entry: entry)
                        }
                    } else {
                        emptyState
                    }
                }
                .environment(
                    \.deviceEditorHeight,
                    max(
                        0,
                        geometry.size.height - 53
                            - (model.paused ? noticeHeight + 20 : 0))
                )
                .padding(.horizontal, 30)
                .padding(.top, 25)
                .padding(.bottom, 28)
                .frame(maxWidth: 1040)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollIndicators(.automatic)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "computermouse")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Palette.blue)
                .frame(width: 100, height: 100)
                .background(Palette.blue.opacity(0.075), in: RoundedRectangle(cornerRadius: 30))
            VStack(spacing: 9) {
                Text(
                    model.catalogDevices.isEmpty && model.hiddenDeviceCount > 0
                        ? "Your devices are hidden"
                        : (model.catalogDevices.isEmpty ? "No pointers connected" : "Choose a pointer")
                )
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                Text(
                    model.catalogDevices.isEmpty && model.hiddenDeviceCount > 0
                        ? "Show hidden devices from the sidebar menu to manage them again."
                        : (model.catalogDevices.isEmpty
                            ? "Connect an external mouse, trackball, or trackpad to adjust its movement and scrolling."
                            : "Select a device in the sidebar to adjust its movement and scrolling.")
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            }
            .frame(maxWidth: 520)
            Button("Check for devices") { model.refresh() }
                .buttonStyle(.bordered)
                .controlSize(.large)
            if !model.bridgeAvailable {
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 350)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 480)
    }

}

@MainActor
private struct GlobalPauseBanner: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 19))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Mousü is paused").font(.system(size: 12, weight: .semibold))
                Text("All devices use their macOS settings.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Resume all") { model.paused = false }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Resume all devices")
        }
        .padding(14)
        .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DeviceEditorHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    fileprivate var deviceEditorHeight: CGFloat {
        get { self[DeviceEditorHeightKey.self] }
        set { self[DeviceEditorHeightKey.self] = newValue }
    }
}

/// Only the Try area grows; settings retain their intrinsic height.
private struct DeviceEditorLayout: Layout {
    let availableHeight: CGFloat
    private let spacing: CGFloat = 20

    private func heights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        guard subviews.count >= 2 else { return [] }
        let tryAreaIndex = subviews.count - 1
        var values = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: width, height: index == tryAreaIndex ? 122 : nil)).height
        }
        let fixedHeight =
            values.enumerated().filter { $0.offset != tryAreaIndex }.reduce(CGFloat(0)) { $0 + $1.element }
            + spacing * CGFloat(subviews.count - 1)
        values[tryAreaIndex] = max(122, min(width * 10 / 16, availableHeight - fixedHeight))
        return values
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 680
        let values = heights(width: width, subviews: subviews)
        return CGSize(width: width, height: values.reduce(0, +) + spacing * CGFloat(max(0, values.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let values = heights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, view) in subviews.enumerated() where index < values.count {
            view.place(
                at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: values[index]))
            y += values[index] + spacing
        }
    }
}

/// Both menus stay editable; the profile edit applies linked changes atomically.
private struct LinkedDirectionControls: View {
    @Binding var vertical: ScrollDirection
    @Binding var horizontal: ScrollDirection
    @Binding var linked: Bool
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if compact {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vertical direction").frame(height: 24)
                    Text("Horizontal direction").frame(height: 24)
                }
                .frame(width: 132, alignment: .leading)
                HStack(spacing: 6) {
                    linkButton
                    VStack(spacing: 6) {
                        directionMenu("Vertical direction", selection: $vertical)
                            .frame(height: 24)
                        directionMenu("Horizontal direction", selection: $horizontal)
                            .frame(height: 24)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.trailing, 44)  // Center the whole group over the slider tracks.
            .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 9) {
                Text("Vertical direction")
                    .font(.system(size: 12, weight: .medium))
                VStack(alignment: .leading, spacing: 18) {
                    directionMenu("Vertical direction", selection: $vertical)
                    directionMenu("Horizontal direction", selection: $horizontal)
                }
                .overlay(alignment: .leading) {
                    linkButton.offset(x: -35)  // Preserve the gap as the centered menus move with window width.
                }
                Text("Horizontal direction")
                    .font(.system(size: 12, weight: .medium))
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var linkButton: some View {
        Button {
            linked.toggle()
        } label: {
            DirectionLinkGlyph(connection: linked ? 1 : 0)
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .frame(width: 16, height: 24)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: linked)
                .frame(width: 24, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(linked ? "Unlink scroll directions" : "Link scroll directions")
        .accessibilityLabel("Link scroll directions")
        .accessibilityValue(linked ? "On" : "Off")
    }

    private func directionMenu(_ title: String, selection: Binding<ScrollDirection>) -> some View {
        Picker(title, selection: selection) {
            Text("Follow system").tag(ScrollDirection.system)
            Text("Natural").tag(ScrollDirection.natural)
            Text("Traditional").tag(ScrollDirection.traditional)
        }
        .labelsHidden()
        .fixedSize(horizontal: !compact, vertical: true)
    }
}

private struct DirectionLinkGlyph: Shape {
    var connection: CGFloat

    var animatableData: CGFloat {
        get { connection }
        set { connection = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 16
        let progress = min(1, max(0, connection))
        let centerX = rect.midX
        let left = centerX - 4 * scale
        let right = centerX + 4 * scale
        let top = rect.midY - (12 - 2.5 * progress) * scale
        let bottom = rect.midY + (12 - 2.5 * progress) * scale
        var path = Path()

        path.move(to: CGPoint(x: left, y: top + 7 * scale))
        path.addLine(to: CGPoint(x: left, y: top + 3.5 * scale))
        path.addQuadCurve(
            to: CGPoint(x: centerX, y: top), control: CGPoint(x: left, y: top))
        path.addQuadCurve(
            to: CGPoint(x: right, y: top + 3.5 * scale), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + 7 * scale))

        path.move(to: CGPoint(x: left, y: bottom - 7 * scale))
        path.addLine(to: CGPoint(x: left, y: bottom - 3.5 * scale))
        path.addQuadCurve(
            to: CGPoint(x: centerX, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addQuadCurve(
            to: CGPoint(x: right, y: bottom - 3.5 * scale), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: bottom - 7 * scale))

        if progress > 0 {
            path.move(to: CGPoint(x: centerX, y: rect.midY - 3 * progress * scale))
            path.addLine(to: CGPoint(x: centerX, y: rect.midY + 3 * progress * scale))
        }
        return path
    }
}

/// Names are presentation metadata; renaming never resumes or reapplies input settings.
private enum DeviceActionCenter: AlignmentID {
    static func defaultValue(in dimensions: ViewDimensions) -> CGFloat { dimensions[VerticalAlignment.center] }
}

extension VerticalAlignment {
    fileprivate static let deviceActionCenter = VerticalAlignment(DeviceActionCenter.self)
}

@MainActor
private struct DeviceNameHeading: View {
    @Bindable var model: AppModel
    let deviceKey: String
    let currentName: String
    var fontSize: CGFloat = 25
    var lineLimit = 2
    var spacing: CGFloat = 7
    var centersName = false
    @State private var hoveringName = false
    @State private var hoveringPencil = false
    @State private var renaming = false
    @FocusState private var renameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canRename: Bool { model.canOrganizeDevices }
    private var renameControlSize: CGFloat { max(24, fontSize * 1.44) }
    private var showsPencil: Bool { hoveringName || renameFocused || renaming }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: spacing) {
            Text(currentName)
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .lineLimit(lineLimit)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: beginRename)
                .accessibilityAction(named: "Rename device", beginRename)
            Button(action: beginRename) {
                Text(Image(systemName: "pencil"))
                    .font(.system(size: fontSize * 0.88, weight: .semibold))
                    .opacity(showsPencil ? 1 : 0)
                    .frame(width: renameControlSize, height: renameControlSize)
                    .background(
                        Color.primary.opacity(hoveringPencil ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .focused($renameFocused)
            .onHover { hoveringPencil = $0 }
            .alignmentGuide(.deviceActionCenter) { $0[VerticalAlignment.center] }
            .help("Rename this device")
            .accessibilityLabel("Rename this device")
            .disabled(!canRename)
        }
        // Balance the pencil's space so a centered title is anchored on its text.
        .padding(.leading, centersName ? renameControlSize + spacing : 0)
        .contentShape(Rectangle())
        .onHover { hoveringName = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: showsPencil)
        .sheet(isPresented: $renaming) {
            RenameDeviceSheet(model: model, deviceKey: deviceKey, currentName: currentName)
        }
    }

    private func beginRename() {
        guard canRename else { return }
        renaming = true
    }
}

@MainActor
private struct RenameDeviceSheet: View {
    @Bindable var model: AppModel
    let deviceKey: String
    @State private var draftName: String
    @FocusState private var nameFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, deviceKey: String, currentName: String) {
        self.model = model
        self.deviceKey = deviceKey
        _draftName = State(initialValue: currentName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Name this device").font(.title3.weight(.semibold))
            TextField("Device name", text: $draftName)
                .textContentType(nil)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { saveName(draftName) }
            HStack {
                Button("Use device name") { saveName("") }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { saveName(draftName) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { nameFocused = true }
    }

    private func saveName(_ name: String) {
        model.renameCatalogDevice(deviceKey, name: name)
        dismiss()
    }
}

@MainActor
private struct DeviceEditor: View {
    @Bindable var model: AppModel
    let device: DeviceInfo
    let profile: DeviceProfile
    let isManaged: Bool
    let crtPlayback: CRTPlaybackState
    @State private var hoveringReset = false
    @Environment(\.deviceEditorHeight) private var editorHeight

    private func binding<Value>(_ keyPath: WritableKeyPath<DeviceProfile, Value>) -> Binding<Value> {
        Binding {
            (model.profile(for: device.id) ?? profile)[keyPath: keyPath]
        } set: { value in
            guard var updated = model.profile(for: device.id) else { return }
            updated[keyPath: keyPath] = value
            model.editProfileSettings(updated, for: device.id)
        }
    }

    private var displayName: String { profile.name.isEmpty ? device.name : profile.name }

    private var settingsPaused: Bool { model.paused || profile.isDevicePaused || !isManaged }
    private var settingsAccent: Color { settingsPaused ? .gray : Palette.blue }

    private var inputEditingDisabled: Bool {
        settingsPaused || !model.bridgeAvailable
    }

    var body: some View {
        DeviceEditorLayout(availableHeight: editorHeight) {
            if !isManaged, let entry = model.catalogDevices.first(where: { $0.connection?.id == device.id }) {
                UnmanagedDeviceNotice(model: model, entry: entry)
            }
            header

            if !model.bridgeAvailable {
                StatusBanner(
                    symbol: "exclamationmark.circle", title: "Device control unavailable", detail: model.detail,
                    color: .orange)
            }

            HStack(alignment: .top, spacing: 16) {
                movementCard
                directionCard
                scrollingCard
            }
            .fixedSize(horizontal: false, vertical: true)
            .modifier(PausedSettingsAppearance(isPaused: settingsPaused))

            TryAreaCard(crtPlayback: crtPlayback)
                .disabled(!isManaged)
                .modifier(PausedSettingsAppearance(isPaused: settingsPaused))

        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center, spacing: 14) {
                DeviceIconButton(
                    model: model, deviceKey: device.identity.key, kind: device.kind, size: 61, symbolSize: 31,
                    fallbackColor: isManaged ? Palette.blue : .orange)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .deviceActionCenter, spacing: 0) {
                        DeviceNameHeading(model: model, deviceKey: device.identity.key, currentName: displayName)
                        Spacer(minLength: 0)
                        Button {
                            model.resetSettings(for: device.id)
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 19, weight: .regular))
                                .frame(width: 36, height: 36)
                                .background(
                                    Color.primary.opacity(hoveringReset ? 0.08 : 0),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .onHover { hoveringReset = $0 }
                        .help("Reset movement and scrolling settings")
                        .accessibilityLabel("Reset device settings")
                        .disabled(inputEditingDisabled)
                        .alignmentGuide(.deviceActionCenter) { $0[VerticalAlignment.center] }
                    }
                    HStack(spacing: 5) {
                        Text("Connected")
                        if let entry = model.catalogDevices.first(where: { $0.id == device.identity.key }),
                            entry.connectionCount > 1
                        {
                            DeviceConnectionCountBadge(count: entry.connectionCount)
                        }
                        if !isManaged || !model.bridgeAvailable || settingsPaused {
                            Text("·")
                            Text(!isManaged ? "Not managed" : !model.bridgeAvailable ? "Unavailable" : "Paused")
                                .foregroundStyle(.orange)
                        }
                        Text("·")
                        DeviceConnectionLabel(model: model, deviceKey: device.identity.key)
                    }
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }

            }
            DeviceProfileControl(model: model, deviceKey: device.identity.key)
        }
    }

    private var movementCard: some View {
        SettingsCard(
            title: "Movement", symbol: "cursorarrow"
        ) {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Response").font(.system(size: 12, weight: .medium))
                    Picker("Response", selection: binding(\.pointerMode)) {
                        Text("System").tag(PointerMode.system)
                        Text("Flat").tag(PointerMode.flat)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .buttonSizing(.flexible)
                    .frame(maxWidth: .infinity)
                    .disabled(!device.capabilities.supportsFlat)
                    .help("System uses macOS acceleration. Flat keeps movement consistent at any hand speed.")
                }
                Spacer(minLength: 0)
                ValueSlider(
                    title: "Speed", value: binding(\.pointerSpeed), range: PointerSpeedScale.range,
                    step: 0.05, centeredSpeed: true,
                    isActive: profile.pointerMode == .flat && device.capabilities.supportsPointerSpeed
                )
                .help(
                    profile.pointerMode == .flat
                        ? "Adjust pointer speed for this device."
                        : "Choose Flat response to adjust speed for this device.")
                if !device.capabilities.supportsFlat {
                    capabilityNote("Flat movement isn’t available for this device.")
                }
            }
        }
        .disabled(inputEditingDisabled)
    }

    private var directionCard: some View {
        SettingsCard(title: "Scroll direction", symbol: "arrow.up.arrow.down") {
            if device.capabilities.supportsScroll {
                LinkedDirectionControls(
                    vertical: binding(\.verticalDirection), horizontal: binding(\.horizontalDirection),
                    linked: binding(\.directionsLinked))
            } else {
                capabilityNote("This device does not report a scrolling capability.")
            }
        }
        .disabled(inputEditingDisabled)
    }

    private var scrollingCard: some View {
        SettingsCard(
            title: "Scroll feel", symbol: "text.line.first.and.arrowtriangle.forward"
        ) {
            VStack(alignment: .leading, spacing: 24) {
                if device.capabilities.supportsScroll {
                    if device.capabilities.isContinuous {
                        ValueSlider(
                            title: "Scroll speed", value: binding(\.scrollSpeed), range: 0.1...4,
                            step: 0.05)
                        Text("Touch movement, gestures, and momentum stay continuous.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Scroll style").font(.system(size: 12, weight: .medium))
                            Picker("Scroll style", selection: binding(\.scrollMode)) {
                                Text("System").tag(ScrollMode.system)
                                Text("Fixed steps").tag(ScrollMode.fixed)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .buttonSizing(.flexible)
                            .frame(maxWidth: .infinity)
                            .help("Fixed steps scrolls the same number of lines for each wheel step.")
                        }
                        Spacer(minLength: 0)
                        ValueSlider(
                            title: "Step size", value: binding(\.linesPerStep), range: 1...20,
                            step: 1, integer: true,
                            isActive: profile.scrollMode == .fixed
                        )
                        .help(
                            profile.scrollMode == .fixed
                                ? "Lines scrolled by each wheel step."
                                : "Choose Fixed steps to adjust the number of lines per wheel step.")
                    }
                } else {
                    capabilityNote("This device does not report a scrolling capability.")
                }
            }
        }
        .disabled(inputEditingDisabled)
    }

    private func capabilityNote(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

}

@MainActor
private struct SettingsCard<Content: View>: View {
    @Environment(\.pausedDeviceSettings) private var settingsPaused
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    private var accent: Color { settingsPaused ? .gray : Palette.blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 18, height: 20)
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 4)

                }
            }
            content.frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

@MainActor
struct ValueSlider: View {
    @Environment(\.pausedDeviceSettings) private var settingsPaused
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var integer = false
    var centeredSpeed = false
    var isActive = true
    var compact = false
    @State private var dragValue: Double?
    @State private var editingValue = false
    @State private var draft = ""
    @State private var invalidEntry = false
    @FocusState private var editorFocused: Bool
    @FocusState private var readoutFocused: Bool

    private var accent: Color { settingsPaused || !isActive ? .gray : Palette.blue }

    private var entryRange: ClosedRange<Double> {
        integer ? DeviceProfile.stepEntryRange : DeviceProfile.speedEntryRange
    }

    private var displayedValue: Double { dragValue ?? value }

    private var formatted: String {
        PointerSpeedScale.formatted(displayedValue, minimumFractionDigits: integer ? 0 : 2)
    }

    private func trackingChanged(_ tracking: Bool) {
        if tracking {
            dragValue = value
        } else if let finalValue = dragValue {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if value != finalValue { value = finalValue }
                dragValue = nil
            }
        }
    }

    private func resetValue() {
        // Reset the setting directly, rather than converting a thumb position back into a value.
        dragValue = nil
        value = integer ? 3 : 1
    }

    // Use the same steps for the stored value and native thumb, without extra tick marks.
    private func steppedValue(at position: Double) -> Double {
        let proposed = centeredSpeed ? PointerSpeedScale.value(at: position) : position
        let rounded = (proposed / step).rounded() * step
        return min(range.upperBound, max(range.lowerBound, rounded))
    }

    private func steppedPosition(_ position: Double) -> Double {
        let stepped = steppedValue(at: position)
        return centeredSpeed ? PointerSpeedScale.position(for: stepped) : stepped
    }

    private func wheelStep(by increments: Int) -> Double {
        // Exact entry has a wider range than the track. Step the real setting,
        // never a clamped thumb position, and preserve an exact value's precision.
        let proposed = PointerSpeedScale.adjustedValue(displayedValue, by: increments, step: step, in: entryRange)
        if proposed != value { value = proposed }
        return centeredSpeed
            ? PointerSpeedScale.position(for: proposed) : min(range.upperBound, max(range.lowerBound, proposed))
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                centeredSpeed
                    ? PointerSpeedScale.position(for: displayedValue)
                    : min(range.upperBound, max(range.lowerBound, displayedValue))
            },
            set: { position in
                let stepped = steppedValue(at: position)
                if dragValue != nil {
                    dragValue = stepped
                } else {
                    value = stepped
                }
            })
    }

    var body: some View {
        let layout =
            compact ? AnyLayout(HStackLayout(alignment: .center, spacing: 12)) : AnyLayout(VStackLayout(spacing: 7))
        layout {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if !compact { valueReadout }
            }
            .frame(width: compact ? 132 : nil, height: 22)
            ResettableSlider(
                value: sliderValue, range: centeredSpeed ? 0...1 : range,
                defaultValue: centeredSpeed ? 0.5 : (integer ? 3 : 1),
                quantize: steppedPosition,
                onWheelStep: wheelStep,
                onTrackingChanged: trackingChanged,
                onReset: resetValue
            )
            .accessibilityLabel(title)
            .accessibilityValue(formatted)
            .help("Scroll over the slider to adjust. Double-click the thumb to reset to \(integer ? "3" : "1").")
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let position =
                        centeredSpeed
                        ? 0.5
                        : (integer
                            ? (3 - range.lowerBound) / (range.upperBound - range.lowerBound)
                            : (1 - range.lowerBound) / (range.upperBound - range.lowerBound))
                    Capsule()
                        .fill(Color.primary.opacity(0.5))
                        .frame(width: 1, height: 6)
                        // The small native slider thumb is 18 points wide.
                        .position(x: 9 + (geometry.size.width - 18) * position, y: geometry.size.height + 7)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .padding(.bottom, compact ? 6 : 10)
            if compact {
                valueReadout
                    .offset(y: -3)
                    // Keep the readout stationary during inherited pause animations.
                    .transaction { $0.animation = nil }
            }
        }
        .disabled(!isActive)
        .opacity(isActive || settingsPaused ? 1 : 0.5)
    }

    private var entryWidth: CGFloat {
        let base = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? base
        let width =
            [integer ? "100" : "0.00", draft].map {
                NSAttributedString(string: $0, attributes: [.font: font]).size().width
            }.max() ?? 0
        // Fit ordinary values closely; long exact entries scroll within the existing
        // readout slot rather than pushing the slider or overflowing the widget.
        return min(compact ? 32 : 48, ceil(width) + 8)
    }

    @ViewBuilder
    private var valueReadout: some View {
        if editingValue {
            TextField(
                title,
                text: Binding(
                    get: { draft },
                    set: {
                        if PointerSpeedScale.isNumericDraft($0) {
                            draft = $0
                            invalidEntry = false
                        }
                    })
            )
            .textContentType(nil)
            .autocorrectionDisabled()
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .textFieldStyle(.plain)
            .multilineTextAlignment(compact ? .leading : .trailing)
            .frame(width: entryWidth - 8, height: 18)
            .padding(.horizontal, 4)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(invalidEntry ? Color.red : accent.opacity(0.4), lineWidth: 1)
            )
            .background(EditorOutsideClick { acceptOnDismiss() })
            .frame(width: compact ? 32 : 48, height: 22, alignment: compact ? .leading : .trailing)
            .focused($editorFocused)
            .task {
                // Let the click finish transferring focus from the readout.
                do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                editorFocused = true
            }
            .onSubmit { commitEntry() }
            .onExitCommand { cancelEntry() }
            .onChange(of: editorFocused) { _, focused in
                guard !focused, editingValue else { return }
                acceptOnDismiss()
            }
            .help(
                invalidEntry
                    ? "Enter a number from \(PointerSpeedScale.formatted(entryRange.lowerBound)) to \(PointerSpeedScale.formatted(entryRange.upperBound))."
                    : "Press Return or click outside to save."
            )
            .accessibilityLabel("Edit \(title.lowercased())")
        } else {
            SliderValueReadout(
                text: formatted, color: accent, leading: compact
            )
            .frame(width: compact ? 32 : 48, height: 22, alignment: compact ? .leading : .trailing)
            .contentShape(Rectangle())
            .onTapGesture { beginEntry() }
            .focusable(isActive && !settingsPaused)
            .focusEffectDisabled()
            .focused($readoutFocused)
            .onKeyPress(.return) {
                beginEntry()
                return .handled
            }
            .accessibilityLabel("\(title): \(formatted)")
            .accessibilityActions {
                Button("Edit \(title.lowercased())") { beginEntry() }
            }
            .help(
                "\(formatted). Click to enter an exact value. Range: \(PointerSpeedScale.formatted(entryRange.lowerBound))–\(PointerSpeedScale.formatted(entryRange.upperBound))."
            )
        }
    }

    private func beginEntry() {
        guard isActive, !settingsPaused else { return }
        draft = PointerSpeedScale.formatted(value)
        invalidEntry = false
        readoutFocused = false
        editingValue = true
    }

    private func commitEntry() {
        guard let parsed = PointerSpeedScale.parse(draft, in: entryRange) else {
            invalidEntry = true
            return
        }
        value = parsed
        cancelEntry()
    }

    private func acceptOnDismiss() {
        guard editingValue else { return }
        if let parsed = PointerSpeedScale.parse(draft, in: entryRange) { value = parsed }
        cancelEntry()
    }

    private func cancelEntry() {
        editingValue = false
        editorFocused = false
        invalidEntry = false
    }
}

// SwiftUI text fields do not resign focus when blank window space is clicked.
// The first local click outside saves and closes the editor without activating another control.
@MainActor
struct EditorOutsideClick: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onClick = onClick
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObserverView: NSView {
        var onClick: (() -> Void)?
        private var monitor: Any?
        private var windowObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            windowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onClick?() }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.consumeOutsideClick(event) ?? false }
                return consumed ? nil : event
            }
        }

        func consumeOutsideClick(_ event: NSEvent) -> Bool {
            guard let window else { return false }
            guard event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil))
            else { return false }
            onClick?()
            return true
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
            windowObserver = nil
        }
    }
}

/// One quiet transition for setup actions, regardless of how much their wording changes.
private struct AnimatedSetupButtonLabel: View, @MainActor Animatable {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    let before: String
    let after: String

    private func width(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 2
    }

    var body: some View {
        let phase = min(1, max(0, progress))
        Text(phase > 0.5 ? after : before)
            .fixedSize()
            .font(.system(size: 13))
            .frame(width: width(before) * (1 - phase) + width(after) * phase, height: 20)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(Palette.blue, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(phase > 0.5 ? after : before)
    }
}

@MainActor
private struct PermissionOnboarding: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var permissionCardHeight: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 19) {
                    HStack(spacing: 15) {
                        AppMark(size: 49)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Welcome to Mousü")
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                            Text(AppCopy.tagline)
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Your starting settings").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("Recommended")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Palette.blue)
                        }
                        AutomaticSetupToggle(model: model)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.quiet, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.border, lineWidth: 1))

                    permissionCard

                    HStack(spacing: 16) {
                        if model.hasBuiltInTrackpad {
                            Label("Your built-in trackpad keeps its system settings.", systemImage: "laptopcomputer")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Button {
                            model.continueSetup()
                        } label: {
                            AnimatedSetupButtonLabel(
                                progress: model.automaticallySetUpDevices ? 1 : 0, before: "Continue",
                                after: "Apply & Continue"
                            )
                            .animation(
                                reduceMotion ? nil : .smooth(duration: 0.32), value: model.automaticallySetUpDevices
                            )
                            .opacity(model.canContinueSetup ? 1 : 0.45)
                        }
                        .buttonStyle(.plain)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canContinueSetup)

                    }
                    Text("Accessibility only. Your keyboard is never monitored.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 570)
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollIndicators(.automatic)
            .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.permissionGranted)
            .clipped()
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: model.permissionGranted ? "checkmark.circle.fill" : "hand.raised")
                    .font(.system(size: 18))
                    .foregroundStyle(Palette.blue)
                Text(model.permissionGranted ? "Accessibility granted" : "Allow Accessibility")
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.interpolate)
            }
            if model.permissionGranted {
                Text("Continue to adjust your device settings.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
            } else {
                Text(
                    "Enable Mousü in Accessibility settings to adjust movement and scrolling for your external devices."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                Button {
                    model.requestControl()
                } label: {
                    AnimatedSetupButtonLabel(
                        progress: model.accessibilityRequested ? 1 : 0, before: "Grant Accessibility",
                        after: "Open Accessibility Settings"
                    )
                    .animation(reduceMotion ? nil : .smooth(duration: 0.32), value: model.accessibilityRequested)
                }
                .buttonStyle(.plain)
                .controlSize(.large)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: { height in
            guard permissionCardHeight != height else { return }
            if permissionCardHeight == nil || reduceMotion {
                permissionCardHeight = height
            } else {
                withAnimation(.smooth(duration: 0.45)) { permissionCardHeight = height }
            }
        }
        .frame(height: permissionCardHeight, alignment: .top)
        .clipped()
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.permissionGranted)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: model.accessibilityRequested)
        .background(Palette.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Palette.blue.opacity(0.13), lineWidth: 1))
    }
}

@MainActor
private struct StatusBanner: View {
    let symbol: String
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
private struct TryAreaCard: View {
    let crtPlayback: CRTPlaybackState
    @AppStorage("tryAreaEffect") private var effect = TryAreaEffect.initial()
    @AppStorage("crtUnlocked") private var crtUnlocked = false
    @Environment(\.pausedDeviceSettings) private var settingsPaused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .frame(minHeight: 122, maxHeight: .infinity)
            .background {
                WheelCapture(
                    accent: settingsPaused ? .gray : Palette.blue, reduceMotion: reduceMotion,
                    effect: crtUnlocked ? effect : .fast, crtPlayback: crtPlayback
                ) {
                    guard !crtUnlocked else { return false }
                    crtUnlocked = true
                    effect = .crt
                    return true
                }
            }
            .background(Palette.quiet)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border))
    }
}

@MainActor
private struct WheelCapture: NSViewRepresentable {
    let accent: Color
    let reduceMotion: Bool
    let effect: TryAreaEffect
    let crtPlayback: CRTPlaybackState
    let onCRTUnlock: () -> Bool

    func makeNSView(context: Context) -> WheelCaptureNSView {
        let view = WheelCaptureNSView()
        configure(view)
        return view
    }
    func updateNSView(_ view: WheelCaptureNSView, context: Context) { configure(view) }
    private func configure(_ view: WheelCaptureNSView) {
        view.dotColor = NSColor(accent)
        view.reduceMotion = reduceMotion
        view.crtPlayback = crtPlayback
        view.effect = effect
        view.onCRTUnlock = onCRTUnlock
    }
}

@MainActor
final class WheelCaptureNSView: NSView, @preconcurrency CAMetalDisplayLinkDelegate {
    private let rasterSurface = CanvasRasterSurface()
    private var renderer: TryCanvasRenderer?
    private var rendererFailed = false
    private let frameClock = CanvasFrameClock()
    private var frameRequested = false
    private let nativeCaptions = CanvasNativeCaptions()
    private var fallbackLayer: CALayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(nativeCaptions)
        nativeCaptions.autoresizingMask = [.width, .height]
        nativeCaptions.frame = bounds
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Try it. Move the pointer here and scroll to preview your settings.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    override var wantsUpdateLayer: Bool { true }

    private func prepareRenderer() -> Bool {
        if renderer != nil { return true }
        guard !rendererFailed else { return false }
        do {
            renderer = try TryCanvasRenderer()
            return true
        } catch {
            rendererFailed = true
            NSLog("Mousü Try area Metal renderer: %@", error.localizedDescription)
            return false
        }
    }

    override func updateLayer() {
        synchronizeNativeCaptions(at: ProcessInfo.processInfo.systemUptime)
        guard prepareRenderer() else {
            nativeCaptions.isHidden = true
            // A bounded, static CPU fallback keeps controls usable when Metal is unavailable.
            guard let size = CanvasRenderSize(size: bounds.size, scale: window?.backingScaleFactor ?? 2) else { return }
            if fallbackLayer == nil {
                let fallback = CALayer()
                layer?.addSublayer(fallback)
                fallbackLayer = fallback
            }
            let scale = min(CGFloat(size.width) / bounds.width, CGFloat(size.height) / bounds.height)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                fallbackLayer?.contents = rasterSurface.image(size: bounds.size, scale: scale) {
                    self.draw(self.bounds)
                }
            }
            fallbackLayer?.frame = bounds
            return
        }
        frameRequested = true
        animateFeedback()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard canAnimate, let renderer else {
            frameClock.clear()
            return
        }
        if renderer.flight.failureCount >= 3 {
            NSLog("Mousü Try area Metal renderer: %@", renderer.lastError ?? "GPU rendering failed")
            rendererFailed = true
            self.renderer = nil
            frameClock.clear()
            needsDisplay = true
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let active = advanceFeedback(at: now)
        synchronizeNativeCaptions(at: now)
        // Draw the final settled state once before pausing the display link.
        frameRequested = !renderer.render(frameState(at: now), to: update.drawable)
        let preferred: Float = active && !(displayEffect == .crt && onlyCRTSignalActive) ? interactionFrameRate : 30
        if link.preferredFrameRateRange.preferred != preferred {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: preferred, preferred: preferred)
        }
        if !active && !frameRequested { link.isPaused = true }
    }

    private func synchronizeNativeCaptions(at now: TimeInterval) {
        nativeCaptions.update(
            text: coordinateText, coordinateOpacity: coordinateOpacity(at: now),
            reveal: CRTSignal.fastReveal(shutdownElapsed: crtStoppedAt.map { now - $0 }, reducedMotion: reduceMotion),
            dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
            visible: displayEffect == .fast && !rendererFailed)
    }

    private func frameState(at now: TimeInterval) -> CanvasFrame {
        let color = dotColor.usingColorSpace(.sRGB) ?? .systemBlue
        return CanvasFrame(
            size: bounds.size, scale: window?.backingScaleFactor ?? 2, offset: displayOffset,
            color: SIMD4(Float(color.redComponent), Float(color.greenComponent), Float(color.blueComponent), 1),
            dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
            reduceMotion: reduceMotion, includesCaptions: displayEffect == .crt,
            noticeActive: unlockNoticeStartedAt.map { now - $0 < 5.2 } == true,
            effect: displayEffect, time: now,
            power: CRTSignal.power(
                elapsed: now - crtStartedAt,
                shutdownElapsed: crtStoppedAt.map { now - $0 }, reducedMotion: reduceMotion),
            signalTime: now - crtStartedAt,
            reveal: CRTSignal.fastReveal(shutdownElapsed: crtStoppedAt.map { now - $0 }, reducedMotion: reduceMotion),
            coordinates: coordinateText, coordinateOpacity: coordinateOpacity(at: now),
            noticeOpacity: unlockNoticeOpacity(at: now), edges: edgeFeedback, path: dotPath, clicks: clickRipples)
    }

    var onCRTUnlock: (() -> Bool)?
    private var unlockRipplePoint: CGPoint?
    private var unlockSequence = CRTUnlockSequence()
    var dotColor = NSColor.systemBlue { didSet { if dotColor != oldValue { needsDisplay = true } } }
    var reduceMotion = false {
        didSet {
            if reduceMotion != oldValue {
                if reduceMotion { scrollMotion.finish() }
                animateFeedback()
                needsDisplay = true
            }
        }
    }
    var crtPlayback = CRTPlaybackState()
    private var crtStartedAt: TimeInterval { crtPlayback.startedAt }
    private var crtStoppedAt: TimeInterval? { crtPlayback.stoppedAt }
    var displayEffect: TryAreaEffect {
        if let stopped = crtStoppedAt, !reduceMotion,
            ProcessInfo.processInfo.systemUptime - stopped < CRTSignal.shutdownDuration
        {
            return .crt
        }
        return effect
    }
    var effect: TryAreaEffect = .fast {
        didSet {
            let now = ProcessInfo.processInfo.systemUptime
            crtPlayback.select(effect, at: now)
            guard effect != oldValue else { return }
            if effect == .fast { unlockNoticeStartedAt = nil }
            frameClock.clear()
            animateFeedback()
            dotPath = DotPathHighlight()
            clickRipples = DotClickRipple()
            edgeFeedback = ScrollEdgeFeedback()
            if effect == .crt, let point = unlockRipplePoint {
                unlockRipplePoint = nil
                unlockNoticeStartedAt = now
                recordClick(at: point, time: now)
            }
            needsDisplay = true
        }
    }
    private var unlockNoticeStartedAt: TimeInterval?
    func unlockNoticeOpacity(at time: TimeInterval) -> Double {
        guard let start = unlockNoticeStartedAt else { return 0 }
        let elapsed = time - start
        if reduceMotion { return elapsed >= 0 && elapsed < 5.2 ? 1 : 0 }
        return max(0, min(1, (elapsed - 0.7) / 0.3)) * max(0, min(1, (5.2 - elapsed) / 0.7))
    }

    private var coordinateText = ""
    private var coordinateVisible = false
    private var coordinateFadeStart: TimeInterval = 0
    private var coordinateFadeFrom: Double = 0

    func updateCoordinates(_ text: String, visible: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        let changed = coordinateText != text || coordinateVisible != visible
        if coordinateVisible != visible {
            coordinateFadeFrom = coordinateOpacity(at: now)
            coordinateFadeStart = now
            coordinateVisible = visible
            animateFeedback()
        }
        coordinateText = text
        if changed {
            needsDisplay = true
            setAccessibilityValue(visible ? text : "Ready to scroll")
        }
    }

    private func coordinateOpacity(at time: TimeInterval) -> Double {
        let target: Double = coordinateVisible ? 1 : 0
        if reduceMotion { return target }
        let progress = min(1, max(0, (time - coordinateFadeStart) / 0.2))
        let eased = 1 - pow(1 - progress, 3)
        return coordinateFadeFrom + (target - coordinateFadeFrom) * eased
    }

    private func drawCaptions() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let primary = NSColor(calibratedWhite: dark ? 0.92 : 0.12, alpha: 1)
        let secondary = NSColor(calibratedWhite: dark ? 0.65 : 0.36, alpha: 1)
        if displayEffect == .crt {
            let now = ProcessInfo.processInfo.systemUptime
            if let start = unlockNoticeStartedAt, now - start < 5.2 {
                let opacity = unlockNoticeOpacity(at: now)
                let message = "CRT unlocked. See Settings"
                let width = PixelCaption.width(of: message, scale: 2)
                PixelCaption.draw(
                    message,
                    at: CGPoint(x: floor(bounds.midX - width / 2), y: floor(bounds.maxY - 38)),
                    scale: 2, color: NSColor.white.withAlphaComponent(opacity))
                return
            }
            PixelCaption.draw("Try it", at: CGPoint(x: 20, y: 20), scale: 3, color: primary)
            PixelCaption.draw(
                "Move your pointer here and try scrolling.",
                at: CGPoint(x: 20, y: 51), scale: 2, color: secondary)
            PixelCaption.draw(
                coordinateText, at: CGPoint(x: 20, y: 83), scale: 2,
                color: secondary.withAlphaComponent(
                    coordinateOpacity(at: ProcessInfo.processInfo.systemUptime)))
            return
        }
        ("Try it" as NSString).draw(
            at: CGPoint(x: 20, y: 20),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: primary,
            ])
        ("Move your pointer here and try scrolling." as NSString).draw(
            at: CGPoint(x: 20, y: 44),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: secondary,
            ])
        (coordinateText as NSString).draw(
            at: CGPoint(x: 20, y: 75),
            withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: secondary.withAlphaComponent(
                    coordinateOpacity(at: ProcessInfo.processInfo.systemUptime)),
            ])
    }

    private var edgeFeedback = ScrollEdgeFeedback()
    private var dotPath = DotPathHighlight()
    private var clickRipples = DotClickRipple()
    private let visibilityObservers = CanvasVisibilityObservers()
    var isFeedbackRunning: Bool { frameClock.link?.isPaused == false }

    static func permitsAnimation(windowVisible: Bool, unoccluded: Bool, viewHidden: Bool, visibleArea: CGRect) -> Bool {
        windowVisible && unoccluded && !viewHidden && !visibleArea.isEmpty
    }

    private var canAnimate: Bool {
        guard let window else { return false }
        return Self.permitsAnimation(
            windowVisible: window.isVisible && !NSApp.isHidden,
            unoccluded: window.occlusionState.contains(.visible),
            viewHidden: isHiddenOrHasHiddenAncestor, visibleArea: visibleRect.intersection(bounds))
    }

    private func stopObservingVisibility() {
        visibilityObservers.clear()
    }

    private func observeVisibility() {
        stopObservingVisibility()
        guard let window else { return }
        func observe(_ name: Notification.Name, object: AnyObject?) {
            visibilityObservers.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.refreshAnimationVisibility() }
                })
        }
        observe(NSWindow.didChangeOcclusionStateNotification, object: window)
        observe(NSWindow.didMiniaturizeNotification, object: window)
        observe(NSWindow.didDeminiaturizeNotification, object: window)
        observe(NSApplication.didHideNotification, object: NSApp)
        observe(NSApplication.didUnhideNotification, object: NSApp)
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                observe(NSView.boundsDidChangeNotification, object: clip)
            }
            ancestor = view.superview
        }
    }

    private func refreshAnimationVisibility() {
        if canAnimate {
            needsDisplay = true
            animateFeedback()
        } else {
            frameClock.clear()
            scrollMotion.finish()
            renderer?.releaseResources()
            // Zero is invalid for CAMetalLayer; shrink its idle drawable pool
            // to the smallest valid surface until the view becomes visible.
            (layer as? CAMetalLayer)?.drawableSize = CGSize(width: 1, height: 1)
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        observeVisibility()
        refreshAnimationVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        refreshAnimationVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        refreshAnimationVisibility()
    }
    private var pointerTrackingArea: NSTrackingArea?
    private var scrollMotion = CanvasScrollMotion()
    private var displayOffset: CGSize { scrollMotion.position }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        if window == nil {
            frameClock.clear()
            scrollMotion.finish()
            renderer?.releaseResources()
            renderer = nil
            (layer as? CAMetalLayer)?.device = nil
            rasterSurface.reset()
            fallbackLayer?.removeFromSuperlayer()
            fallbackLayer = nil
            edgeFeedback = ScrollEdgeFeedback()
            dotPath = DotPathHighlight()
            clickRipples = DotClickRipple()
        } else {
            refreshAnimationVisibility()
        }
    }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag,
            ],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }

    private func trackPointer(_ event: NSEvent) {
        let point = effectPoint(convert(event.locationInWindow, from: nil))
        guard bounds.contains(point) else {
            dotPath.endStroke()
            return
        }
        dotPath.record(
            CGPoint(x: point.x - displayOffset.width, y: point.y - displayOffset.height),
            at: ProcessInfo.processInfo.systemUptime)
        animateFeedback()
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rippleFromClick(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        recordClick(at: point, time: ProcessInfo.processInfo.systemUptime)
    }

    func recordClick(at point: CGPoint, time: TimeInterval) {
        guard bounds.contains(point) else { return }
        let point = effectPoint(point)
        // The wave belongs to the visible surface; the dot grid scrolls through it.
        clickRipples.record(point, at: time, bounds: bounds)
        animateFeedback()
        needsDisplay = true
    }

    func clickIntensity(at point: CGPoint, time: TimeInterval) -> Double {
        clickRipples.intensity(at: point, time: time, reduceMotion: reduceMotion)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point), unlockSequence.click(at: event.timestamp) {
            unlockRipplePoint = point
            if onCRTUnlock?() == true {
                // Switch before recording the fifth click so the mode reset cannot erase it.
                effect = .crt
                return
            }
            unlockRipplePoint = nil
        }
        rippleFromClick(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        unlockSequence.reset()
        rippleFromClick(event)
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        unlockSequence.reset()
        rippleFromClick(event)
    }

    override func mouseEntered(with event: NSEvent) {
        dotPath.endStroke()
        trackPointer(event)
    }

    override func mouseMoved(with event: NSEvent) { trackPointer(event) }

    override func mouseDragged(with event: NSEvent) {
        trackPointer(event)
        super.mouseDragged(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        unlockSequence.reset()
        dotPath.endStroke()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard rendererFailed else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.clear(bounds)
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).addClip()
        drawDots()
        drawCaptions()
    }

    private func effectPoint(_ point: CGPoint) -> CGPoint {
        effect == .crt ? CRTProjection.sourcePoint(at: point, in: bounds.size) : point
    }

    private func drawDots() {
        let spacing: CGFloat = 16
        let xOffset = displayOffset.width.truncatingRemainder(dividingBy: spacing)
        let yOffset = displayOffset.height.truncatingRemainder(dividingBy: spacing)
        let now = ProcessInfo.processInfo.systemUptime
        let feedback = ScrollEdgeFeedback.dotSpeeds.map { edgeFeedback.spatialField(at: now, speed: $0) }
        let sparseGlow = edgeFeedback.sparseIntensity(at: now)
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlight: NSColor = dark ? .white : .labelColor
        for column in -1...Int(bounds.width / spacing + 1) {
            for row in -1...Int(bounds.height / spacing + 1) {
                let x = CGFloat(column) * spacing + xOffset
                let y = CGFloat(row) * spacing + yOffset
                let center = CGPoint(x: x + 1, y: y + 1)
                let variation = ScrollEdgeFeedback.variation(
                    column: Int(((center.x - displayOffset.width - 1) / spacing).rounded()),
                    row: Int(((center.y - displayOffset.height - 1) / spacing).rounded()))
                let pulse = feedback[variation.speedIndex].intensity(at: center, in: bounds.size)
                let scalePulse = feedback[variation.speedIndex].intensity(
                    at: center, in: bounds.size, spatialExponent: 3.8)
                let proximity = dotPath.intensity(
                    at: CGPoint(x: center.x - displayOffset.width, y: center.y - displayOffset.height), time: now)
                let clickGlow = clickIntensity(at: center, time: now)
                let accent = sparseGlow * variation.sparseAccent
                // Clip edge dots geometrically without dimming their visible portion.
                let emphasis = min(1, max(pulse * variation.brightness + accent * 0.36, proximity, clickGlow))
                // A cubic boost separates aggressive reactions from gentle movement.
                let growth = min(
                    13, 3 * scalePulse + 8 * scalePulse * scalePulse * scalePulse + 2 * accent)
                let diameter = 2 + (reduceMotion ? 0 : growth * variation.scale)
                let color = dotColor.blended(withFraction: emphasis * 0.75, of: highlight) ?? dotColor
                let baseline = 0.2 * (0.35 + 0.65 * center.x / max(bounds.width, 1))
                color.withAlphaComponent(min(1, baseline + 0.8 * emphasis)).setFill()
                NSBezierPath(
                    ovalIn: CGRect(
                        x: center.x - diameter / 2, y: center.y - diameter / 2,
                        width: diameter, height: diameter)
                ).fill()
            }
        }

    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        unlockSequence.reset()
        let x: Double
        let y: Double
        if event.hasPreciseScrollingDeltas {
            x = Double(event.scrollingDeltaX)
            y = Double(event.scrollingDeltaY)
        } else if let cg = event.cgEvent {
            // Wheel deltas are lines, not points: one line is one 16-point dot row.
            func lines(_ fixed: CGEventField, _ integer: CGEventField) -> Double {
                let value = cg.getDoubleValueField(fixed)
                return value == 0 ? Double(cg.getIntegerValueField(integer)) : value
            }
            x = lines(.scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2) * 16
            y = lines(.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1) * 16
        } else {
            x = Double(event.scrollingDeltaX) * 16
            y = Double(event.scrollingDeltaY) * 16
        }
        guard x.isFinite, y.isFinite, x != 0 || y != 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        edgeFeedback.record(x: x, y: y, at: now)
        // The wheel destination updates immediately; its dot motion retains the
        // original short glide. Precise input and Reduce Motion remain direct.
        scrollMotion.retarget(
            to: CGSize(width: scrollMotion.target.width + x, height: scrollMotion.target.height + y), at: now,
            animated: !event.hasPreciseScrollingDeltas && !reduceMotion && canAnimate)
        if let previous = lastScrollTime, now - previous > 1.2 { scrollTotals = .zero }
        scrollTotals.width += x / 16
        scrollTotals.height += y / 16
        lastScrollTime = now
        refreshCoordinateText(at: now)
        animateFeedback()
        needsDisplay = true
    }

    private var scrollTotals = CGSize.zero
    private var lastScrollTime: TimeInterval?
    private var lastCoordinateUpdate: TimeInterval = -.infinity
    private var onlyCRTSignalActive = false

    private func refreshCoordinateText(at now: TimeInterval) {
        guard lastScrollTime != nil else { return }
        if now - (lastScrollTime ?? now) >= 1 {
            if coordinateVisible { updateCoordinates(coordinateText, visible: false) }
            return
        }
        guard !coordinateVisible || now - lastCoordinateUpdate >= 0.1 else { return }
        func coordinate(_ value: Double) -> String {
            value.formatted(.number.grouping(.never).precision(.fractionLength(0...1)))
        }
        updateCoordinates(
            "↑↓ \(coordinate(scrollTotals.height))    ←→ \(coordinate(scrollTotals.width))", visible: true)
        lastCoordinateUpdate = now
        setAccessibilityValue(coordinateText)
    }

    @discardableResult
    func advanceFeedback(at now: TimeInterval) -> Bool {
        let scrolling = scrollMotion.advance(at: now)
        refreshCoordinateText(at: now)
        let edges = edgeFeedback.expire(at: now)
        let path = dotPath.expire(at: now)
        let clicks = clickRipples.expire(at: now)
        let caption = !reduceMotion && now - coordinateFadeStart < 0.2
        let coordinatePending = lastScrollTime.map { now - $0 < 1.2 } == true
        let notice = unlockNoticeStartedAt.map { now - $0 < 5.2 } == true
        let transition =
            !reduceMotion
            && crtStoppedAt.map {
                now - $0 < CRTSignal.shutdownDuration + CRTSignal.revealDuration
            } == true
        let signal = !reduceMotion && displayEffect == .crt
        let starting = signal && now - crtStartedAt < 0.7
        onlyCRTSignalActive =
            signal && !starting && !scrolling && !edges && !path && !clicks && !caption && !coordinatePending && !notice
        return scrolling || edges || path || clicks || caption || coordinatePending || notice || transition || signal
    }

    private var interactionFrameRate: Float {
        renderer?.flight.lastDuration.map { $0 > 0.007 } == true ? 60 : 120
    }

    private func animateFeedback() {
        guard canAnimate, prepareRenderer(), let layer = layer as? CAMetalLayer,
            let size = CanvasRenderSize(size: bounds.size, scale: window?.backingScaleFactor ?? 2)
        else { return }
        renderer?.configure(layer, size: size)
        if frameClock.link == nil {
            let link = CAMetalDisplayLink(metalLayer: layer)
            link.delegate = self
            link.preferredFrameLatency = 1
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
            frameClock.link = link
            link.add(to: .main, forMode: .common)
        }
        // Wake at the interaction rate before the next callback, so the first
        // wheel/hover frame is not held to the idle CRT cadence.
        if let link = frameClock.link {
            let preferred = interactionFrameRate
            if link.preferredFrameRateRange.preferred != preferred {
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: preferred, preferred: preferred)
            }
            link.isPaused = false
        }
    }

}

private final class CanvasFrameClock {
    var link: CAMetalDisplayLink?
    func clear() {
        link?.invalidate()
        link = nil
    }
    deinit { clear() }
}

// Own notification registrations independently of the view's actor isolation so
// teardown also removes them when a view is released without a detach callback.
private final class CanvasVisibilityObservers {
    var tokens: [NSObjectProtocol] = []

    func clear() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }

    deinit { clear() }
}

private struct PausedDeviceSettingsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    fileprivate var pausedDeviceSettings: Bool {
        get { self[PausedDeviceSettingsKey.self] }
        set { self[PausedDeviceSettingsKey.self] = newValue }
    }
}

private struct PausedSettingsAppearance: ViewModifier {
    let isPaused: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.pausedDeviceSettings, isPaused)
            .tint(isPaused ? .gray : Palette.blue)
            .opacity(isPaused ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.16), value: isPaused)
    }
}

@MainActor
struct MenuPanel: View {
    @Environment(\.menuPanelDismissal) private var menuPanelDismissal
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var detailDeviceID: String?
    @State private var detailScrollStatus: MenuDetailScrollStatus?
    private static let detailViewportHeight: CGFloat = 260
    @State private var panelWindow = MenuPanelWindowReference()
    @State private var catalogCardWidth: CGFloat?
    @State private var refreshAnimation = 0
    @State private var hoveringRefresh = false
    @State private var hoveringReset = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel) {
        self.model = model
        _detailDeviceID = State(initialValue: model.restoredMenuDeviceKey)
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<DeviceProfile, Value>, fallback: DeviceProfile, deviceID: UInt64
    ) -> Binding<Value> {
        Binding {
            (model.profile(for: deviceID) ?? fallback)[keyPath: keyPath]
        } set: { value in
            guard var updated = model.profile(for: deviceID) else { return }
            updated[keyPath: keyPath] = value
            model.editProfileSettings(updated, for: deviceID)
        }
    }

    var body: some View {
        Group {
            if model.requiresSetup {
                setupRequired
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    Divider()
                    if model.paused {
                        GlobalPauseBanner(model: model)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                    catalog
                    if let detailDeviceID, let entry = model.catalogDevices.first(where: { $0.id == detailDeviceID }) {
                        Divider()
                        if let device = entry.connection {
                            deviceDetail(entry, device: device)
                                .id(entry.id)
                        } else {
                            disconnectedDetail(entry)
                        }
                    }
                    Divider()
                    footer
                }
            }
        }
        .frame(width: 400)
        .modifier(CatalogDragOverlay(model: model))
        .background(MenuPanelWindowReader(reference: panelWindow).frame(width: 0, height: 0))
        .environment(\.clearCatalogDetail, clearDetailAction)
        .tint(Palette.blue)
        .onChange(of: model.catalogDevices.map(\.id)) { _, ids in
            if let detailDeviceID, !ids.contains(detailDeviceID) {
                self.detailDeviceID = model.canonicalCatalogKey(detailDeviceID)
            }
        }
        .onChange(of: detailDeviceID) { _, deviceID in
            if detailScrollStatus?.deviceID != deviceID { detailScrollStatus = nil }
        }
        .onDisappear {
            model.clearDeviceSelection()
            model.rememberMenuDevice(detailDeviceID)
            detailDeviceID = model.restoredMenuDeviceKey
            detailScrollStatus = nil
        }
    }

    private var clearDetailAction: (@MainActor @Sendable () -> Void)? {
        guard detailDeviceID != nil else { return nil }
        return { detailDeviceID = nil }
    }

    private func openMousu() {
        if let menuPanelDismissal {
            menuPanelDismissal.dismiss()
        } else {
            panelWindow.window?.close()
        }
        AppPresence.shared.openWindow()
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var header: some View {
        HStack(spacing: 9) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Mousü").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(
                    model.requiresSetup
                        ? "Setup needed" : (model.paused ? "Paused · using system settings" : model.status)
                )
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !model.paused {
                Button {
                    model.paused = true
                } label: {
                    Label("Pause all", systemImage: "pause.fill")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Pause all devices")
                .accessibilityLabel("Pause all devices")
                .disabled(model.requiresSetup)
            }
        }
        .padding(16)
    }

    private var setupRequired: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                AppMark(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mousü").font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(AppCopy.tagline)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()

            VStack(alignment: .leading, spacing: 13) {
                Label(
                    "Continue setting up Mousü",
                    systemImage: model.permissionGranted ? "checkmark.circle" : "hand.raised"
                )
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.permissionGranted ? "Accessibility access granted" : "Accessibility access is required")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        model.permissionGranted
                            ? "Continue in the app to finish setting up your devices."
                            : "Continue setup to allow Mousü in Accessibility settings and enable pointer and scrolling controls."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Button("Continue", action: openMousu)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .accessibilityHint("Close this panel and continue setup in Mousü.")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Palette.blue.opacity(0.12)))
            .padding(18)

        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Your devices").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.catalogDevices.isEmpty {
                    Text("\(model.connectedDeviceCount) connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if model.hiddenDeviceCount > 0 {
                    Text("\(model.hiddenDeviceCount) hidden")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                CatalogVisibilityMenu(model: model)
                Button {
                    refreshAnimation += 1
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .medium))
                        .symbolEffect(
                            .rotate, options: .nonRepeating.speed(1.5), value: reduceMotion ? 0 : refreshAnimation
                        )
                        .frame(width: 22, height: 22)
                        .background(
                            Color.primary.opacity(hoveringRefresh ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .onHover { hoveringRefresh = $0 }
                .help("Refresh connected devices")
                .accessibilityLabel("Refresh connected devices")
            }
            .padding(.leading, 18)
            .padding(.trailing, max(16, 400 - 16 - (catalogCardWidth ?? 368)))
            .padding(.top, 15)
            .padding(.bottom, 11)

            if model.catalogDevices.isEmpty && model.hiddenDeviceCount == 0 {
                VStack(spacing: 10) {
                    Image(systemName: "computermouse")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Palette.blue)
                    Text("Connect a device to get started.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 125)
            } else if !model.catalogDevices.isEmpty {
                ScrollView {
                    DeviceCatalogGrid(
                        model: model, columns: 2, selectedID: detailDeviceID,
                        selectionHelp: { entry in
                            detailDeviceID == entry.id
                                ? "Click again to close device settings"
                                : "Show device settings below the device catalog"
                        }
                    ) { entry in
                        model.selectCatalogDevice(entry.id)
                        detailDeviceID = entry.id
                    }
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: { width in
                        catalogCardWidth = width
                    }
                    .padding(.horizontal, 16)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollIndicators(.visible)
                .frame(height: catalogHeight)
                .clipped()
                .padding(.bottom, 12)
            }
        }
    }

    private var catalogHeight: CGFloat {
        // Keep up to two complete rows visible, even while device settings are open.
        let rows = min(2, (model.catalogDevices.count + 1) / 2)
        return CGFloat(rows) * CatalogCardMetrics.height + CGFloat(max(0, rows - 1) * 10)
    }

    private var detailHeader: some View {
        HStack {
            Text("Device settings").font(.system(size: 12, weight: .semibold))
            Spacer()

        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private func disconnectedDetail(_ entry: CatalogDevice) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader
            VStack(spacing: 16) {
                DeviceIconButton(
                    model: model, deviceKey: entry.id, kind: entry.kind, size: 72,
                    symbolSize: 34, fallbackColor: .secondary)
                VStack(spacing: 6) {
                    DeviceNameHeading(
                        model: model, deviceKey: entry.id, currentName: entry.name,
                        fontSize: 18, lineLimit: 2, spacing: 6, centersName: true)
                    Label(entry.connectionDescription, systemImage: "cable.connector.slash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .frame(maxWidth: .infinity)
            .frame(height: Self.detailViewportHeight, alignment: .top)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func deviceDetail(_ entry: CatalogDevice, device: DeviceInfo) -> some View {
        let profile = entry.profile
        let hasMoreBelow = detailScrollStatus?.deviceID == entry.id && detailScrollStatus?.hasMoreBelow == true
        let settingsPaused = model.paused || profile.isDevicePaused || !entry.isManaged
        let settingsAccent: Color = settingsPaused ? .gray : Palette.blue
        return VStack(spacing: 0) {
            detailHeader
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !entry.isManaged {
                            UnmanagedDeviceNotice(model: model, entry: entry)
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                DeviceIconButton(
                                    model: model, deviceKey: entry.id, kind: entry.kind, size: 32, symbolSize: 20,
                                    fallbackColor: settingsAccent)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .deviceActionCenter, spacing: 0) {
                                        DeviceNameHeading(
                                            model: model, deviceKey: entry.id, currentName: entry.name,
                                            fontSize: 14, spacing: 6)
                                        Spacer(minLength: 0)
                                        Button {
                                            model.resetSettings(for: device.id)
                                        } label: {
                                            Text(Image(systemName: "arrow.counterclockwise"))
                                                .font(.system(size: 14 * 0.88, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                                .background(
                                                    Color.primary.opacity(hoveringReset ? 0.08 : 0),
                                                    in: RoundedRectangle(cornerRadius: 6)
                                                )
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)
                                        .onHover { hoveringReset = $0 }
                                        .help("Reset movement and scrolling settings")
                                        .accessibilityLabel("Reset device settings")
                                        .disabled(settingsPaused || !model.bridgeAvailable)
                                        .alignmentGuide(.deviceActionCenter) { $0[VerticalAlignment.center] }
                                    }

                                }

                            }

                            VStack(alignment: .leading, spacing: 9) {
                                if device.capabilities.supportsFlat {
                                    HStack(spacing: 12) {
                                        Text("Response").font(.system(size: 12))
                                            .frame(width: 132, alignment: .leading)
                                        Picker(
                                            "Response",
                                            selection: binding(\.pointerMode, fallback: profile, deviceID: device.id)
                                        ) {
                                            Text("System").tag(PointerMode.system)
                                            Text("Flat").tag(PointerMode.flat)
                                        }
                                        .labelsHidden().pickerStyle(.segmented)
                                        .buttonSizing(.flexible)
                                        .frame(maxWidth: .infinity)
                                        .padding(.trailing, 44)
                                    }
                                    if device.capabilities.supportsPointerSpeed {
                                        ValueSlider(
                                            title: "Speed",
                                            value: binding(\.pointerSpeed, fallback: profile, deviceID: device.id),
                                            range: PointerSpeedScale.range, step: 0.05, centeredSpeed: true,
                                            isActive: profile.pointerMode == .flat, compact: true)
                                    }
                                }
                                if device.capabilities.supportsScroll {
                                    if device.capabilities.supportsFlat { Divider() }
                                    LinkedDirectionControls(
                                        vertical: binding(\.verticalDirection, fallback: profile, deviceID: device.id),
                                        horizontal: binding(
                                            \.horizontalDirection, fallback: profile, deviceID: device.id),
                                        linked: binding(\.directionsLinked, fallback: profile, deviceID: device.id),
                                        compact: true)
                                    Divider()
                                    if device.capabilities.isContinuous {
                                        ValueSlider(
                                            title: "Scroll speed",
                                            value: binding(\.scrollSpeed, fallback: profile, deviceID: device.id),
                                            range: 0.1...4, step: 0.05, compact: true)
                                        Text("Touch movement and momentum stay continuous.")
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                    } else {
                                        HStack(spacing: 12) {
                                            Text("Scroll style").font(.system(size: 12))
                                                .frame(width: 132, alignment: .leading)
                                            Picker(
                                                "Scroll style",
                                                selection: binding(\.scrollMode, fallback: profile, deviceID: device.id)
                                            ) {
                                                Text("System").tag(ScrollMode.system)
                                                Text("Fixed steps").tag(ScrollMode.fixed)
                                            }
                                            .labelsHidden().pickerStyle(.segmented)
                                            .buttonSizing(.flexible)
                                            .frame(maxWidth: .infinity)
                                            .padding(.trailing, 44)
                                        }
                                        ValueSlider(
                                            title: "Step size",
                                            value: binding(\.linesPerStep, fallback: profile, deviceID: device.id),
                                            range: 1...20, step: 1,
                                            integer: true, isActive: profile.scrollMode == .fixed, compact: true)
                                    }
                                }
                                if !device.capabilities.supportsFlat && !device.capabilities.supportsScroll {
                                    Text(
                                        "No adjustable pointer or scrolling capabilities were reported for this device."
                                    )
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(settingsPaused || !model.bridgeAvailable)
                        }
                        .modifier(PausedSettingsAppearance(isPaused: settingsPaused))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: MenuDetailScrollStatus.self) { geometry in
                    let epsilon: CGFloat = 1
                    return MenuDetailScrollStatus(
                        deviceID: entry.id,
                        hasMoreBelow: geometry.contentSize.height > geometry.containerSize.height + epsilon
                            && geometry.contentSize.height - geometry.visibleRect.maxY > epsilon
                    )
                } action: { _, status in
                    guard detailDeviceID == status.deviceID else { return }
                    detailScrollStatus = status
                }
                .clipped()
                if hasMoreBelow {
                    Label("Scroll for more settings", systemImage: "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .opacity(hasMoreBelow ? 1 : 0)
                        .animation(.easeInOut(duration: 0.18), value: hasMoreBelow)
                        .accessibilityHidden(!hasMoreBelow)
                }
            }
            .frame(height: Self.detailViewportHeight)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Mousü", action: openMousu)
                .buttonStyle(.borderedProminent)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Quit Mousü completely and stop all device control.")
                .accessibilityHint("Quit Mousü completely and stop all device control.")
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct MenuDetailScrollStatus: Equatable {
    let deviceID: String
    let hasMoreBelow: Bool
}

@MainActor
private struct CatalogVisibilityActions: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle("Show hidden devices", isOn: $model.showHiddenDevices)
            .disabled(!model.showHiddenDevices && model.hiddenDeviceCount == 0)
    }
}

@MainActor
private struct CatalogVisibilityMenu: View {
    @Bindable var model: AppModel
    @State private var confirmingForget = false

    var body: some View {
        Menu {
            CatalogVisibilityActions(model: model)
            Divider()
            Button("Select all devices") { model.selectDevicesForCleanup(disconnectedOnly: false) }
                .disabled(!model.canSelectDevicesForCleanup(disconnectedOnly: false))
            Button("Select disconnected devices") { model.selectDevicesForCleanup(disconnectedOnly: true) }
                .disabled(!model.canSelectDevicesForCleanup(disconnectedOnly: true))
            if model.hasDeviceSelection {
                Divider()
                DeviceCleanupActions(model: model, confirmingForget: $confirmingForget)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(CatalogSelectionClickRegion())
        .accessibilityLabel("Device list options")
        .help("Select, clean up, or show hidden devices")
        .alert("Forget selected devices?", isPresented: $confirmingForget) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) { model.forgetSelectedDevices() }
                .disabled(!model.canOrganizeDevices)
        } message: {
            Text("Removes their saved settings. Connected devices stay.")
        }
    }
}

@MainActor
private struct UnmanagedDeviceNotice: View {
    @Bindable var model: AppModel
    let entry: CatalogDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mousü isn’t managing this device.")
                .font(.system(size: 12, weight: .medium))
            Text("Its macOS settings are in use. Manage it again to restore its saved Mousü settings.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Manage and show") { model.manageAndShowDevice(entry.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.canOrganizeDevices)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.quiet, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DisconnectedDeviceDetail: View {
    @Bindable var model: AppModel
    let entry: CatalogDevice

    private var reconnectionDescription: String {
        if let explanation = entry.matchingDeviceExplanation { return explanation }
        if !entry.isManaged {
            return
                "This device isn’t managed. Use its menu to manage and show it again. Controls become available when it reconnects."
        }
        return "Your settings are saved. Reconnect this device to adjust them again."
    }

    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            DeviceIconButton(
                model: model, deviceKey: entry.id, kind: entry.kind, size: 100,
                symbolSize: 42, fallbackColor: .secondary)
            VStack(alignment: .center, spacing: 8) {
                DeviceNameHeading(
                    model: model, deviceKey: entry.id, currentName: entry.name,
                    fontSize: 26, lineLimit: 3, spacing: 6, centersName: true)
                Label(entry.connectionDescription, systemImage: "cable.connector.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(reconnectionDescription)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if (!entry.isModelCard && !entry.identityPersistent) || (entry.isModelCard && !entry.capturesAllMatches)
                {
                    DeviceProfileControl(
                        model: model, deviceKey: entry.id, showsExplanation: false, alignment: .center
                    )
                    .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)
        }
        // Keep the icon at a stable height as names and reconnection messages wrap.
        .padding(.top, 100)
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .top)
    }
}

private struct CatalogDragPresentation {
    let anchor: Anchor<CGRect>
    let token: UUID
    let entry: CatalogDevice
    let selected: Bool
    let width: CGFloat
    let origin: CGPoint
    let settling: Bool
}

private struct CatalogDragPresentationKey: PreferenceKey {
    static var defaultValue: CatalogDragPresentation? { nil }
    static func reduce(value: inout CatalogDragPresentation?, nextValue: () -> CatalogDragPresentation?) {
        if let next = nextValue() { value = next }
    }
}

@MainActor
private struct CatalogDragOverlay: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(CatalogDragPresentationKey.self) { presentation in
            if let presentation {
                GeometryReader { geometry in
                    let grid = geometry[presentation.anchor]
                    DeviceCard(
                        model: model, entry: presentation.entry, selected: presentation.selected,
                        selectionHelp: "", action: {}
                    )
                    .frame(width: presentation.width, height: CatalogCardMetrics.height)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .scaleEffect(presentation.settling ? 1 : 1.025)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .offset(x: grid.minX + presentation.origin.x, y: grid.minY + presentation.origin.y)
                    .id(presentation.token)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct CatalogSlots {
    let width: CGFloat
    let columns: Int
    var spacing: CGFloat { columns == 1 ? 8 : 10 }
    var cardWidth: CGFloat { max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)) }

    func origin(at index: Int) -> CGPoint {
        CGPoint(
            x: CGFloat(index % columns) * (cardWidth + spacing),
            y: CGFloat(index / columns) * (CatalogCardMetrics.height + spacing))
    }

    func nearestIndex(to center: CGPoint, count: Int) -> Int {
        let column = Int(
            min(CGFloat(columns - 1), max(0, ((center.x - cardWidth / 2) / (cardWidth + spacing)).rounded())))
        let row = Int(
            min(
                CGFloat(max(0, count - 1)),
                max(0, ((center.y - CatalogCardMetrics.height / 2) / (CatalogCardMetrics.height + spacing)).rounded())))
        return min(max(0, count - 1), row * columns + column)
    }
}

private struct CatalogSlotLayout: Layout {
    let columns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let rows = (subviews.count + columns - 1) / columns
        let slots = CatalogSlots(width: width, columns: columns)
        return CGSize(
            width: width, height: CGFloat(rows) * CatalogCardMetrics.height + CGFloat(max(0, rows - 1)) * slots.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let slots = CatalogSlots(width: bounds.width, columns: columns)
        for (index, subview) in subviews.enumerated() {
            let origin = slots.origin(at: index)
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), anchor: .topLeading,
                proposal: ProposedViewSize(width: slots.cardWidth, height: CatalogCardMetrics.height))
        }
    }
}

@MainActor
private struct DeviceCatalogGrid: View {
    @Environment(\.clearCatalogDetail) private var clearCatalogDetail
    @Environment(\.menuPanelDismissal) private var menuPanelDismissal
    @Bindable var model: AppModel
    let columns: Int
    let selectedID: String?
    let selectionHelp: (CatalogDevice) -> String
    let action: (CatalogDevice) -> Void
    @State private var coordinateSpace = UUID()
    @State private var width: CGFloat = 0
    @State private var drag: MovingCard?
    @State private var trackingGesture = false
    @State private var cancelledGesture = false
    @State private var scrollReference = CatalogScrollReference()

    private struct MovingCard {
        let token = UUID()
        var order: CatalogDragOrder
        let grabOffset: CGSize
        let cardWidth: CGFloat
        var position: CGPoint
        var settling = false
    }

    private var entries: [CatalogDevice] { model.catalogDevices }
    private var pins: Set<String> { Set(entries.filter(\.isPinned).map(\.id)) }
    private var displayedEntries: [CatalogDevice] {
        guard let drag else { return entries }
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return drag.order.deviceIDs.compactMap { byID[$0] }
    }

    var body: some View {
        CatalogSlotLayout(columns: columns) {
            ForEach(displayedEntries) { entry in
                DeviceCard(
                    model: model, entry: entry,
                    selected: model.hasDeviceSelection
                        ? model.selectedDeviceKeys.contains(entry.id)
                        : selectedID == entry.id,
                    selectionHelp: "Command-click to select multiple devices; Shift-click to select a range. "
                        + selectionHelp(entry),
                    action: { select(entry) }, dragSpace: coordinateSpace,
                    dragChanged: { updateDrag(entry: entry, value: $0) }, dragEnded: finishDrag,
                    dragCancelled: gestureCancelled
                )
                .opacity(floatingDeviceID == entry.id ? 0.001 : 1)
            }
        }
        .animation(.snappy(duration: 0.18), value: displayedEntries.map(\.id))
        .anchorPreference(key: CatalogDragPresentationKey.self, value: .bounds) { anchor in
            dragPresentation(anchor: anchor)
        }
        .coordinateSpace(name: coordinateSpace)
        .background(CatalogScrollReader(reference: scrollReference).frame(width: 0, height: 0))
        .background {
            CatalogEscapeHandler(
                menuPanelDismissal: menuPanelDismissal, clearOnOutsideClick: { model.clearDeviceSelection() }
            ) {
                guard model.hasDeviceSelection || drag != nil else { return false }
                cancelDrag()
                model.clearDeviceSelection()
                return true
            }.frame(width: 0, height: 0)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: { newWidth in
            if width != newWidth { cancelDrag() }
            width = newWidth
        }
        .onChange(of: entries) { _, _ in
            model.selectedDeviceKeys.formIntersection(Set(entries.map(\.id)))
            if drag != nil { cancelDrag() }
        }
        .onChange(of: model.canOrganizeDevices) { _, enabled in if !enabled { cancelDrag() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            cancelDrag()
            model.clearDeviceSelection()
        }
        .onExitCommand {
            if drag != nil || model.hasDeviceSelection {
                cancelDrag()
                model.clearDeviceSelection()
            } else {
                menuPanelDismissal?.dismiss()
            }
        }
        .onDisappear { cancelDrag() }
    }

    private var floatingDeviceID: String? {
        if let drag { return drag.order.draggedID }
        return nil
    }

    private func dragPresentation(anchor: Anchor<CGRect>) -> CatalogDragPresentation? {
        guard let id = floatingDeviceID, let entry = entries.first(where: { $0.id == id }) else { return nil }
        if let drag {
            return CatalogDragPresentation(
                anchor: anchor, token: drag.token, entry: entry, selected: selectedID == entry.id,
                width: drag.cardWidth,
                origin: CGPoint(
                    x: drag.position.x - drag.grabOffset.width, y: drag.position.y - drag.grabOffset.height),
                settling: drag.settling)
        }
        return nil
    }

    private func select(_ entry: CatalogDevice) {
        let modifiers = NSApp.currentEvent?.modifierFlags ?? []
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if !model.hasDeviceSelection, let selectedID {
                model.selectDeviceForCleanup(selectedID)
            }
            model.selectDeviceForCleanup(
                entry.id, range: modifiers.contains(.shift), additive: modifiers.contains(.command))
        } else {
            let reselected =
                selectedID == entry.id
                && (!model.hasDeviceSelection || model.selectedDeviceKeys == [entry.id])
            model.clearDeviceSelection()
            if reselected, let clearCatalogDetail { clearCatalogDetail() } else { action(entry) }
        }
    }

    private func updateDrag(entry: CatalogDevice, value: DragGesture.Value) {
        trackingGesture = true
        guard !cancelledGesture, model.canOrganizeDevices, !entry.isPinned, !model.hasDeviceSelection, width > 0,
            drag?.settling != true
        else { return }
        let slots = CatalogSlots(width: width, columns: columns)
        if drag == nil {
            guard let index = entries.firstIndex(where: { $0.id == entry.id }),
                let order = CatalogDragOrder(
                    deviceIDs: entries.map(\.id), pinnedIDs: pins, draggedID: entry.id,
                    allowedIDs: Set(
                        entries.filter {
                            $0.isPinned == entry.isPinned && $0.catalogRank == entry.catalogRank
                        }.map(\.id)))
            else { return }
            let origin = slots.origin(at: index)
            drag = MovingCard(
                order: order,
                grabOffset: CGSize(width: value.startLocation.x - origin.x, height: value.startLocation.y - origin.y),
                cardWidth: slots.cardWidth, position: value.location)
        }
        guard var moving = drag, moving.order.draggedID == entry.id else { return }
        moving.position = value.location
        let center = CGPoint(
            x: value.location.x - moving.grabOffset.width + moving.cardWidth / 2,
            y: value.location.y - moving.grabOffset.height + 50)
        moving.order.move(to: slots.nearestIndex(to: center, count: entries.count))
        drag = moving
        if let event = NSApp.currentEvent, event.type == .leftMouseDragged {
            scrollReference.scrollView?.documentView?.autoscroll(with: event)
        }
    }

    private func cancelDrag() {
        if trackingGesture { cancelledGesture = true }
        drag = nil
    }

    private func gestureCancelled() {
        trackingGesture = false
        cancelledGesture = false
        if drag?.settling != true { drag = nil }
    }

    private func finishDrag() {
        trackingGesture = false
        if cancelledGesture {
            cancelledGesture = false
            drag = nil
            return
        }
        guard var moving = drag, !moving.settling,
            let index = moving.order.deviceIDs.firstIndex(of: moving.order.draggedID)
        else { return }
        moving.settling = true
        drag = moving
        let origin = CatalogSlots(width: width, columns: columns).origin(at: index)
        withAnimation(.snappy(duration: 0.18), completionCriteria: .logicallyComplete) {
            drag?.position = CGPoint(x: origin.x + moving.grabOffset.width, y: origin.y + moving.grabOffset.height)
        } completion: {
            guard let completed = drag, completed.token == moving.token else { return }
            drag = nil
            if model.canOrganizeDevices, completed.order.isCompatible(deviceIDs: entries.map(\.id), pinnedIDs: pins) {
                model.moveDevice(completed.order.draggedID, before: completed.order.destinationBefore)
            }
        }
    }
}

@MainActor
private final class CatalogScrollReference {
    weak var scrollView: NSScrollView?
}

@MainActor
private struct CatalogScrollReader: NSViewRepresentable {
    let reference: CatalogScrollReference
    func makeNSView(context: Context) -> Reader {
        let view = Reader()
        view.reference = reference
        return view
    }
    func updateNSView(_ nsView: Reader, context: Context) {}
    final class Reader: NSView {
        var reference: CatalogScrollReference?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.scrollView = enclosingScrollView
        }
    }
}

private struct DeviceConnectionCountBadge: View {
    let count: Int

    private var diameter: CGFloat { max(15, CGFloat(String(count).count) * 6 + 6) }

    var body: some View {
        Text(count.formatted())
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(.secondary.opacity(0.55), lineWidth: 1))
            .fixedSize()
            .accessibilityLabel("\(count) matching devices connected")
    }
}

@MainActor
private struct DeviceCard: View {
    @Environment(\.clearCatalogDetail) private var clearCatalogDetail
    @Bindable var model: AppModel
    let entry: CatalogDevice
    let selected: Bool
    let selectionHelp: String
    let action: () -> Void
    var dragSpace: UUID = UUID()
    var dragChanged: ((DragGesture.Value) -> Void)?
    var dragEnded: (() -> Void)?
    var dragCancelled: (() -> Void)?
    @GestureState private var dragging = false
    @State private var confirmingForget = false
    @State private var confirmingBulkForget = false
    @State private var renaming = false

    private var menuTargets: [CatalogDevice] {
        model.hasDeviceSelection && model.selectedDeviceKeys.contains(entry.id) ? model.selectedCatalogEntries : [entry]
    }

    private var profile: DeviceProfile { entry.profile }
    private var showsPauseControl: Bool { entry.isConnected && entry.isManaged }
    private var statusSuffix: String? {
        guard entry.isConnected else { return nil }
        if !entry.isManaged { return "Not managed" }
        if !model.bridgeAvailable { return "Unavailable" }
        if model.paused || profile.isDevicePaused { return "Paused" }
        return nil
    }
    private var status: String {
        entry.connectionDescription + (statusSuffix.map { " · \($0)" } ?? "")
    }
    private var statusLabel: some View {
        HStack(spacing: 4) {
            Text(entry.isConnected ? "Connected" : entry.connectionDescription)
                .foregroundStyle(.secondary)
            if entry.connectionCount > 1 {
                DeviceConnectionCountBadge(count: entry.connectionCount)
            }
            if let statusSuffix {
                Text("·").foregroundStyle(.secondary)
                Text(statusSuffix).foregroundStyle(.orange)
            }
        }
    }
    private var transport: String {
        entry.transport.isEmpty ? entry.kind.rawValue.capitalized : entry.transport
    }
    private var pauseHelp: String {
        if !entry.isConnected { return "Reconnect this device to pause or resume its settings." }
        if !entry.isManaged { return "Manage this device again to control its settings." }
        if model.paused { return "Resume all devices before changing this device’s pause state." }
        if !model.bridgeAvailable { return "Device control is currently unavailable." }
        if !profile.hasCustomInputSettings { return "This device is already using macOS settings." }
        return profile.isDevicePaused ? "Resume settings for \(entry.name)." : "Pause settings for \(entry.name)."
    }

    var body: some View {
        card
            .background(CatalogSelectionClickRegion())
            .contextMenu {
                let targets = menuTargets
                let multiple = targets.count > 1
                let allPinned = targets.allSatisfy(\.isPinned)
                let allUnmanaged = targets.allSatisfy { !$0.isManaged }
                let disconnected = targets.filter { !$0.isConnected }.count
                Button(multiple ? "Rename devices" : "Rename", systemImage: "pencil") { renaming = true }
                    .disabled(multiple || !model.canOrganizeDevices)
                Button(
                    allPinned
                        ? (multiple ? "Unpin devices" : "Unpin device") : (multiple ? "Pin devices" : "Pin device"),
                    systemImage: allPinned ? "pin.slash" : "pin"
                ) {
                    for target in targets where target.isPinned == allPinned { model.toggleDevicePin(target.id) }
                }
                .disabled(!model.canOrganizeDevices)
                Menu("Connection type") {
                    DeviceConnectionActions(model: model, deviceKey: entry.id)
                }
                .disabled(multiple || !model.canOrganizeDevices)
                IncludeConnectionMenu(model: model, deviceKey: entry.id)
                    .disabled(multiple)
                if entry.isModelCard {
                    Button("Stop using for matching devices", systemImage: "square.stack.3d.up.slash") {
                        model.stopMatchingDevices(entry.id)
                    }
                    .disabled(multiple || !model.canOrganizeDevices)
                } else if !entry.identityPersistent {
                    Button("Use for all matching devices", systemImage: "square.stack") {
                        do { try model.captureModelCard(entry.id) } catch {
                            model.errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(
                        multiple || !model.canOrganizeDevices || !entry.isManaged
                            || entry.modelMetadata?.fingerprint == nil)
                }
                Divider()
                if allUnmanaged {
                    Button(multiple ? "Manage and show devices" : "Manage and show") {
                        for target in targets { model.manageAndShowDevice(target.id) }
                    }
                    .disabled(!model.canOrganizeDevices)
                } else {
                    Button(multiple ? "Don’t manage and hide devices" : "Don’t manage and hide") {
                        for target in targets { model.hideDevice(target.id) }
                        model.clearDeviceSelection()
                    }
                    .disabled(!model.canOrganizeDevices)
                }
                if disconnected > 0 {
                    Divider()
                    Button(
                        multiple ? "Forget \(disconnected) disconnected devices…" : "Forget device…",
                        systemImage: "trash", role: .destructive
                    ) {
                        if multiple { confirmingBulkForget = true } else { confirmingForget = true }
                    }
                    .disabled(!model.canOrganizeDevices)
                }
                if model.hasDeviceSelection || selected {
                    Divider()
                    Button("Clear selection") {
                        let closeDetail = !model.canClearDeviceSelection
                        model.clearDeviceSelection()
                        if closeDetail { clearCatalogDetail?() }
                    }
                    .disabled(!model.canClearDeviceSelection && clearCatalogDetail == nil)
                }
            }
            .alert("Forget selected devices?", isPresented: $confirmingBulkForget) {
                Button("Cancel", role: .cancel) {}
                Button("Forget", role: .destructive) { model.forgetSelectedDevices() }
                    .disabled(!model.canOrganizeDevices)
            } message: {
                Text("Removes their saved settings. Connected devices stay.")
            }
            .onChange(of: dragging) { _, active in
                if !active { dragCancelled?() }
            }
            .sheet(isPresented: $renaming) {
                RenameDeviceSheet(model: model, deviceKey: entry.id, currentName: entry.name)
            }
            .alert("Forget “\(entry.name)”?", isPresented: $confirmingForget) {
                Button("Cancel", role: .cancel) {}
                Button("Forget", role: .destructive) { model.removeDevice(entry.id) }
                    .disabled(entry.isConnected || !model.canOrganizeDevices)
            } message: {
                Text(
                    "Removes its saved settings. Reconnecting adds it as a new device."
                )
            }
            .onChange(of: entry.isConnected) { _, connected in if connected { confirmingForget = false } }
            .onChange(of: model.canOrganizeDevices) { _, available in if !available { confirmingForget = false } }
    }

    private var card: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: iconSymbol(entry.iconAppearance, kind: entry.kind))
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(
                            iconColor(
                                entry.iconAppearance,
                                fallback: entry.isConnected ? (entry.isManaged ? Palette.blue : .orange) : .gray)
                        )
                        .frame(width: 28, height: 36)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.system(size: 12, weight: .semibold))
                            .lineLimit(2).multilineTextAlignment(.leading)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            if entry.isModelCard {
                                Image(systemName: "square.stack")
                                    .font(.system(size: 9))
                                    .accessibilityHidden(true)
                            }
                            Text(
                                entry.isModelCard
                                    ? (entry.capturesAllMatches ? "All matching devices" : "Matching devices")
                                    : transport
                            )
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, entry.isPinned ? 18 : 0)
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    statusLabel.font(.system(size: 10))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, showsPauseControl ? 30 : 0)
                .frame(height: 26)
            }
            .padding(.horizontal, 11)
            .padding(.top, 12)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity)
            .frame(height: CatalogCardMetrics.height, alignment: .topLeading)
            .background(
                selected ? Palette.blue.opacity(0.075) : Palette.quiet, in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).strokeBorder(
                    selected ? Palette.blue.opacity(0.3) : Palette.border, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.7))
                        .rotationEffect(.degrees(30))
                        .frame(width: 18, height: 18)
                        .padding(7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named(dragSpace))
                    .updating($dragging) { _, active, _ in active = true }
                    .onChanged { dragChanged?($0) }
                    .onEnded { _ in dragEnded?() }
                    .exclusively(before: TapGesture().onEnded { action() })
            )
            .accessibilityElement(children: .ignore)
            .focusable(interactions: .activate)
            .onKeyPress(.return) {
                action()
                return .handled
            }
            .onKeyPress(.space) {
                action()
                return .handled
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
            .accessibilityAction(named: "Rename device") {
                if model.canOrganizeDevices { renaming = true }
            }
            .accessibilityAction(named: "Move earlier") { model.moveDeviceUp(entry.id) }
            .accessibilityAction(named: "Move later") { model.moveDeviceDown(entry.id) }
            .accessibilityLabel(
                "\(entry.name), \(transport), \(status)\(entry.isModelCard ? ", shared card for matching devices" : "")\(entry.isPinned ? ", pinned" : "")"
            )
            .accessibilityHint(selectionHelp)
            .accessibilityAddTraits(selected ? .isSelected : [])

            if showsPauseControl {
                // Pause is a sibling of selection, so it never opens or collapses the editor.
                Button {
                    model.setCatalogCardPaused(!profile.isDevicePaused, key: entry.id)
                } label: {
                    Image(systemName: profile.isDevicePaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Palette.quiet, in: Circle())
                        .overlay(Circle().strokeBorder(Palette.border))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    !entry.isConnected || !entry.isManaged
                        ? Color.gray : (profile.isDevicePaused ? Color.orange : Palette.blue)
                )
                .help(pauseHelp)
                .accessibilityLabel("\(profile.isDevicePaused ? "Resume" : "Pause") \(entry.name)")
                .disabled(
                    model.paused || !model.bridgeAvailable || !profile.hasCustomInputSettings
                        || !entry.isConnected || !entry.isManaged
                )
                .padding(9)
            }
        }
        .frame(height: CatalogCardMetrics.height)

    }
}

@MainActor
private struct AutomaticSetupToggle: View {
    @Bindable var model: AppModel
    var compact = false
    var explainTurningOff = false

    var body: some View {
        Toggle(isOn: $model.automaticallySetUpDevices) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Apply these defaults to future pointer devices")
                    .font(.system(size: 12, weight: .medium))
                Text(
                    compact
                        ? "Flat, no acceleration · Traditional · 3 lines per wheel step."
                        : "Flat movement without acceleration · Traditional scroll direction · 3 lines per wheel step."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if explainTurningOff {
                    Text("Saved device settings are preserved. Turning this off leaves current settings in place.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Apply these defaults to future pointer devices")
        .help(helpText)
    }

    private var helpText: String {
        "Apply these defaults to currently connected unconfigured external devices and future ones, where supported. Saved device settings are preserved. Turning this off leaves existing settings in place. Traditional scrolling follows mouse-wheel direction, like Windows. Touch scrolling stays continuous."
            + (model.hasBuiltInTrackpad ? " The built-in trackpad is excluded." : "")
    }
}

@MainActor
struct AppSettingsSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Mousü settings").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Done") { model.settingsPresented = false }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            AppSettingsView(model: model)
        }
        .frame(width: 490)
        .tint(Palette.blue)
        .background(SettingsOutsideClick { model.settingsPresented = false })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.settingsPresented = false
        }
        .onExitCommand { model.settingsPresented = false }
    }
}

@MainActor
private struct SettingsOutsideClick: NSViewRepresentable {
    var dismiss: () -> Void

    func makeNSView(context: Context) -> ObserverView {
        let view = ObserverView()
        view.dismiss = dismiss
        return view
    }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

    final class ObserverView: NSView {
        var dismiss: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                guard let self, let sheet = self.window, let parent = sheet.sheetParent else { return event }
                // Ignore the settings panel's own menus and popovers.
                guard event.window == nil || event.window === parent || event.window === sheet else { return event }
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                guard parent.frame.contains(point), !sheet.frame.contains(point) else { return event }
                self.dismiss?()
                return nil  // The dismissal click must not activate a control underneath.
            }
        }

        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

@MainActor
struct AppSettingsView: View {
    @AppStorage("tryAreaEffect") private var effect = TryAreaEffect.initial()
    @AppStorage("crtUnlocked") private var crtUnlocked = false
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.requiresSetup {
            VStack(alignment: .leading, spacing: 18) {
                AppMark(size: 44)
                Text("Finish setting up Mousü")
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                Text(
                    model.permissionGranted
                        ? "Accessibility is ready. Click Continue in the main window to finish."
                        : "Choose your defaults and allow Accessibility in the main window."
                )
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                Button("Open setup") {
                    model.settingsPresented = false
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(30)
            .frame(width: 430, alignment: .leading)
            .tint(Palette.blue)
        } else {
            settingsContent
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9"
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppMark(size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Mousü")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                        Text(version)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(AppCopy.tagline)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            settingsSection("General", spacing: 8) {
                settingsRow("Show in menu bar", isOn: $model.menuBarVisible)
                    .help("Quick access to your device controls.")
                    .accessibilityLabel("Show menu bar item")
                Divider()
                settingsRow("Hide Dock icon when closed", isOn: $model.hideDockWhenClosed)
                    .help(
                        "Device settings stay active after closing the window. Open Mousü from Applications to return, even with the menu bar item hidden."
                    )
                Divider()
                settingsRow("Open at login", isOn: $model.launchAtLogin)
                    .help("Start Mousü when you sign in.")
                    .accessibilityLabel("Launch at login")
            }

            settingsSection("Devices") {
                settingsRow(
                    "Automatically set up new devices",
                    detail: "Flat movement · Traditional scrolling · 3 lines per wheel step",
                    isOn: $model.automaticallySetUpDevices
                )
                .help(
                    "Applies to unconfigured connected and future external devices, where supported. Individual settings and model profiles take priority. Turning this off leaves current settings in place."
                )
            }

            if crtUnlocked {
                settingsSection("Try area effect") {
                    Picker("Try area effect", selection: $effect) {
                        ForEach(TryAreaEffect.allCases.filter { $0 != .crt || crtUnlocked }, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Try area effect")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("Closing the window keeps Mousü running. Quitting restores the system settings it changed.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack {
                    Text("Input status")
                    Spacer()
                    Text(model.status).foregroundStyle(.secondary)
                }
                .font(.system(size: 11, weight: .medium))
                Text(model.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 490)
        .tint(Palette.blue)
    }

    private func settingsSection<Content: View>(
        _ title: String, spacing: CGFloat = 12, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.leading, 2)
            VStack(alignment: .leading, spacing: spacing, content: content)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary.opacity(0.5)))
        }
    }

    private func settingsRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

}

private struct AppMark: View {
    let size: CGFloat

    var body: some View {
        MousuSymbol(size: size)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [Palette.blue.opacity(0.85), Palette.blue], startPoint: .topLeading,
                    endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.29)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.29).strokeBorder(.white.opacity(0.15)))
    }
}

private func deviceSymbol(_ device: DeviceInfo) -> String {
    deviceSymbol(device.kind)
}

private func deviceSymbol(_ kind: DeviceKind) -> String {
    switch kind {
    case .trackball: "circle.circle"
    case .trackpad: "rectangle.and.hand.point.up.left"
    case .mouse: "computermouse"
    case .other: "cursorarrow.motionlines"
    }
}

private let deviceIconShapes: [(String, String)] = [
    ("automatic", "Automatic"), ("computermouse", "Mouse"), ("circle.circle", "Trackball"),
    ("rectangle.and.hand.point.up.left", "Trackpad"), ("cursorarrow", "Pointer"),
    ("star", "Star"), ("hexagon", "Hexagon"), ("diamond", "Diamond"),
]
private let deviceIconColors: [(String, Color)] = [
    ("automatic", Palette.blue), ("blue", .blue), ("purple", .purple), ("pink", .pink),
    ("green", .green), ("teal", .teal),
]

private func iconSymbol(_ appearance: DeviceIconAppearance, kind: DeviceKind) -> String {
    deviceIconShapes.contains(where: { $0.0 == appearance.shape }) && appearance.shape != "automatic"
        ? appearance.shape : deviceSymbol(kind)
}

private func iconColor(_ appearance: DeviceIconAppearance, fallback: Color) -> Color {
    appearance.color == "automatic"
        ? fallback : deviceIconColors.first(where: { $0.0 == appearance.color })?.1 ?? Palette.blue
}

struct DeviceIconButton: View {
    @Bindable var model: AppModel
    let deviceKey: String
    let kind: DeviceKind
    let size: CGFloat
    let symbolSize: CGFloat
    var fallbackColor: Color = Palette.blue
    @State private var presented = false
    @State private var hovered = false

    private var appearance: DeviceIconAppearance { model.deviceIconAppearance(deviceKey) }
    private var color: Color { iconColor(appearance, fallback: fallbackColor) }

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            Image(systemName: iconSymbol(appearance, kind: kind))
                .font(.system(size: symbolSize, weight: .light))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(color.opacity(hovered ? 0.15 : 0.075), in: RoundedRectangle(cornerRadius: size * 0.3))
                .contentShape(RoundedRectangle(cornerRadius: size * 0.3))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Change device icon and color")
        .accessibilityLabel("Change device icon and color")
        .disabled(!model.canOrganizeDevices)
        .popover(isPresented: $presented) { picker }
    }

    var picker: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Device icon").font(.headline)
            Text("Shape").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38)), count: 4), spacing: 8) {
                ForEach(deviceIconShapes, id: \.0) { shape in
                    Button {
                        var updated = appearance
                        updated.shape = shape.0
                        model.setDeviceIconAppearance(deviceKey, appearance: updated)
                    } label: {
                        Image(systemName: shape.0 == "automatic" ? "a.circle" : shape.0)
                            .font(.system(size: 20, weight: .light))
                            .frame(width: 36, height: 36)
                            .background(
                                color.opacity(appearance.shape == shape.0 ? 0.2 : 0),
                                in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(color)
                    .help(shape.1)
                    .accessibilityLabel(shape.1)
                    .accessibilityAddTraits(appearance.shape == shape.0 ? .isSelected : [])
                }
            }
            .frame(height: 80)
            Text("Color").font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28)), count: 6), spacing: 8) {
                ForEach(deviceIconColors, id: \.0) { choice in
                    Button {
                        var updated = appearance
                        updated.color = choice.0
                        model.setDeviceIconAppearance(deviceKey, appearance: updated)
                    } label: {
                        Circle().fill(choice.1).frame(width: 24, height: 24)
                            .overlay {
                                if appearance.color == choice.0 {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                } else if choice.0 == "automatic" {
                                    Text("A").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(choice.0.capitalized)
                    .accessibilityLabel(choice.0.capitalized)
                    .accessibilityAddTraits(appearance.color == choice.0 ? .isSelected : [])
                }
            }
            .frame(height: 56)
            Divider()
            Button("Reset to automatic") {
                model.setDeviceIconAppearance(deviceKey, appearance: DeviceIconAppearance())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .frame(width: 208)
        .padding(18)
        .fixedSize()
    }
}

@MainActor
private struct DeviceCleanupActions: View {
    @Bindable var model: AppModel
    @Binding var confirmingForget: Bool
    private var entries: [CatalogDevice] { model.selectedCatalogEntries }
    private var disconnectedCount: Int { entries.filter { !$0.isConnected }.count }

    var body: some View {
        Text("\(entries.count) selected")
        Button("Don’t manage and hide selected") { model.hideSelectedDevices() }
            .disabled(entries.isEmpty || !model.canOrganizeDevices)
        Button("Forget \(disconnectedCount) disconnected devices…", systemImage: "trash", role: .destructive) {
            confirmingForget = true
        }
        .disabled(disconnectedCount == 0 || !model.canOrganizeDevices)
        Button("Clear selection") { model.clearDeviceSelection() }
            .disabled(!model.canClearDeviceSelection)
    }
}

@MainActor
struct CatalogEscapeHandler: NSViewRepresentable {
    fileprivate var menuPanelDismissal: MenuPanelWindowReference? = nil
    let clearOnOutsideClick: () -> Void
    let clear: () -> Bool
    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ view: Reader, context: Context) {
        view.clear = clear
        view.clearOnOutsideClick = clearOnOutsideClick
        view.menuPanelDismissal = menuPanelDismissal
    }
    static func dismantleNSView(_ view: Reader, coordinator: ()) { view.stop() }

    final class Reader: NSView, MenuPanelEscapeHandling {
        func cancelMenuInteraction() -> Bool { clear?() == true }
        var clear: (() -> Bool)?
        var clearOnOutsideClick: (() -> Void)?
        var monitor: Any?
        fileprivate weak var menuPanelDismissal: MenuPanelWindowReference? {
            didSet {
                if window != nil { menuPanelDismissal?.catalogEscapeHandler = self }
            }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            menuPanelDismissal?.catalogEscapeHandler = self
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self, let window = self.window, window.attachedSheet == nil else { return event }
                if event.type == .leftMouseDown {
                    if event.window === window {
                        self.handleClick(at: event.locationInWindow)
                    } else if event.window == nil && window.isVisible {
                        self.handleClick(at: window.convertPoint(fromScreen: NSEvent.mouseLocation))
                    }
                    return event
                }
                guard event.window === window else { return event }
                guard event.keyCode == 53 else { return event }
                // The menu's single handler clears selection before closing,
                // independent of the order AppKit invokes its local monitors.
                guard self.menuPanelDismissal == nil else { return event }
                // Let editors/popovers handle Escape themselves.
                if let responder = self.window?.firstResponder, responder is NSTextView { return event }
                return self.clear?() == true ? nil : event
            }
        }
        func handleClick(at point: NSPoint) {
            guard let content = window?.contentView, !isSelectionControl(content, point: point) else { return }
            clearOnOutsideClick?()
        }

        func isSelectionControl(_ view: NSView, point: NSPoint) -> Bool {
            if view is CatalogSelectionClickRegion.Region,
                !view.isHiddenOrHasHiddenAncestor,
                view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil))
            {
                return true
            }
            return view.subviews.contains { isSelectionControl($0, point: point) }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if menuPanelDismissal?.catalogEscapeHandler === self {
                menuPanelDismissal?.catalogEscapeHandler = nil
            }
        }
    }
}

/// Preserve selection while clicking cards or opening its action menu.
@MainActor
struct CatalogSelectionClickRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> Region { Region() }
    func updateNSView(_ view: Region, context: Context) {}
    final class Region: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct ClearCatalogDetailKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void)? = nil
}

extension EnvironmentValues {
    fileprivate var clearCatalogDetail: (@MainActor @Sendable () -> Void)? {
        get { self[ClearCatalogDetailKey.self] }
        set { self[ClearCatalogDetailKey.self] = newValue }
    }
}

private enum CatalogCardMetrics {
    static let height: CGFloat = 92
}
