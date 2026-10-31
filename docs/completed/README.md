# 已完成需求归档

本目录集中保存原定范围已经全部完成的需求与实施计划。归档的是一次明确的交付范围，后续独立 bug 修复或 feature 扩展不影响原需求的完成状态。当前实现以源码 README 为准，归档文档保留当时的目标、决策和实施记录。

## 归档规则

1. 核对原范围的功能、接口、迁移、清理和明确约定的必要验收；仍有原定交付缺项时不能归档，也不能将其改称后续扩展。
2. 部分完成的需求整份保留在 requirements，更新子项状态；只有原范围全部完成后才整份迁入本目录，不按已完成章节提前归档。
3. 归档记录日期、完成范围及验证来源，更新所有引用，不保留两份相同的活动需求。
4. 后续修复与扩展使用独立记录；归档中的历史失败、构建限制和另行跟踪的模型/设备验收保持真实，不因归档改写为通过。若某项验收本身属于原需求完成条件，则完成前不能归档。
5. ADR、验证报告、原始设计源和通用变更历史按各自目录职责保存；文件中出现“完成”不代表它就是需求文档。

## 本次归档

整理日期：2026-10-15。以下归档范围均已有实施完成记录；归档日期不代替实际实现或验证日期。

| 文档 | 已完成的原范围 |
| --- | --- |
| [Action 文档与流程 Skills](Action-Documentation-Skills-Plan.md) | Action 声明替代重复元数据，模块自动投影，以及流程教学迁入 Skills。 |
| [Tasks 与独立 Skills 迁移](Agents-Skills-Task-Modes-Plan.md) | 通用 Task、独立 Skill 机制及其 Assistant、历史和 UI 迁移。生产后台业务与物理体验不属于该机制迁移的新增交付。 |
| [ModelKit Support 重组](ModelKit-Support-Plan.md) | 源码职责与编译边界重组、重复模块清理及调用迁移。 |
| [ModelKit 解耦审计](ModelKit-Decoupling-Audit.md) | 中性 Core 契约、SDK 依赖隔离、完整源码审计和当前设计文档对齐。 |
| [SQLite 业务记录迁移](Prefix-Numeric-ID-Plan.md) | 业务 ID、逐消息持久化、索引查询和媒体文件命名/提交迁移。 |
| [Storage 仓库与后端分离](Storage-Repository-Plan.md) | 独立领域契约、File/Memory/SQLite 后端及调用迁移。其后新增的自动历史分页属于独立页面扩展，不改变原接口分离的完成状态。 |

各文档中的测试失败、模拟器依赖限制和独立真机验收状态原样保留，具体以其验证记录为准。

## 仍未整体完成

[四项核心架构改进](../requirements/technical/Core-Architecture-Improvement-Plan.md) 只有存储接口子项完成；状态转换、全局错误处理和 App 解耦仍待实施，整份继续留在 requirements。相册与记忆、Resource 状态接入、摄影构图与运镜也继续留在各自待办分类。

[未完成需求](../requirements/README.md) · [文档总索引](../README.md) · [验证记录](../validation/Validation-History.md)

## 业务组织整理（2026-10-23）

- [Actions 业务组织与端点解耦](Actions-Organization.md)：业务目录归位、共享 Support、显式端点及生命周期所有权。
- [Agents 角色归属与共享机制](Agents-Organization.md)：根级装配、角色私有协议与通用机制分离，以及职责一致的文件组织。

原定整理范围与完整自动检查已完成；模拟器构建使用隔离项目元数据读取同一工作区源码。原工程文件协调阻塞、修正过程及未进行的真实模型／设备验收见[验证记录](../validation/Agents-Actions-Organization.md)。

## Actions execution ownership (2026-10-25)

- [Actions container and one-way execution](Actions-Container.md): one App-owned Actions root, composable business library, neutral Gateway preparation/scheduling and Agent-owned authorization. Required repository checks and all four Simulator builds passed; retained failure iterations and native/model/device evidence limits are in [validation](../validation/Actions-Container.md).

## Execution layer cleanup (2026-10-25)

- [Execution layer source ownership audit](Execution-Layers-Cleanup.md): consolidate six net Swift files, remove unused adapters/helpers, reconcile physical and Xcode ownership, and correct stale cognitive authorization diagrams. Full repository checks and all four Simulator schemes passed; [validation evidence](../validation/Execution-Layers-Cleanup.md) distinguishes build/test results from model/device acceptance.

- [Platform system facts](Platform-System-State.md): eight passive native sources and BasicSkill context, implemented with required checks/builds; independent native acceptance limits remain explicit.

- [Current State before redundant queries](Current-State-First.md): BasicSkill direct answers, precise environment-query scope and unchanged instruction budgets; [validation](../validation/Current-State-First.md) separates automated/build checks from real LLM adherence.

## State summaries and detail queries (2026-10-26)

- [State and query responsibilities](State-And-Query-Responsibilities.md): agents.application summary, removal of the generic environment Action/reverse binding, preserved specific queries and correlated feedback, with [automated/build evidence](../validation/State-And-Query-Responsibilities.md).

[NexArm 位置跟踪恢复](NexArm-Position-Tracking-Restore.md)：恢复有限角度目标，删除持续速度及取消恢复写入，收紧USB/BLE原始寄存器写校验。代码和自动化验证完成，实机边界见归档记录。

2026-10-27：[NexArm 位置跟随平滑](NexArm-Smooth-Position-Tracking.md) 已完成位置目标 20 Hz 更新、时间滤波、最新目标派发和 PlatformKit 设备约束归属，自动检查与 iOS 构建通过；未安装或验证机械臂实物。

2026-10-27：[NexArm 通用设备反馈与连接错误归属](NexArm-Device-Feedback-Ownership.md) 完成SDK容差、位置观察、行程估算及原生恢复预算/分类迁移；全量自动检查和四项iOS构建通过，未安装或实物测试。

- [NexArm motor teaching and regression](NexArm-Robot-Skill-Teaching.md): relative motor requests, unit/axis teaching and three-model experiments with retained failure evidence.

- [Explicit execution composition](Explicit-Execution-Composition.md): App-sequenced preparation and module-owned configuration; automated checks and simulator build passed.
