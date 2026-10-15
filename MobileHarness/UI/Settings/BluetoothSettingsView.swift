import Foundation

#if os(iOS)
    import SwiftUI

    @MainActor
    public struct BluetoothSettingsView: View {
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
            .navigationTitle("蓝牙外设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if state.connectionBusy, state.phase != .disconnecting {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("取消", action: controls.disconnect)
                            .accessibilityIdentifier("settings.bluetooth.cancelConnection")
                    }
                }
            }
            .preferredColorScheme(.dark)
            .task { controls.openPage() }
            .onDisappear { controls.closePage() }
            .confirmationDialog("忽略这台机械臂？", isPresented: $forgetting, titleVisibility: .visible) {
                Button("忽略设备", role: .destructive, action: controls.forget)
            } message: {
                Text("将断开连接并忘记此设备。")
            }
        }
        @ViewBuilder private var availabilitySection: some View {
            Section {
                LabeledContent("蓝牙", value: availabilityText)
                if state.availability == .denied {
                    Button("前往系统设置允许蓝牙", action: controls.openSystemSettings)
                        .accessibilityIdentifier("settings.bluetooth.permission")
                }
            } footer: {
                Text("自动重连上次设备；手动断开后不再重连。")
            }
        }
        @ViewBuilder private var myDevicesSection: some View {
            if let device = state.myDevice {
                Section("我的设备") {
                    deviceRow(device)
                    if state.isConnected(device.id) {
                        Button("断开连接", action: controls.disconnect)
                            .accessibilityIdentifier("settings.bluetooth.disconnect")
                    }
                    Button("忽略此设备", role: .destructive) { forgetting = true }
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
                            Text(state.scanning ? "停止搜索" : "搜索附近设备")
                            Spacer()
                            if state.scanning { ProgressView() }
                        }
                    }
                    .disabled(!state.canScan)
                    .accessibilityIdentifier("settings.bluetooth.scan")
                    if state.otherDevices.isEmpty && !state.scanning {
                        Text("暂未发现设备").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("附近设备")
                }
            }
        }
        private var availabilityText: String {
            switch state.availability {
            case .unknown: "正在检查"
            case .available: "已开启"
            case .poweredOff: "已关闭，请在控制中心开启"
            case .denied: "未允许访问"
            case .unsupported: "当前设备不支持"
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
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if state.selected?.id == device.id && state.connectionBusy { ProgressView() }
                Text(state.status(for: device.id)).font(.subheadline)
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
        @Bindable var state: BluetoothSettingsState
        let controls: any BluetoothControlling
        let device: BluetoothDeviceRow
        private var connected: Bool { state.isConnected(device.id) }
        private var canControl: Bool { state.canControl(device.id) }
        var body: some View {
            List {
                Section("当前状态") {
                    LabeledContent("连接") {
                        Text(state.status(for: device.id))
                            .foregroundStyle(state.hasConnectionIssue(device.id) ? Color.yellow : .secondary)
                    }
                    if state.recoveryDeviceID == device.id, state.recoveryStage != .idle {
                        LabeledContent("恢复", value: state.recoveryStage.title)
                        if state.recoveryAttempt > 0 {
                            LabeledContent("已尝试", value: "\(state.recoveryAttempt)/3 次")
                        }
                    }
                    Button("重新连接") { controls.reconnect(device.id) }
                        .disabled(state.connectionBusy || state.availability != .available)
                        .accessibilityIdentifier("settings.bluetooth.reconnect")
                    if state.recoveryDeviceID == device.id, state.recoveryStage.busy {
                        Button("取消恢复 / 断开", action: controls.disconnect)
                            .accessibilityIdentifier("settings.bluetooth.cancelRecovery")
                    }
                }
                if let message = state.currentMessage(for: device.id) {
                    Section {
                        Text(message).font(.subheadline).foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("settings.bluetooth.currentError")
                    }
                }
                if connected {
                    Section("设备反馈") {
                        if state.pose.count == 6 {
                            LabeledContent(
                                "末端位置", value: "X \(state.pose[0]) · Y \(state.pose[1]) · Z \(state.pose[2]) mm")
                        }
                        if let sampledAt = state.sampledAt {
                            LabeledContent("位置更新于") { Text(sampledAt, style: .time) }
                        }
                        Button("刷新位置") { Task { await controls.refreshDevice() } }
                            .disabled(state.connectionBusy)
                    }
                }
                Section("动作") {
                    ForEach(BluetoothArmAction.allCases.filter { $0 != .reset }) { action in
                        Button {
                            controls.tryAction(action)
                        } label: {
                            HStack {
                                Text(action.title)
                                Spacer()
                                Image(systemName: "play.circle.fill")
                            }
                        }
                        .accessibilityLabel("试一试\(action.title)")
                        .accessibilityIdentifier("settings.bluetooth.action.\(action.rawValue)")
                    }
                }
                .disabled(!canControl)
                Section {
                    Button("整臂归位", systemImage: "arrow.counterclockwise") { controls.tryAction(.reset) }
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
                    Text("电机控制")
                } footer: {
                    Text("滑动控制方向和速度，松手停止并保持当前位置。")
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
        let id: Int
        let position: Int?
        let enabled: Bool
        let controls: any BluetoothControlling
        @State private var draft = 0.0
        @GestureState private var touching = false
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("电机 \(id)")
                    Spacer()
                    if touching {
                        Text("\(Int(abs(draft) * 100))%").monospacedDigit()
                    } else if let position {
                        Text("上次位置 \(position)").foregroundStyle(.secondary).monospacedDigit()
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
                .accessibilityLabel("电机 \(id)方向与速度")
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
