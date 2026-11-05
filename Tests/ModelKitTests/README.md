# ModelKit contract tests

Purpose: verify independent capability contracts and bounded inference sessions. Design goals: deterministic fixtures, explicit failure/cancellation and no business dependencies.

SessionTests cover ordered completion, single consumers, explicit synchronous overflow, suspending emission with capacity one and cancellation of a blocked producer. Capability/media/resource tests verify validated independent SDK contracts.

Unbounded sessions retain 20,001 ordered events before consumption, including suspending yield; size validation and cancellation still apply. Existing bounded overflow tests remain.

## Message contracts

CapabilityTests 验证有界消息、媒体、原生函数声明和 call/result 配对的中立值契约。Provider 编码由各适配器测试覆盖；业务 ReACT 与 Task 生命周期由 IntegrationTests 覆盖。

## ModelKit Support ownership

Five deterministic InferenceTaskControl regressions cover cancel-before-install, installed cancellation/isolation, finish-before-install, finish cleanup and duplicate worker rejection. Owners join all fixture workers; no timing sleeps or real models are required.

CoreBoundaryTests cover opaque scope propagation, invalid injected limits, global load admission, waiter rejection, explicit retry and residency without importing Management.

## 待实现

- Real-model quality, latency and hardware behavior belong to adapter/device acceptance.

✅ 模型回归覆盖 App 同根四子能力／根隔离、流式错误观察者早／晚安装及取消无故障；资源暂停取消加入与权重保留由 Runtime 测试覆盖，默认根生命周期由 Defaults 测试覆盖。

Session coverage includes a one-event queue without a single-event byte ceiling, large payload preservation and suspended-producer progress after consumption.
