# ADR 0018 · Agent 内双协议解析与 Channel 调度

> Scheduling update: [ADR 0059](0059-structured-wait-scheduling.md) supersedes shared cross-task Channel lanes and introduces typed nested wait groups. This document retains its historical decision context; Channel ownership/takeover remains planned.

日期：2026-09-24。状态：采用。目标依据 MobileHarness/README.md 第 6–24、27、37 节。

## 决策

AgentCore 迁至根层协议、Capability、Generation、Output、Runtime。Agents/Assistant 使用共享 AgentGenerator，能力注册由每个 Agent 持有不可变快照。FunctionToken 是 Agent 内部的 text/action/boundary 解析事件；边界向外仅传已解析 ActionCall 或 ToolCall，另暂保留原 runtime control 完成/错误通知。

FunctionTokenParser 增量解析 UTF-8 字节。动作只能自闭；Channel 成对，可嵌套，闭合恢复外层或动作默认 Channel。自然文本按 Agent 指定的动作别名映射，Assistant 默认 say + print。Channel 边界冲刷旧文本；已转义文本不二次解释。工具结果和演示文本转义后走纯文本映射，不能将返回内容直接执行为 XML。

ToolCallParser 独立处理完整模型原生 tool alias/JSON 字符串参数，保留 ID，解析到明确 toolPath；ToolRuntime 不解析别名、不经 Channel。当前 ChatCapability 没有原生 tool 增量事件，模型适配接入标记为未完成；现有 /status 工具回路保持可用。

## 执行与兼容

Gateway 移除局部别名解析；OutputValidator 检查已解析路径、参数和 Channel 白名单。原 ActionRuntime/ActionExecutor 迁至 Gateway/Output/Scheduling/ChannelScheduler，以有效 Channel 排队。默认 Speech/Display 保持原有业务行为；main 支持跨模块串行。模块仍是最小设备资源互斥范围，防止不同 Channel 重叠占用扬声器。就绪队首按接纳序竞争资源，不承诺全局跨 Channel 执行顺序。

保持 input/session/source/callID 关联、普通语音分句、取消/完成屏障、工具回流和默认模型选择。每 Channel 32 项、16 个活动 Channel、64 个输入跟踪；Manager 最多注册 64 个 Agent。所有上限明确拒绝，不丢弃设备动作。

## 失败规则与限制

单轮解析最多 65536 字节、单标签 4096 字节、1024 标签、8 层 Channel；解释器最多 120 个动作、2000 字节分句缓冲。未知能力、参数不符、非法 XML/UTF-8、错配/截断和超限终止本轮；失败 parser 不复用。已流出的动作不可回滚，失败通过 runtime 通知取消剩余动作；append 抛错不返回该次局部结果，不承诺错误输入分片方式不影响已发出前缀。

保留 AgentInput，统一 Signal、StateStore、通用 AgentRuntime、InternalSignalBus、restart/健康监督后续实施。ActionCall 当前无独立对外 invocation ID/幂等语义；调度内部任务有 UUID。control 后续迁成独立强类型运行事件。原生工具完整 JSON Schema/增量参数、Channel 抢占/优先级/多资源依赖及标准 ActionResult 均未实现。

## 文档与测试

每个已建立的 Agent 层目录有用途、设计目标、✅/❌ README。Generation、Capability、Runtime、Channel 调度与工具模块提供 Mermaid 图。未建立空 State、Bus 或重复职责的 ChannelParser/GhostShellScheduler 文件。

测试覆盖每个 UTF-8 字节分片和逐字节输入、嵌套/退出恢复、动作在 Channel 闭合前流出、转义、非法标签/实体/UTF-8、截断、容量、Agent 局部绑定、工具 ID/参数、完整 Assistant 流、工具结果不执行标签、跨模块同 Channel 串行、同资源跨 Channel 互斥，以及既有取消和语音回归。真机模型遵循新增 XML 指令的质量、连续麦克风/音质仍需设备验收。

## 验证结果

- ✅ 最终 `scripts/check.sh` 通过：格式、Swift 测试（包含 46 项集成测试及参数化非法输入案例）、配置校验。
- ✅ `scripts/build-ios.sh` 五个模拟器 scheme 构建通过；最后的数字实体语法收紧另经完整 check 和真机编译覆盖。
- ✅ MobileHarness 真机目标 Debug 无签名构建通过。
- ✅ AgentCore/Agents/Gateway/Actions 的实际目录 README 覆盖、工程引用唯一性与无悬空路径核对通过。
- ❌ 默认跳过的 5 项真实模型/系统音频测试未执行，未安装真机或进行实际麦克风/连续语音/模型 XML 遵循质量验收。

使用 DEVELOPER_DIR 指向完整 Xcode，未改变全局开发工具选择或签名配置。ToolRuntime/PlatformKit 既有 README 未排除警告保留；不影响编译与测试结果。
