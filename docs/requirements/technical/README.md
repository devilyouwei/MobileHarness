# 技术需求

[原生音视频故障诊断](Native-Media-Failure-Diagnosis.md)：空间音频错误保真、原生通知回归及媒体服务重置的设备调查。

本目录收录原范围尚未全部完成的架构、接口和运行机制需求。用户场景为主的需求归 [产品需求](../product/README.md)，无法独立拆分的交叉需求归 [requirements 根目录](../README.md#技术与产品交叉需求)。

| 需求文档 | 待实现范围 |
| --- | --- |
| [四项核心架构改进](Core-Architecture-Improvement-Plan.md) | 资源状态接入（通用 State 已实现）；错误分类及用户文案/开发日志分层；App 独立端到端/设备验收。App 结构迁移和存储抽象接口子项已完成，整份需求仍未完成。 |
| [Storage 生命周期边界](Storage-Lifecycle-Boundary-Plan.md) | 实现与专项回归完成；全量集成与 Simulator 限制保留，见验证记录。 |
| [App 宿主职责与目录调整方案](App-Host-Boundaries-Plan.md) | 核心架构第 3 项的纯组合根重构已实现；保留全量感知回归、Simulator 依赖与真实模型/原生 UI/物理设备验收。 |

共享State方案已由Container上下文方案替代，当前状态读取与后续验收见下方迁移需求；旧需求保留历史范围。已完成的存储接口与后端分离记录在 [Storage 实施历史](../../completed/Storage-Repository-Plan.md)，不再列为未实现需求。

部分完成时保留整份需求并更新状态；原范围全部完成后整份迁入 completed，更新当前设计和验证记录。分类及维护规则见 [需求总索引](../README.md)。

[Storage 四类容器与 State](Storage-Containers-Plan.md)：代码与专项验证已完成；全量声源回归和 Simulator 限制保留；公开事实/useState 的当前实现与后续验收见 [公开 State 计划](../Resource-State-Plan.md)。

- [PlatformKit 容器与 Gateway 设备接入](PlatformKit-Containers-Plan.md)：代码已实现，保留全量回归、Simulator 与设备验收缺口。

- [Direct container inputs](Direct-Container-Input-Plan.md): implementation and automated/build validation; native/device and comparable performance acceptance remain tracked.

- [Agent containers](Agent-Containers-Plan.md): root, seven roles and unified lifecycle implemented; validation and native acceptance tracked separately.

- [Container 状态与模型上下文](Container-State-Context.md)：替代共享Storage State，迁移到容器快照和Skill v3；验收见专项记录。

Completed scope: [Actions container and one-way execution](../../completed/Actions-Container.md); current independent limitations remain in the follow-up document below.

- [Container architecture follow-ups](Container-Architecture-Followups.md): inherited limitations and identified corrective work, including the current execution-policy routing discrepancy.

Completed scope: [Execution layer cleanup](../../completed/Execution-Layers-Cleanup.md), including redundant source consolidation and Xcode ownership reconciliation.

Completed scope: [Platform system facts](../../completed/Platform-System-State.md), including eight native sources, App injection, BasicSkill context and required automated checks. Native acceptance limits remain in the validation record.

Completed scope: [Prefer current facts](../../completed/Current-State-First.md): BasicSkill uses sufficient CURRENT STATE before Skill/function selection; model-adherence limits remain explicit.

Completed scope: [State summaries and explicit queries](../../completed/State-And-Query-Responsibilities.md): role-owned application summary, generic environment-query removal and preserved specific detail queries.

[Device.control 声明一致性修复](Device-Control-Declaration-Fix.md)：修复手机连接／忽略携带 fence 被执行声明拒绝的问题，自动化和手机复验结果见该记录。

已完成的 [NexArm 位置跟踪恢复](../../completed/NexArm-Position-Tracking-Restore.md) 已归档；真实硬件配置与动作验收独立记录，不将软件检查作为物理安全证明。

Completed scope: [NexArm 位置跟随平滑与设备约束](../../completed/NexArm-Smooth-Position-Tracking.md)。软件验证完成，物理平滑与硬件保护仍需独立验收。

Completed scope: [NexArm 通用设备反馈与连接错误归属](../../completed/NexArm-Device-Feedback-Ownership.md)。

Completed scope: [NexArm motor teaching and regression](../../completed/NexArm-Robot-Skill-Teaching.md): parameter/Skill teaching, relative motion and bounded model validation; residual model failures remain documented.

- [Container reflexivity](Container-Reflexivity.md): local state ownership, internal recursive reads and Skill-selected disclosure.

- [Camera preview orientation](Camera-Preview-Orientation.md): separate gravity-based capture from interface-based preview, crop, skeleton and gaze geometry.
