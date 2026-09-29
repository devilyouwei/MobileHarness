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
                connectionSection
                messageSection
            }
            .navigationTitle("蓝牙设备")
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
                Text("连接并验证后，机械臂会复位，并让 ID5 向两侧各转约 8° 后回中。请留出活动空间。完成后返回对话说“让底座左右晃动一次”。请先断开 Wonderbot 的连接。")
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
                } footer: {
                    Text("显示附近可发现的 BLE 设备，NexArm 名字的设备优先。设备名称不代表兼容性，连接后会检查通信协议。")
                }
            }
        }
        @ViewBuilder private var connectionSection: some View {
            if state.phase == .indicating {
                Section { Label("正在复位并轻摇 ID5…", systemImage: "arrow.triangle.2.circlepath") }
            }
            if state.phase == .connected {
                Section {
                    if state.controlReady {
                        Label("可以通过对话控制", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("支持底座左右晃动 1～3 次，每侧约 2°，完成后回位。")
                    } else {
                        Label("蓝牙已连接，控制待验证", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    }
                    if let status = state.motionStatus { Text(status).foregroundStyle(.secondary) }
                } footer: {
                    Text("锁屏后会取消后续动作，已发出的短动作可能继续到位。返回 App 会自动恢复上次连接，不重复复位或摇动；手动断开后不自动重连。")
                }
            }
        }
        @ViewBuilder private var messageSection: some View {
            if let error = state.error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("settings.bluetooth.error") }
            } else if let notice = state.notice {
                Section { Text(notice).foregroundStyle(.secondary) }
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
                controls.connect(device.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill").foregroundStyle(.blue)
                    Text(device.name).foregroundStyle(.primary)
                    Spacer()
                    if state.selected?.id == device.id && state.connectionBusy { ProgressView() }
                    Text(state.status(for: device.id)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .disabled(state.connectionBusy || state.phase == .connected || state.executing)
            .accessibilityIdentifier("settings.bluetooth.device.\(device.id.uuidString)")
        }
    }
#endif
