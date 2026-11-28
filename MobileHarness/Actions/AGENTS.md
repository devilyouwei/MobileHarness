# Actions 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)、[模块设计](README.md)和受影响能力的 README。

## 职责归属

| 位置 | 开发职责 |
| --- | --- |
| 模块根、[Composition](Composition/) | 唯一执行根、明确的函数装配、域服务构造及公开端口。 |
| [Support](Support/README.md) | 中立函数契约、调用适配、Shell 调度、资源准入和结果账本。 |
| [Camera](Camera/README.md)、[Speech](Speech/README.md) | 相机事务、媒体处置、语音播放、聆听和诊断执行。 |
| [NexArm](NexArm/README.md)、[System](System/README.md) | 设备动作与执行回执、连接业务、模型资源和 Provider 操作。 |
| [UI](UI/README.md)、[Web](Web/README.md) | 展示和导航请求适配、网页交互、读取与截图。 |
| [History](History/README.md)、[Artifacts](Artifacts/README.md) | 历史查询和更新、作品工作区与文件操作。 |
| [Resources](Resources/README.md) | 随 Actions 打包的函数说明本地化。 |

## 开发边界

- 将业务函数放在拥有实际副作用的能力目录。入口通过已有的 Module 和 [CapabilityModules](CapabilityModules.swift) 明确装配。域、Module 和函数共享执行根。禁止为单个函数增加容器、应用生命周期节点或服务定位器。
- 通过注入的公开能力执行操作。禁止导入 Agents、AgentCore、Gateway 或 App，禁止在处理器中解释角色权限、Skill、Task 或组装通信消息。保持 FunctionContracts、ExecutionRuntime、CallRuntime 的独立目标边界。
- 同一业务函数使用统一的 `@Action` 声明并支持 `ActionCall` 与 `ToolCall`。禁止在宏、模块装配、注册或处理器中按函数限制调用协议，或根据协议改变业务结果。Tool 回执策略只控制结果交付。
- 调用方选择调用方式。ActionCall 由 Shell 按调用方提供的 Channel 与 wait 调度。ToolCall 通过准入后直接执行，默认可重叠。需要串行的调用方等前一个 Tool 完成再提交下一个。两条路径均遵守共享资源准入、容量和取消清理契约。不要用全局队列或处理器内的协议分支模拟调用方排序。
- Skill 由 Agents 授权、注册和教学。灵动岛由 Agent 的固定内部 Tool 权限驱动。禁止在 Skill 的 `useActions` 或提示词加入灵动岛调用，也不要用 Actions 装配替代角色授权。
- 在 `@Action` 声明中写清参数、资源、预算、完成时点。前置解码保持纯校验，禁止先做 I/O、修改状态或取得资源。执行时复核有效许可和当前业务条件。状态读取已持有的事实，禁止隐式构造服务或启动设备。
- 明确成功代表接纳、已提交、已完成还是资源已清理。仅在有业务数据时返回值，失败保留真实异常和已完成的副作用。处理器等待自身启动的有限工作或清理完成。区分 `callID`、`executionID` 和 `roundID`，用原身份关联回执。

## Action 开发模板

1. 在所属能力定义 `@Action` 和类型化处理器。用 `FunctionInput` 接收调用，先纯解码，再通过注入端口执行。声明固定预算或使用现有动态预算入口。使用资源的操作声明资源并验证运行时许可。宏展开与纯前置校验见[宏技术设计](../../Macros/BehaviorDefinitions/README.md)。
2. 在所属 `CapabilityModule` 的 definitions 中绑定生成的工厂。效果型函数用 `handler:`，返回业务结果的函数用 `completing:` 并返回真实的 `ActionCompletion`。同步函数本地化和拥有目录的技术说明。
3. 在对应 [Actions 测试](../../Tests/Actions/README.md)验证无效参数无副作用、实际结果、取消后清理和必要的资源冲突。调用顺序变更用 [Shell 的实际入口](Support/Shell/README.md)验证。实例暂停、恢复或取消沿用[执行生命周期契约](../../docs/requirements/technical/Action-Execution-Lifecycle.md#action-实例生命周期与控制)。

### 示例

以现有 `UI.Expression.setExpression` 为例，[ExpressionActions](UI/Expression/ExpressionActions.swift) 先验证 emotion，再提交状态。[UIModule](UI/UIModule.swift) 的绑定将已注入的呈现端口交给处理器。

```swift
UIActions.setExpressionDefinition(handler: { [expression] invocation in
    try await UIActions.setExpression(invocation: invocation) {
        try await expression.setExpression($0, invocation: $1)
    }
})
```

该函数的完成点是基础表情状态已提交。按这个时点编写断言。
