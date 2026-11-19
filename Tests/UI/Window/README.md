# Window tests

呈现状态与原生入口中本目录能力的测试。测试通过真实接口及显式替身验证可观察行为、失败、取消和清理；真实模型及设备用例保留显式 gate。

## 文件归属

- [WebPageTests.swift](WebPageTests.swift)
- [WebSimulatorAcceptance.swift](WebSimulatorAcceptance.swift)
- [WindowStateTests.swift](WindowStateTests.swift)
- [WriterRecordsUITests.swift](WriterRecordsUITests.swift)

## 测试分层与入口

| 文件 | 层级 | 边界与入口 |
| --- | --- | --- |
| WindowStateTests | Unit Tests | 几何、身份、模式和回执；注入呈现完成，不检查真实动画。 |
| WebPageTests | Unit Tests / Integration Tests | URL 策略与实际 macOS WebKit 页面/像素/预览行为。 |
| WebSimulatorAcceptance | Integration Tests | 条件编译的 iOS 原生组件宿主，由 scripts/simulator/test-webkit-simulator.sh 调用。 |
| WriterRecordsUITests | UI Tests | XCTest/XCUIAutomation 操作实际 App；由 scripts/simulator/test-writer-records-simulator.sh 编译运行，保留 WRITER_UI_ACCEPTANCE gate 和两个原用例。 |

UI 状态测试、WebKit 组件集成和实际 App 点击分别报告，不互相作为执行证据。
