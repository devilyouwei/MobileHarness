# MobileHarness 技术文档核对

## 范围

核对 MobileHarness 下版本控制中的 README 与其源码、目标配置和资源清单。下载的模型制品自带文档由制品拥有。总设计维持架构、模块、关键链路三个部分。一级模块记录直接邻接接口和内部数据流。子目录文档聚焦自身接口、状态、失败及生命周期。

## 实施

- 简单叶目录的接口与约束并入直接父目录 README，保留源码位置。独立工作流、状态机和重要算法保留独立文档。
- 同步 AGENTS.md、文档索引规则、SwiftPM 文档排除项、Xcode 导航引用及目录覆盖检查。覆盖检查允许父 README 明确链接并说明简单叶目录。
- 对照源码更新接口、状态、容量、迁移和数据所有权。整理重复描述、过时说明与实现状态标记，维持现行约束和历史验证证据的各自入口。
- 核对文档相对路径和锚点，验证 Mermaid 图与工程元数据，运行受影响的仓库检查。

## 交付

[总设计](../../MobileHarness/README.md) 保留架构、模块、关键链路三部分。九个一级模块分别绘制直接邻接接口和内部链路。相机、音频、NexArm、Provider 保存与作品编辑补充目录内的流程和数据流。代码 README 以当前契约描述能力，历史及验证入口归 docs。

| 直接父层 | 并入的简单叶目录 |
| --- | --- |
| [Actions/Speech](../../MobileHarness/Actions/Speech/README.md) | Playback、Support |
| [Actions/System](../../MobileHarness/Actions/System/README.md) | Device、Diagnostics |
| [Actions/UI](../../MobileHarness/Actions/UI/README.md) | Support |
| [Agents/Support/Core](../../MobileHarness/Agents/Support/Core/README.md) | Input |
| [Gateway/Output](../../MobileHarness/Gateway/Output/README.md) | Dispatch、Results |
| [ModelKit/Speech/VAD](../../MobileHarness/ModelKit/Speech/VAD/README.md) | Energy |
| [ModelKit/Support/Backends](../../MobileHarness/ModelKit/Support/Backends/README.md) | CoreML |
| [ModelKit/Support/Speech](../../MobileHarness/ModelKit/Support/Speech/README.md) | Apple |
| [Resources/Agents](../../MobileHarness/Resources/Agents/README.md) | Shared |
| [Resources/Assets.xcassets](../../MobileHarness/Resources/Assets.xcassets/README.md) | AppIcon.appiconset |
| [Storage/Cache](../../MobileHarness/Storage/Cache/README.md) | Image |
| [Storage/Database](../../MobileHarness/Storage/Database/README.md) | Devices、Shared、WorkspaceFiles |

SQLite 当前十一表及升级路径、Writer 委托与工具归属、ModelKit D3、共享 Skill 和 Writer 私有 Tool 的绑定、UI 公开 State 节点及运行时日志能力均按源码核对。

[验证记录](../validation/Readme-Ownership-Audit.md)
