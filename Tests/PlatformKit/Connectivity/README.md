# Connectivity tests

## Unit Tests

[NexArmBluetoothTests.swift](NexArmBluetoothTests.swift) 独立验证 PlatformKit 的 BLE 回复重组/ACK、写入能力与确认窗口、连接级流量预算、原生背压和通知计数。直接构造协议/预算值，不安装 Action Catalog，不创建 CoreBluetooth manager。

## Integration Tests

连接业务、运动规划及 Agent/Gateway/Actions 的工作流由发起能力拥有，见 [NexArmBluetoothIntegrationTests](../../Actions/NexArm/NexArmBluetoothIntegrationTests.swift)。Actions 的独立规划/连接策略见 [NexArmConnectionPolicyTests](../../Actions/NexArm/NexArmConnectionPolicyTests.swift)，UI 控件状态见 [BluetoothConnectionStateTests](../../UI/Settings/BluetoothConnectionStateTests.swift)。这些默认回归使用显式蓝牙替身，不代表真实无线/机械臂验收。
