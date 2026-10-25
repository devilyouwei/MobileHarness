# Container architecture follow-ups

This document tracks inherited limitations and subsequently identified implementation gaps. The inherited items were moved from current implementation READMEs under the repository documentation policy. Historical passing tests do not establish untested policy semantics or native/model/device acceptance.

### MobileHarness/Agents/Assistant/README.md

## 待实现

❌ 场景挂起期间前台目标及最终 checkpoint 的完整落盘；公共限制见 [Chat](../../../MobileHarness/Agents/Support/Chat/README.md)。

### MobileHarness/Agents/Memory/README.md

## 待实现

❌ 语义记忆与活跃历史事务的持久化恢复。

### MobileHarness/Agents/VisionPerception/README.md

## 待实现

❌ 身份跟踪、独立深度／人脸模型和热反馈。

- ❌ barge-in 与后台聆听未实现。
- ❌ 活跃 worker 持久化恢复、跨进程运行状态共享和 Skill 驱动动态 Context 订阅未实现。只读来源见本目录 AgentStateContext，模型流程见 [Chat](../../../MobileHarness/Agents/Support/Chat/README.md)。
### MobileHarness/Agents/Support/Core/README.md

## 待实现

❌ 通用 factory、自动重启、远程传输和持久化执行递送。

- ❌ 完整 JSON Schema 和配置热更新未实现。解析见 [Generation](../../../MobileHarness/Agents/Support/Core/Generation/README.md)，消息声明见 [Communication](../../../MobileHarness/Agents/Support/Core/Communication/README.md)。
- ❌ 通用 factory、自动重启和健康监督未实现。局部媒体见 [Input](../../../MobileHarness/Agents/Support/Core/Input/README.md)，真实结果见 [Output](../../../MobileHarness/Agents/Support/Core/Output/README.md)。
- ❌ 持久化执行递送与 control(String) 的完整类型化未实现。轮次协调见 [Runtime](../../../MobileHarness/Agents/Support/Core/Runtime/README.md)。
- 停止和显式取消决定生命周期，重启标 interrupted，不重放设备效果。❌ 远程序列化和持久化投递未实现。业务契约见 [Agents/Communication](../../../MobileHarness/Agents/Support/Communication/README.md)。
- ❌ 自动语法修复和计时 flush 未实现。上层流程见 [Chat](../../../MobileHarness/Agents/Support/Chat/README.md)，配置与目录见 [Capability](../../../MobileHarness/Agents/Support/Core/Capability/README.md)。
- ❌ 暂停／中断时 Task 状态投影与 per-input 提交的统一最终 flush、活跃 worker 的持久化恢复与跨进程传输。各提交边界独立传播错误，不提供统一 checkpoint。
- ❌ 更多 Agent 记录 schema、历史页面重设计、交互返回／滚动保持、目录点按、分享接收端及蓝牙物理行为仍需单独验收，自动化状态测试不代替真机。

## Execution policy routing (identified by the overall README audit)

ActionExecutionDescriptor carries executionPolicy, and binding validation preserves it. Production OutputGateway currently routes ActionCall through ChannelScheduler and ToolCall through DirectExecutionDispatcher. Dispatchers do not branch on executionPolicy. A direct declaration therefore does not currently bypass Channel/wait for an ActionCall.

Corrective follow-up: verify and restore the intended protocol-independent execution-policy semantics against the pre-migration contract, with explicit Channel/wait, resource, result and round-barrier behavior for both call protocols. Cover the same function submitted through Action and Tool views under declared direct/scheduled policies, then reconcile all current contracts. Current documentation describes the existing protocol-specific route; this audit does not change runtime behavior.
