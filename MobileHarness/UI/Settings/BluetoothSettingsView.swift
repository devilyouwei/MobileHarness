import Foundation

#if os(iOS)
    import SwiftUI

    @MainActor
    public struct BluetoothSettingsView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        @Bindable var state: BluetoothSettingsState
        private let controls: any BluetoothControlling
        @State private var forgetting = false
        @State private var deviceForDetail: BluetoothDeviceRow?
        public init(state: BluetoothSettingsState, controls: any BluetoothControlling) {
            self.state = state
            self.controls = controls
        }
        public var body: some View {
            List {
                availabilitySection
                myDevicesSection
                nearbySection
            }
            .buttonStyle(.borderless)
            .navigationDestination(item: $deviceForDetail) { device in
                BluetoothArmDetailView(state: state, controls: controls, device: device)
            }
            .navigationTitle(appCopy.text("Bluetooth devices"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if state.connectionBusy, state.phase != .disconnecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(appCopy.text("Cancel"), action: controls.disconnect)
                            .accessibilityIdentifier("settings.bluetooth.cancelConnection")
                    }
                }
            }
            .preferredColorScheme(.dark)
            .task { controls.openPage() }
            .onDisappear { controls.closePage() }
            .confirmationDialog(
                appCopy.text("Forget this robot arm?"), isPresented: $forgetting, titleVisibility: .visible
            ) {
                Button(appCopy.text("Forget device"), role: .destructive, action: controls.forget)
            } message: {
                Text(appCopy.text("This disconnects and forgets the device."))
            }
        }
        @ViewBuilder private var availabilitySection: some View {
            Section {
                LabeledContent(appCopy.text("Bluetooth"), value: availabilityText)
                LabeledContent(
                    appCopy.text("Robot arm connection"), value: appCopy.text(state.connectionPresentation.title))
                if state.availability == .denied {
                    Button(appCopy.text("Allow Bluetooth in System Settings"), action: controls.openSystemSettings)
                        .accessibilityIdentifier("settings.bluetooth.permission")
                }
            } footer: {
                Text(appCopy.text("The last device reconnects automatically until manually disconnected."))
            }
        }
        @ViewBuilder private var myDevicesSection: some View {
            if let device = state.myDevice {
                Section(appCopy.text("My devices")) {
                    deviceRow(device)
                    if state.isConnected(device.id) {
                        Button(appCopy.text("Disconnect"), action: controls.disconnect)
                            .accessibilityIdentifier("settings.bluetooth.disconnect")
                    }
                    Button(appCopy.text("Forget this device"), role: .destructive) { forgetting = true }
                        .accessibilityIdentifier("settings.bluetooth.forget")
                }
            }
        }
        @ViewBuilder private var nearbySection: some View {
            if state.phase != .connected {
                Section {
                    ForEach(state.otherDevices) { device in
                        deviceRow(device)
                    }
                    Button {
                        if state.scanning { controls.stopScan() } else { controls.scan() }
                    } label: {
                        HStack {
                            Text(
                                state.scanning ? appCopy.text("Stop scanning") : appCopy.text("Scan for nearby devices")
                            )
                            Spacer()
                            if state.scanning { ProgressView() }
                        }
                    }
                    .disabled(!state.canScan)
                    .accessibilityIdentifier("settings.bluetooth.scan")
                    if state.otherDevices.isEmpty && !state.scanning {
                        Text(appCopy.text("No devices found")).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(appCopy.text("Nearby devices"))
                }
            }
        }
        private var availabilityText: String {
            switch state.availability {
            case .unknown: appCopy.text("Checking")
            case .available: appCopy.text("On")
            case .poweredOff: appCopy.text("Off. Turn Bluetooth on in Control Center.")
            case .denied: appCopy.text("Access denied")
            case .unsupported: appCopy.text("Unsupported on this device")
            }
        }
        private func deviceRow(_ device: BluetoothDeviceRow) -> some View {
            Button {
                switch state.rowIntent(for: device.id) {
                case .connect: controls.connect(device.id)
                case .openDetail: deviceForDetail = device
                case .unavailable: break
                }
            } label: {
                rowLabel(device)
            }
            .disabled(state.rowIntent(for: device.id) == .unavailable)
            .accessibilityIdentifier("settings.bluetooth.device.\(device.id)")
        }
        private func rowLabel(_ device: BluetoothDeviceRow) -> some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .foregroundStyle(state.rowIntent(for: device.id) == .unavailable ? Color.secondary : .primary)
                    if let message = state.currentMessage(for: device.id) {
                        Text(appCopy.text(message)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if state.selected?.id == device.id && state.connectionBusy { ProgressView() }
                Text(appCopy.text(state.status(for: device.id))).font(.subheadline)
                    .foregroundStyle(state.hasConnectionIssue(device.id) ? Color.yellow : .secondary)
                if state.isConnected(device.id) {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
    }

    @MainActor
    private struct BluetoothArmDetailView: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        @Bindable var state: BluetoothSettingsState
        let controls: any BluetoothControlling
        let device: BluetoothDeviceRow
        private var connected: Bool { state.isConnected(device.id) }
        private var canControl: Bool { state.canControl(device.id) }
        var body: some View {
            List {
                Section(appCopy.text("Current status")) {
                    LabeledContent(appCopy.text("Connection")) {
                        Text(appCopy.text(state.status(for: device.id)))
                            .foregroundStyle(state.hasConnectionIssue(device.id) ? Color.yellow : .secondary)
                    }
                    if state.recoveryDeviceID == device.id, state.recoveryStage != .idle {
                        LabeledContent(appCopy.text("Recovery"), value: appCopy.text(state.recoveryStage.title))
                        if state.recoveryAttempt > 0 {
                            LabeledContent(
                                appCopy.text("Attempts"),
                                value: appCopy.format("%@/3 attempts", String(describing: state.recoveryAttempt)))
                        }
                    }
                    Button(appCopy.text("Reconnect")) { controls.reconnect(device.id) }
                        .disabled(state.connectionBusy || state.availability != .available)
                        .accessibilityIdentifier("settings.bluetooth.reconnect")
                    if state.recoveryDeviceID == device.id, state.recoveryStage.busy {
                        Button(appCopy.text("Cancel recovery and disconnect"), action: controls.disconnect)
                            .accessibilityIdentifier("settings.bluetooth.cancelRecovery")
                    }
                }
                if let message = state.currentMessage(for: device.id) {
                    Section {
                        Text(appCopy.text(message)).font(.subheadline).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.bluetooth.currentError")
                    }
                }
                if connected {
                    Section(appCopy.text("Device feedback")) {
                        if state.pose.count == 6 {
                            LabeledContent(
                                appCopy.text("End effector position"),
                                value: "X \(state.pose[0]) · Y \(state.pose[1]) · Z \(state.pose[2]) mm")
                        }
                        if let sampledAt = state.sampledAt {
                            LabeledContent(appCopy.text("Position updated at")) { Text(sampledAt, style: .time) }
                        }
                        Button(appCopy.text("Refresh position")) { Task { await controls.refreshDevice() } }
                            .disabled(state.connectionBusy)
                    }
                }
                Section(appCopy.text("Actions")) {
                    ForEach(BluetoothArmAction.allCases.filter { $0 != .reset }) { action in
                        Button {
                            controls.tryAction(action)
                        } label: {
                            HStack {
                                Text(appCopy.text(action.title))
                                Spacer()
                                Image(systemName: "play.circle.fill")
                            }
                        }
                        .accessibilityLabel(appCopy.format("Try %@", String(describing: action.title)))
                        .accessibilityIdentifier("settings.bluetooth.action.\(action.rawValue)")
                    }
                }
                .disabled(!canControl)
                Section {
                    Button(appCopy.text("Home the arm"), systemImage: "arrow.counterclockwise") {
                        controls.tryAction(.reset)
                    }
                    .disabled(!canControl)
                    .accessibilityIdentifier("settings.bluetooth.reset")
                }
                Section {
                    ForEach(1...6, id: \.self) { id in
                        BluetoothMotorSlider(
                            id: id, position: state.joints.count == 6 ? state.joints[id - 1] : nil,
                            enabled: canControl, controls: controls
                        )
                        .disabled(!canControl)
                    }
                } header: {
                    Text(appCopy.text("Motor controls"))
                } footer: {
                    Text(appCopy.text("Slide to control direction and speed. Release to stop and hold position."))
                }
            }
            .buttonStyle(.borderless)
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { if connected { await controls.refreshDevice() } }
            .refreshable { if connected { await controls.refreshDevice() } }
            .onDisappear { controls.stopMotorControl() }
        }
    }

    @MainActor
    private struct BluetoothMotorSlider: View {
        @Environment(\.locale) private var appCopyLocale
        private var appCopy: AppLanguage { AppLanguage(preferredLanguage: appCopyLocale.identifier) }
        let id: Int
        let position: Int?
        let enabled: Bool
        let controls: any BluetoothControlling
        @State private var draft = 0.0
        @GestureState private var touching = false
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(appCopy.format("Motor %@", String(describing: id)))
                    Spacer()
                    if touching {
                        Text("\(Int(abs(draft) * 100))%").monospacedDigit()
                    } else if let position {
                        Text(appCopy.format("Last position %@", String(describing: position))).foregroundStyle(
                            .secondary
                        ).monospacedDigit()
                    }
                }
                GeometryReader { geometry in
                    let width = max(1, geometry.size.width - 32)
                    ZStack {
                        Capsule().fill(.quaternary).frame(height: 6)
                        Rectangle().fill(.secondary).frame(width: 2, height: 16)
                        Circle().fill(enabled ? Color.blue : Color.gray).frame(width: 30, height: 30)
                            .offset(x: CGFloat(draft) * width / 2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($touching) { _, active, _ in active = true }
                            .onChanged { value in
                                guard enabled else { return }
                                draft = min(
                                    1, max(-1, Double((value.location.x - geometry.size.width / 2) / (width / 2))))
                                controls.setMotorVelocity(id: id, value: draft)
                            }
                            .onEnded { _ in release() }
                    )
                    .allowsHitTesting(enabled)
                }
                .frame(height: 44)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appCopy.format("Motor %@ direction and speed", String(describing: id)))
                .accessibilityValue("\(Int(draft * 100))%")
                .accessibilityIdentifier("settings.bluetooth.motor.\(id)")
                HStack {
                    Image(systemName: "minus")
                    Spacer()
                    Image(systemName: "plus")
                }.font(.caption).foregroundStyle(.secondary)
            }
            .opacity(enabled ? 1 : 0.45)
            .onChange(of: touching) { _, active in if !active { release() } }
            .onChange(of: enabled) { _, active in if !active { release() } }
            .onDisappear { release() }
        }
        private func release() {
            controls.setMotorVelocity(id: id, value: 0)
            withAnimation(.easeOut(duration: 0.15)) { draft = 0 }
        }
    }
#endif
