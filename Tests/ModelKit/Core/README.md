# ModelKit contract tests

Purpose: verify independent capability contracts and bounded inference sessions. Design goals: deterministic fixtures, explicit failure/cancellation and no business dependencies.

SessionTests cover ordered completion, single consumers, explicit synchronous overflow, suspending emission with capacity one and cancellation of a blocked producer. Capability/media/resource tests verify validated independent SDK contracts.

Unbounded sessions retain 20,001 ordered events before consumption, including suspending yield; size validation and cancellation still apply. Existing bounded overflow tests remain.

## Message contracts

CapabilityTests 验证有界消息、媒体、原生函数声明和 call/result 配对的中立值契约。Provider 编码由各适配器测试覆盖；业务 ReACT 与 Task 生命周期由 IntegrationTests 覆盖。

## ModelKit Support ownership

Five deterministic InferenceTaskControl regressions cover cancel-before-install, installed cancellation/isolation, finish-before-install, finish cleanup and duplicate worker rejection. Owners join all fixture workers; no timing sleeps or real models are required.

CoreBoundaryTests cover opaque scope propagation, invalid injected limits, global load admission, waiter rejection, explicit retry and residency without importing Management.


## 文件归属

- [CapabilityTests.swift](CapabilityTests.swift)
- [CoreBoundaryTests.swift](CoreBoundaryTests.swift)
- [InferenceTaskControlTests.swift](InferenceTaskControlTests.swift)
- [MultiDecisionTests.swift](MultiDecisionTests.swift)
- [SessionTests.swift](SessionTests.swift)

## 契约覆盖

模型回归覆盖 App 同根四子能力／根隔离、流式错误观察者早／晚安装及取消无故障；资源暂停取消加入与权重保留由 Runtime 测试覆盖，默认根生命周期由 Defaults 测试覆盖。

Session coverage includes a one-event queue without a single-event byte ceiling, large payload preservation and suspended-producer progress after consumption.

[DecisionWeightArchiveTests.swift](DecisionWeightArchiveTests.swift) 验证 CoreAI 权重标量读取、tensor shape 与越界拒绝。

## 测试层级

能力、会话、取消控制与多问题策略使用确定性 Unit Tests；DecisionWeightArchiveTests 通过临时 safetensors 验证真实 CoreAI 张量读取，属于 Integration Tests。受限系统使用 @available 报告跳过，缺少 CoreAI 的编译环境明确记录失败，不能无断言通过。
