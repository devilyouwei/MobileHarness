# Agent 静态类别

日期：2026-11-10。用户确认将所有 Agent 分为 perception 与 cognition，Memory 暂归 cognition。

## 设计与范围

- 在现有 `MobileHarness/Agents/Support/Core/AgentDescriptor.swift` 内定义 `AgentCategory: String, Codable, Sendable`，只有 perception/cognition；Descriptor 持有必填不可变 category，不提供默认类别。
- 每个 `Resources/Agents/<角色>/Agent.json` 显式声明 category，作为生产角色唯一来源。资源 schema 从 v9 升为 v10；`Support/AgentConfigurations.swift` 严格校验必填字段、值与类型，投影到携带 category 的 AgentCore v8 配置（原 v7）。旧版本、缺失/null/未知类别明确拒绝。同步 scripts/check-modelkit-boundaries.py 的资源版本及类别合法性校验，保持静态检查与加载器一致。
- `AgentConfiguration` 保存类别，restrictingCommunication 保留原值。七个生产角色从配置构造 Descriptor；OutputGateway 在收窄有效能力时保留该身份属性。纯函数目录的内部临时配置显式填写类别，仅用于 schema 编译，不产生 Agent 身份或分类策略。
- cognition：Assistant、Writer、Memory。perception：SpeechPerception、VisionPerception、Photographer、ApplicationControl。后两者按当前快速响应和确定性执行职责分类；类别不等于是否调用模型。
- 本轮只增加静态声明与读取，不改变权限、队列、模型请求、持久化消息或 UI，也不增加目录、依赖或运行任务。无需新增取消和清理机制。

## 文档与验证

同步 AgentCore 根/Capability、Support、Agents、Resources/Agents 和总体设计；角色 README 链接统一分类契约，避免重复名单。测试覆盖完整角色映射、配置至运行时投影、通信收窄保留类别、缺失/错误类别及旧版本拒绝，并更新受必填初始化参数影响的测试替身。

运行 `./scripts/check.sh`、`./scripts/build-ios.sh`；区分静态分类回归、构建与未执行的实模/设备验收。通过后整份计划归档，证据另记 docs/validation。

## 验证中发现的测试同步修正

完整回归发现 ProviderDiscoveryTests 的取消替身在调用 caller.cancel 后立即释放，而 UIRequests 通过异步主线程任务转发取消；替身可能先正常返回。仅调整该测试的 HeldDiscovery，使用有界信号确认底层 cancellation handler 被调用后再释放，并给用例增加时间上限，不修改生产取消逻辑或分类策略。跟踪目标时序失败单独复跑后通过，保留原失败记录。

## 状态

2026-11-10：分类声明、配置迁移、运行时保留、文档及回归均完成；完整检查与四个 iOS 模拟器目标构建通过。需求整份归档，过程失败与验收边界见[验证记录](../validation/Agent-Categories.md)。
