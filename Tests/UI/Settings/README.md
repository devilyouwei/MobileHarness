# Settings tests

呈现状态与原生入口中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [AudioDetectionStateTests.swift](AudioDetectionStateTests.swift)
- [BluetoothConnectionStateTests.swift](BluetoothConnectionStateTests.swift)
- [SettingsStateTests.swift](SettingsStateTests.swift)

## Unit Tests

上述文件直接验证 UI 状态，不操作实际 App。BluetoothConnectionStateTests 同时验证活动中手动控件保持可用、断连/恢复阶段拒绝控制；无需 Action Catalog、蓝牙 link 或设备连接。原生点击属于独立 UI Tests。
