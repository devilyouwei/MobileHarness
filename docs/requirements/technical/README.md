# 技术需求

本目录收录原范围尚未全部完成的架构、接口和运行机制需求。用户场景为主的需求归 [产品需求](../product/README.md)，无法独立拆分的交叉需求归 [requirements 根目录](../README.md#技术与产品交叉需求)。

| 需求文档 | 待实现范围 |
| --- | --- |
| [四项核心架构改进](Core-Architecture-Improvement-Plan.md) | 资源状态接入（通用 State 已实现）；错误分类及用户文案/开发日志分层；App 独立端到端/设备验收。App 结构迁移和存储抽象接口子项已完成，整份需求仍未完成。 |
| [Storage 生命周期边界](Storage-Lifecycle-Boundary-Plan.md) | 实现与专项回归完成；全量集成与 Simulator 限制保留，见验证记录。 |
| [App 宿主职责与目录调整方案](App-Host-Boundaries-Plan.md) | 核心架构第 3 项的纯组合根重构已实现；保留全量感知回归、Simulator 依赖与真实模型/原生 UI/物理设备验收。 |

通用 State 注册、版本和纯转换机制已实现；camera/robot/task 与 Skill useState 每轮上下文已接通；更多事实和真实模型/UI/设备验收继续跟进。已完成的存储接口与后端分离记录在 [Storage 实施历史](../../completed/Storage-Repository-Plan.md)，不再列为未实现需求。

部分完成时保留整份需求并更新状态；原范围全部完成后整份迁入 completed，更新当前设计和验证记录。分类及维护规则见 [需求总索引](../README.md)。

[Storage 四类容器与 State](Storage-Containers-Plan.md)：代码与专项验证已完成；全量声源回归和 Simulator 限制保留；公开事实/useState 的当前实现与后续验收见 [公开 State 计划](../Resource-State-Plan.md)。
