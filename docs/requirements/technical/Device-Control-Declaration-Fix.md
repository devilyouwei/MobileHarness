# Device.control 声明与可信 UI 调用一致性修复

2026-10-27。

## 问题与计划

ActionFunction 统一按声明校验参数后，DeviceActions.control 声明仅包含 operation/id，却在实现与 ApplicationControl InternalTool 中支持 value/action/fence 和更多 UI 操作。手机连接、忽略等携带 fence 的调用在到达设备能力前报 invalidKeys；preset/openPage 等还可能因枚举不完整失败。

修改 Actions/System/Device/DeviceActions.swift 的声明，使其覆盖现有端口全部操作与字段，不放宽统一校验，不改变模块边界、设备操作或物理完成语义。Skill 的参数投影同步采用完整声明；fence 仍须通过业务 UUID 与设备当前会话校验。FunctionTokenParserTests 的 XML 用例应保留已声明 fence，继续丢弃真正未知字段。更新 Device 与 System README，IntegrationTests/ActionContractTests.swift 覆盖真实生成声明的 connect/forget fence、全部可信操作，以及未知键和非法操作拒绝。InteractionPipelineTests 经真实 Agent/Gateway/Actions 路径覆盖携带 fence 的 connect/forget。执行 scripts/check.sh 与 scripts/build-ios.sh，结果记录在本文件。

## 验收

代码与当前设计文档已同步。手机连接/忽略尚未在更新后的 App 上复验，自动化检查不代表 BLE 验收，后续已按用户要求原位安装并启动 iPhone 17 Pro 版本2026102701，见 [安装证据](../../validation/Validation-History.md#2026-10-27--devicecontrol-参数声明修复版真机安装)。真实连接／忽略操作仍待现场复验。

## 2026-10-27 验证证据

- 原因定位：0fb86445 引入 ActionFunction.validateInput 的声明级参数/枚举校验；BluetoothInteractionWorkflow.submit 会给连接、忽略等操作添加 fence，旧 DeviceActions.control 声明没有该字段。错误发生在实际设备调用前。
- scripts/check.sh 已执行：边界检查、6 项 Python 测试、格式检查与 plist 检查通过；876 项普通集成测试首轮仅旧 XML 断言失败，原因是 fence 现在已正式声明；221 项 LiveRuntime/NativePresentation 测试通过。首轮完整脚本退出 1，不宣称整轮通过。
- 更新 XML 断言并补完完整链路测试后，专项复跑 3/3 通过：deviceControlDeclarationAdmitsTrustedUIOperationsAndRejectsUnknownInputs、xmlActionsDiscardUndeclaredParametersBeforeAuthorization、deviceContainerRequestsUseRegisteredFunctionsAndRecover。未再次复跑全套普通测试。
- scripts/build-ios.sh 退出 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个 Simulator scheme 均 BUILD SUCCEEDED。
- git diff --check 通过。日志在本机临时路径 /tmp/mobileharness-device-contract-{check,build,regression}.log。
- 设备端口采用测试替身；测试未向真实机械臂发送动作。剩余为更新手机版本后的真实连接／忽略操作验收。
