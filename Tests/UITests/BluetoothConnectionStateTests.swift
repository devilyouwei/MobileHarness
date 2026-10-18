import Foundation
import Testing

@testable import UI

@Test @MainActor
func bluetoothConnectionLabelsIgnoreExecutionMessagesAndManualActivity() {
    let state = BluetoothSettingsState()
    let device = BluetoothDeviceRow(id: UUID().uuidString, name: "Nex_Arm")
    state.selected = device
    state.phase = .connected
    state.jogging = true
    state.error = "动作反馈超时"
    state.notice = "未收到位置反馈"
    #expect(state.summary == "已连接")
    #expect(state.status(for: device.id) == "已连接")
    #expect(state.status(for: UUID().uuidString) == "未连接")
    // Execution presentation messages do not change native connection status.
    state.error = nil
    state.notice = nil
    #expect(state.controlReady && state.summary == "已连接")
}

@Test @MainActor
func bluetoothConnectionLabelsFollowCurrentRecovery() {
    let state = BluetoothSettingsState()
    let device = BluetoothDeviceRow(id: UUID().uuidString, name: "Nex_Arm")
    state.selected = device
    state.error = "旧动作异常"
    state.phase = .connecting
    #expect(state.status(for: device.id) == "正在连接…")
    state.phase = .idle
    state.recoveryStage = .waiting
    #expect(state.summary == "正在重连…")
    state.recoveryStage = .waitingForBluetooth
    #expect(state.summary == "等待蓝牙开启")
    state.phase = .failed
    state.recoveryStage = .failed
    #expect(state.summary == "未连接" && state.status(for: device.id) == "未连接")
    state.phase = .idle
    state.recoveryStage = .idle
    state.availability = .available
    #expect(state.summary == "未连接" && state.canScan)
}

@Test @MainActor
func bluetoothDetailEntryRequiresMatchingConnectedDevice() {
    let state = BluetoothSettingsState()
    let device = BluetoothDeviceRow(id: UUID().uuidString, name: "Remembered arm")
    state.remembered = device
    #expect(!state.isConnected(device.id) && state.canConnect)
    #expect(state.rowIntent(for: device.id) == .connect)
    state.selected = device
    state.phase = .connecting
    #expect(!state.isConnected(device.id) && !state.canConnect)
    #expect(state.rowIntent(for: device.id) == .unavailable)
    state.phase = .connected
    #expect(state.isConnected(device.id) && !state.canConnect)
    #expect(state.rowIntent(for: device.id) == .openDetail)
    #expect(!state.isConnected(UUID().uuidString))
    #expect(state.rowIntent(for: UUID().uuidString) == .unavailable)
    state.phase = .disconnecting
    #expect(!state.isConnected(device.id) && !state.canConnect)
    state.phase = .idle
    #expect(!state.isConnected(device.id) && state.canConnect)
    #expect(state.rowIntent(for: device.id) == .connect)
}

@Test @MainActor
func bluetoothDeviceRowRejectsUnavailableRadioAndBusyRecovery() {
    let state = BluetoothSettingsState()
    for availability: BluetoothAvailability in [.poweredOff, .denied, .unsupported] {
        state.availability = availability
        #expect(!state.canConnect)
    }
    state.availability = .available
    for stage: BluetoothRecoveryStage in [.cleaning, .waiting, .connecting] {
        state.recoveryStage = stage
        #expect(!state.canConnect)
    }
    state.recoveryStage = .failed
    state.phase = .failed
    #expect(state.canConnect)
}

@Test @MainActor
func bluetoothDeviceGroupsKeepUnsuccessfulSelectionsOutOfMyDevices() {
    let state = BluetoothSettingsState()
    let saved = BluetoothDeviceRow(id: UUID().uuidString, name: "Saved arm")
    let candidate = BluetoothDeviceRow(id: UUID().uuidString, name: "Nearby arm")
    state.remembered = saved
    state.selected = candidate
    state.phase = .connecting
    // Connection clears discovery; its current row must remain visible without becoming remembered.
    #expect(state.myDevice == saved)
    #expect(state.otherDevices == [candidate])
    state.nearby = [saved, candidate]
    #expect(state.otherDevices == [candidate])
    state.phase = .failed
    state.error = "Nearby connection failed"
    #expect(state.myDevice == saved && state.otherDevices == [candidate])
    #expect(state.currentMessage(for: saved.id) == nil)
    #expect(state.currentMessage(for: candidate.id) == "Nearby connection failed")
    #expect(state.rowIntent(for: candidate.id) == .connect)
    state.phase = .connected
    #expect(state.myDevice == candidate)  // Native connection is shown even before persistence catches up.
    state.remembered = candidate
    #expect(state.myDevice == candidate)
    #expect(!state.otherDevices.contains { $0.id == candidate.id })
    state.phase = .idle
    #expect(state.myDevice == candidate && state.rowIntent(for: candidate.id) == .connect)
    state.remembered = nil
    state.selected = nil
    #expect(state.myDevice == nil)
}

@Test @MainActor
func bluetoothConnectedWarningUsesOnlyCurrentNativeIssue() {
    let state = BluetoothSettingsState()
    let device = BluetoothDeviceRow(id: UUID().uuidString, name: "Requested arm")
    state.selected = device
    state.phase = .connected
    state.error = "Old execution error"
    #expect(!state.hasConnectionIssue(device.id))
    #expect(state.currentMessage(for: device.id) == nil)
    let nativeIssue = "发送设备指令失败（CBErrorDomain 7）"
    state.transportIssue = nativeIssue
    #expect(state.status(for: device.id) == "已连接，异常")
    #expect(state.hasConnectionIssue(device.id))
    #expect(state.currentMessage(for: device.id) == nativeIssue)
    #expect(!state.hasConnectionIssue(UUID().uuidString))
    #expect(state.currentMessage(for: UUID().uuidString) == nil)
    state.transportIssue = nil
    #expect(state.status(for: device.id) == "已连接")
    #expect(!state.hasConnectionIssue(device.id))
    #expect(state.currentMessage(for: device.id) == nil)
}

@Test @MainActor
func bluetoothOpenDetailDisablesAllMotorAdmissionAfterDisconnect() {
    let state = BluetoothSettingsState()
    let device = BluetoothDeviceRow(id: UUID().uuidString, name: "Nex_Arm")
    state.selected = device
    state.phase = .connected
    #expect(state.canControl(device.id))
    state.transportIssue = "暂未收到新的机械臂位置反馈"
    #expect(state.status(for: device.id) == "已连接，异常")
    #expect(state.canControl(device.id))
    state.phase = .disconnecting
    #expect(!state.canControl(device.id))
    state.phase = .idle
    #expect(state.status(for: device.id) == "未连接")
    #expect(!state.canControl(device.id))
    #expect(!state.canControl(UUID().uuidString))
}

@Test @MainActor
func bluetoothCurrentStateDoesNotBorrowAnotherDevicesRecoveryOrRetainIdleError() {
    let state = BluetoothSettingsState()
    let old = BluetoothDeviceRow(id: UUID().uuidString, name: "Old arm")
    let current = BluetoothDeviceRow(id: UUID().uuidString, name: "Current arm")
    state.selected = current
    state.recoveryDeviceID = old.id
    state.phase = .connected
    #expect(state.status(for: old.id) == "未连接")
    #expect(state.status(for: current.id) == "已连接")
    state.error = "Previous connection failure"
    state.phase = .idle
    state.recoveryStage = .idle
    #expect(state.currentMessage(for: current.id) == nil)
    #expect(!state.canControl(current.id))
}
