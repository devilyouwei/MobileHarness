#if os(iOS)
    import SwiftUI

    @MainActor
    public struct BluetoothSettingsView: View {
        @Bindable var state: BluetoothSettingsState
        private let controls: any BluetoothControlling
        @State private var forgetting = false
        public init(state: BluetoothSettingsState, controls: any BluetoothControlling) {
            self.state = state
            self.controls = controls
        }
        public var body: some View {
            List {
                availabilitySection
                myDevicesSection
                nearbySection
                messageSection
            }
            .navigationTitle("蓝牙外设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .task { controls.openPage() }
            .onDisappear { controls.closePage() }
            .confirmationDialog("忽略这台机械臂？", isPresented: $forgetting, titleVisibility: .visible) {
                Button("忽略设备", role: .destructive, action: controls.forget)
            } message: {
                Text("会断开连接并移除本机记录。之后可重新搜索连接。")
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
                Text("返回 App 时会自动恢复上次连接。手动断开后不再自动连接。")
            }
        }
        @ViewBuilder private var myDevicesSection: some View {
            if let device = state.selected ?? state.remembered {
                Section("我的设备") {
                    deviceRow(device)
                    if state.selected?.id == device.id && state.phase != .idle {
                        Button(state.connectionBusy ? "取消连接 / 断开" : "断开连接", action: controls.disconnect)
                            .disabled(state.phase == .disconnecting)
                            .accessibilityIdentifier("settings.bluetooth.disconnect")
                    }
                    Button("忽略此设备", role: .destructive) { forgetting = true }
                        .disabled(state.connectionBusy || state.executing)
                        .accessibilityIdentifier("settings.bluetooth.forget")
                }
            }
        }
        @ViewBuilder private var nearbySection: some View {
            if state.phase != .connected {
                Section {
                    ForEach(state.nearby.filter { $0.id != (state.selected ?? state.remembered)?.id }) { device in
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
                    if state.nearby.isEmpty && !state.scanning {
                        Text("暂未发现设备").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("附近设备")
                }
            }
        }
        @ViewBuilder private var messageSection: some View {
            if let error = state.error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("settings.bluetooth.error") }
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
        @ViewBuilder private func deviceRow(_ device: BluetoothDeviceRow) -> some View {
            if state.selected?.id == device.id && state.phase == .connected {
                NavigationLink {
                    BluetoothArmDetailView(state: state, controls: controls, device: device)
                } label: {
                    rowLabel(device)
                }
                .accessibilityIdentifier("settings.bluetooth.device.\(device.id.uuidString)")
            } else {
                Button {
                    controls.connect(device.id)
                } label: {
                    rowLabel(device)
                }
                .disabled(state.connectionBusy || state.phase == .connected || state.executing)
                .accessibilityIdentifier("settings.bluetooth.device.\(device.id.uuidString)")
            }
        }
        private func rowLabel(_ device: BluetoothDeviceRow) -> some View {
            HStack(spacing: 12) {
                Image(systemName: "sensor.tag.radiowaves.forward.fill").foregroundStyle(.blue)
                Text(device.name).foregroundStyle(.primary)
                Spacer()
                if state.selected?.id == device.id && state.connectionBusy { ProgressView() }
                Text(state.status(for: device.id)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private struct BluetoothArmDetailView: View {
        @Bindable var state: BluetoothSettingsState
        let controls: any BluetoothControlling
        let device: BluetoothDeviceRow
        private var connected: Bool { state.selected?.id == device.id && state.phase == .connected }
        var body: some View {
            List {
                Section("当前状态") {
                    LabeledContent("连接", value: state.status(for: device.id))
                    if connected {
                        LabeledContent(
                            "机械臂",
                            value: state.testing
                                ? "测试指令发送中" : state.jogging ? "手动控制中" : (state.executing ? "动作执行中" : "待机"))
                        if state.pose.count == 6 {
                            LabeledContent(
                                "末端位置", value: "X \(state.pose[0]) · Y \(state.pose[1]) · Z \(state.pose[2]) mm")
                        }
                        if let sampledAt = state.sampledAt {
                            LabeledContent("位置更新于") { Text(sampledAt, style: .time) }
                        }
                        Button("刷新状态 / 验证控制") { Task { await controls.refreshDevice() } }
                            .disabled(state.executing || state.refreshing || state.connectionBusy)
                    }
                    if let status = state.motionStatus, connected { Text(status).foregroundStyle(.secondary) }
                    if let error = state.error { Text(error).foregroundStyle(.red) }
                }
                Section("动作") {
                    ForEach(BluetoothArmAction.allCases.filter { $0 != .reset }) { action in
                        Button {
                            controls.tryAction(action)
                        } label: {
                            HStack {
                                Text(action.title).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "play.circle.fill")
                            }
                        }
                        .accessibilityLabel("试一试\(action.title)")
                        .accessibilityIdentifier("settings.bluetooth.action.\(action.rawValue)")
                    }
                }
                .disabled(!connected)
                Section {
                    Button("整臂归位", systemImage: "arrow.counterclockwise") { controls.tryAction(.reset) }
                        .disabled(!connected)
                        .accessibilityIdentifier("settings.bluetooth.reset")
                }
                Section {
                    ForEach(1...6, id: \.self) { id in
                        BluetoothMotorSlider(
                            id: id, position: state.joints.count == 6 ? state.joints[id - 1] : nil,
                            enabled: connected, controls: controls)
                    }
                } header: {
                    Text("电机控制")
                } footer: {
                    Text("按住滑动控制方向和速度，离中心越远越快。松手停止，机械臂保持当前位置。")
                }
            }
            .navigationTitle(device.name)
            .navigationBarTitleDisplayMode(.inline)
            .task { await controls.refreshDevice() }
            .refreshable { await controls.refreshDevice() }
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
