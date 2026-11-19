# Gateway tests

输入广播、调度、资源与结果/媒体传输。实际执行端口和受控函数/资源构成集成边界，参数附件与局部策略可独立验证。

Input：原生输入流与代际；Output：Channel/wait、容器端口、媒体和窗口路由。

## 测试分层

采用 [Tests 的统一分层](../README.md#测试分层)。混合行表示文件中同时存在独立逻辑单元与真实组件协作；按实际用例边界判断，不按 target 命名判断。

| 能力目录 | 层级 | 文件或用例组 |
| --- | --- | --- |
| Input | Unit Tests / Integration Tests | [DeviceInputTests](Input/DeviceInputTests.swift) |
| Output | Integration Tests | [ChannelSchedulerTests](Output/ChannelSchedulerTests.swift)、[GatewayContainerTests](Output/GatewayContainerTests.swift) |
| Output | Unit Tests / Integration Tests | [MediaTransportTests](Output/MediaTransportTests.swift)、[WindowGatewayTests](Output/WindowGatewayTests.swift) |
| Output | Unit Tests | [NativeAttachmentTests](Output/NativeAttachmentTests.swift) |

## 执行与替身边界

默认执行 `./scripts/check.sh`；实际期限与原生窗口回归由既有串行阶段隔离。模型/网络/设备开关与原生独立入口见 所属能力 README 和 [执行总索引](../README.md#执行入口)。每次运行单独记录通过、失败与跳过，不将替身结果标成原生验收。

## 能力文档

- [Input](Input/README.md)
- [Output](Output/README.md)
