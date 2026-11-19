# Output tests

输入输出路由中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [GatewayContainerTests.swift](GatewayContainerTests.swift)
- [MediaTransportTests.swift](MediaTransportTests.swift)
- [NativeAttachmentTests.swift](NativeAttachmentTests.swift)
- [WindowGatewayTests.swift](WindowGatewayTests.swift)

[ChannelSchedulerTests.swift](ChannelSchedulerTests.swift) 验证同 Channel 顺序、跨 Channel 并行、wait、容量、资源竞争和取消 join。被测 ChannelScheduler 属于 Gateway，文件不再归 Actions。
