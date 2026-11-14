# 未实现需求

本目录维护原定范围尚未全部完成的需求，不收录已整体完成的实施计划或当前设计。部分完成的需求保留整份文档，已完成子项标明状态；不得通过拆走完成子项将原需求提前归档。原范围已完成、仅有另行跟踪的独立验收记录时，不将其重新列为开发需求。

## 分类规则

| 位置 | 归属 |
| --- | --- |
| [technical/](technical/README.md) | 以架构、接口、运行机制或工程边界为主的技术需求。 |
| [product/](product/README.md) | 以用户场景、功能和页面体验为主的产品需求；必要的技术约束随需求保留。 |
| 本目录根级 | 产品行为和技术机制难以独立拆分的交叉需求。 |

## 技术需求

[Storage 数据库与 Workspace 重构](Storage-Database-Refactor.md) 记录早期实现及独立原生/模型验收；数据边界已由[独立 Agent 方案](../completed/Message-Agent-Business-Separation.md) 更新为两侧私有消息和任务、通用通信及原始 HTTP 日志。

[四项核心架构改进](technical/Core-Architecture-Improvement-Plan.md) 中，通用内存状态机制与 App 结构迁移已实施；更多事实/Trigger/写入源治理、统一错误分类与分层展示及端到端验收仍待完成；第 4 项存储抽象接口已完成。原需求整份保留在本目录，不能按单项完成归档；独立的 [Storage 接口分离实施记录](../completed/Storage-Repository-Plan.md) 按其自身完整范围归档。

## 产品需求

[用户相册与记忆](product/User-Album-Memory-Plan.md) 包含“用户”板块内的两个独立页面：摄影任务媒体相册，以及周期性增量整理的日记式记忆。两项均待实施。

## 技术与产品交叉需求

| 需求 | 未实现范围 |
| --- | --- |
| [English and Simplified Chinese](App-Localization.md) | App language, user-facing copy, model prompts and speech language. |
| [统一记录与记忆管理](Unified-Memory-Plan.md) | 后续以 MemorySkill 统一 Writer 记录、聊天记录和综合记忆，评估独立 Memory Agent；当前 History/Writing 暂不调整。 |
| [State 公开寄存器与 useState](Resource-State-Plan.md) | 首批 camera/robot/task、作用域与每轮上下文已实施；真实模型/UI/物理验收及后续 Trigger/写入源治理另行跟进。 |
| [Face 窗口与 App 内灵动岛](Face-Window-Island-Plan.md) | 通用窗口/拍照首版已安装真机；取景比例、双用途共享采集和可见层级镜头权限已实现并自动化验证，本轮真机验收及独立岛保留。 |
| [摄影构图与运镜](Photographer-Proposal.md) | 摄影任务的构图和跟随体验，以及相应感知契约、运动策略与完成/安全边界。 |

## 其他待细化方向

以下保留原路线图中的需求方向，尚未细化为独立需求文档；细化时按上述规则确定归属，确认仍未实现后再列出具体范围。

| 方向 | 实施前需明确的边界 |
| --- | --- |
| Agent-driven app 的剩余接入 | 对照当前设计确认未接通的生命周期/能力事实、业务路由和结果续轮；已经实现的历史事务不重复列入需求。 |
| 更多模型能力 | 具体消费场景、类型化接口、真实适配器和不支持时的明确结果。 |
| 原生 Tool 事件与结果驱动交互 | 协议、权限/身份、取消以及反馈归属；不将已实现的模型 Tool 调用误列为未实现。 |
| 快慢认知与算力路由 | Agent 角色、能力可用性及资源策略。 |
| 活动监督与多窗口 | 具名生命周期/资源所有者和隔离状态路由。 |

## 维护与完成规则

新需求记录原始范围、状态、边界和验收标准。部分实现后更新子项状态，整份保留；原定功能、迁移/清理和明确约定的必要验收全部完成后，再将整份文档迁入 [completed](../completed/README.md)，同步更新源码 README、索引、决策/变更及验证记录。

后续 bug 修复和 feature 扩展独立跟踪，不使原需求重新变为未完成；也不能将原范围的缺项改称后续扩展以提前归档。独立的模型/设备验收继续在 [Roadmap](../Roadmap.md#acceptance-work) 和验证文档中如实记录；若验收本就是原需求的完成条件，则完成前不能归档。

[文档总索引](../README.md) · [当前产品范围](../Product-Scope.md) · [交付路线图](../Roadmap.md)

## 全部待办汇总（2026-10-24）

以下按当前需求正文汇总；实施、验收和待细化方向分别标注，历史失败不直接视为当前代码缺陷。

| 类型 | 待办 | 正文来源 |
| --- | --- | --- |
| 新增功能 | 多云端模型 URL/Key 配置保存、管理与选择 | [新增需求 §1](product/Model-Web-Speech-Plan.md#1-多云端模型配置与选择) |
| 独立验收 | WebKit浏览/截图与绘图功能已实现，真实模型/物理设备验收见专项记录 | [新增需求 §2](product/Model-Web-Speech-Plan.md#2-webkit-html-内容呈现组件) |
| 新增功能 | 持续聆听与回复期间打断判断、取消及输入交接 | [新增需求 §3](product/Model-Web-Speech-Plan.md#3-持续聆听与打断判断的-speech-perception-agent) |
| 功能 | 用户相册、摄影媒体聚合与视频完整链路 | [用户相册](product/User-Album-Memory-Plan.md) |
| 功能 | 日记式记忆、周期增量整理、摘要/关键词/embedding 与来源检索页面 | [用户记忆](product/User-Album-Memory-Plan.md) |
| 功能与策略 | 摄影自主构图、跟随与运镜及安全完成边界 | [摄影需求](Photographer-Proposal.md) |
| 工程 | 更多公开事实、Trigger、完整写入源治理 | [State](Resource-State-Plan.md)、[核心架构](technical/Core-Architecture-Improvement-Plan.md) |
| 工程 | 统一错误分类及用户文案/开发日志分层 | [核心架构](technical/Core-Architecture-Improvement-Plan.md) |
| 回归与验收 | App 宿主、Storage 生命周期/容器、PlatformKit 容器的全量集成、Simulator 外部依赖及真实模型/UI/设备缺口 | [技术需求索引](technical/README.md)，具体结果以各正文链接的最新验证记录为准 |
| 修复与验收 | iPhone 实时预览黑屏定位；直接输入迁移的完整业务/生命周期及同设备性能对照 | [直接容器输入](technical/Direct-Container-Input-Plan.md) |
| 独立验收 | 连续语音、模型切换/恢复、原生 UI/生命周期、机械臂/BLE/跟踪、流式执行/清理；功耗、内存与持续性能 | [Roadmap 验收清单](../Roadmap.md#acceptance-work)、[PlatformKit 计划](technical/PlatformKit-Containers-Plan.md) |
| 待细化 | Agent-driven 剩余接入、更多模型能力、原生 Tool 事件交互、快慢认知与算力路由、活动监督与多窗口 | [待细化方向](#其他待细化方向) |

本汇总不将已完成的 State 基础、App 结构迁移、存储抽象、云端 Tool 调用或半双工聆听重复列为开发任务。未设交付顺序；新增三项的实现前设计需同步更新相关源码 README。

[WebKit 与网页 Actions](../completed/WebKit-Actions-Plan.md) 已完成远程浏览/截图、独立模型绘图、局部编辑工作区及运行时 skills；独立模型/设备验收见专项验证记录。

[WriterAgent 流式创作](Writer-Agent-Plan.md)：独立创作角色、通用作品工作区、流式预览与后台委托；实施中。

[语音打断后的聆听恢复](Listening-Interruption-Recovery-Plan.md)：修复取消期间回复空闲事实被拦截造成的重新启听卡死；真机复验独立记录。

[Assistant 多源输入协调](Assistant-MultiSource-Input-Coordination.md)：既有整 Q、Decision 云端/本地与全双工链路已接入；最新“仅用户快决策、统一语义 Q、用户身份/时间 envelope 与选择性回复”已接入调度、提示词及自动回归，准备失败保留批次且不建行。Decision 独立选择云端 Provider/模型已接入保存、恢复与运行时，旧配置缺少选择时明确未配置；真实模型/UI/音频验收独立跟踪。

[全双工回声与字幕](Assistant-MultiSource-Input-Coordination.md)：已接入系统回声消除输入/语音处理 AEC 的实际状态确认及降级；双方字幕固定分区。真实扬声器回录、插话和原生页面效果仍需设备验收。

- [网页当前截图 State](technical/Web-Screenshot-State.md)：与相机统一多模态附件，只保留当前截图，撤除网页 feedback 附图链路。

[资源刷新过期误报](technical/Resource-Refresh-Supersession.md)：保存成功快速离页后的旧 UI 刷新正常结束与真实失败保留。
