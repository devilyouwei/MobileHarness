# Project documentation

文档按职责维护：未完成需求、完整交付归档、当前说明、决策、验证证据和历史资料各有独立入口。当前技术契约由源码 README 拥有；历史结果不能直接作为当前能力或验收结论。

## 分类与入口

| 位置 | 内容 |
| --- | --- |
| [requirements/](requirements/README.md) | 原范围尚未全部完成的需求；technical 为技术需求，product 为产品需求，交叉需求放在根级。 |
| [completed/](completed/README.md) | 原需求全部完成后整份归档的需求与实施计划。 |
| [validation/](validation/README.md) | 自动化检查、模型实验、设备实测和验收步骤。 |
| [history/](history/README.md) | 变更、历史里程碑、迁出的旧说明和原始 Markdown 设计。 |
| [adr/](adr/README.md) | 架构决策、理由和替代关系。 |
| [measurements/](measurements/README.md) | 保留的原始测量数据及解释约束。 |
| [licenses/](licenses/README.md) | 第三方许可和分发说明。 |

## 当前产品与架构说明

| 文档 | 唯一职责 |
| --- | --- |
| [Product scope](Product-Scope.md) | 用户能做什么、产品范围及明确限制。 |
| [Architecture](Architecture.md) | 模块如何协作，主要输入、执行、数据与生命周期流向。 |
| [Concepts](Concepts.md) | Signal、Agent、Action、Task、Skill、完成与接纳等术语。 |
| [Platform boundaries](Platform-Boundaries.md) | 平台授权、原生能力与物理控制边界。 |
| [Roadmap](Roadmap.md) | 当前待交付方向和独立验收事项的导航。 |
| [Overall technical design](../MobileHarness/README.md) | 完整框架、模块边界、编译依赖和跨模块技术流程。 |
| [Module READMEs](../MobileHarness/README.md#part-ii--module-responsibilities) | 各目录的接口、状态、算法、生命周期、容量和失败契约。 |

## Experiments, tests and acceptance

[验证索引](validation/README.md) 区分可执行验收指南、项目验证日志和专项历史报告。测试是否执行、成功与失败、模型/设备/版本及证据限制，均在相应报告记录；编译或替身测试不等于真实模型、原生 UI 或物理设备验收。

## 需求与归档规则

部分完成的需求保留整份文档并更新子项状态；原定功能、迁移/清理和明确约定的必要验收全部完成后，才整份迁入 completed。后续独立 bug 修复或 feature 扩展不影响原需求归档，也不能将原范围缺项改称扩展以提前归档。详细规则见 [归档索引](completed/README.md#归档规则)。

独立验收的缺口在 Roadmap 和验证资料中跟进；若验收本身是原需求完成条件，则完成前不能归档。

## 文档维护

- 当前说明只保留现行行为和必要边界；接口或数值细节链接到拥有它的源码 README。
- 需求保存目标与验收条件，ADR 保存决定与理由，变更日志保存日期与变更，验证报告保存方法与证据。相同内容保留一个正文来源，其他位置使用链接。
- 历史记录中的“当前”“默认”“待实现”只对应当时版本；不能从旧记录自动生成当前待办或覆盖新设计。
- 目录或文件迁移同步更新全仓引用与文档导航。保留历史证据的日期、失败、指标和设备范围，不将旧失败改写为通过。
- 原始 Word 设计源 [Technical_Design.docx](Technical_Design.docx) 保持原路径与内容；[原始 Markdown 设计](history/Tech_Design.md) 归入历史资料。
