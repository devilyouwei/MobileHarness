# ModelKit 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)、[模块设计](README.md)和受影响的能力或后端 README。

## 职责归属

| 位置 | 开发职责 |
| --- | --- |
| 模块根、[Support/Core](Support/Core/README.md) | SDK 入口、中立输入输出值、模型错误、会话、流、租约与取消。 |
| [Language](Language/README.md)、[Speech](Speech/README.md)、[Vision](Vision/README.md) | 各能力的接口及提供方实现。各模型自行拥有 tokenizer、提示协议、张量布局和算法状态。 |
| [Support/Backends](Support/Backends/README.md) | 可复用原生推理后端与张量执行机制。 |
| [Support/Management](Support/Management/README.md)、[Support/Config](Support/Config/README.md) | 制品目录、下载校验、注册、驻留管理、能力默认装配。 |
| [Support/Speech](Support/Speech/README.md) | SDK 内共享的语音转换机制。 |

## 开发边界

- 保持基础 SDK 独立。依赖限于本模块目标、系统框架和已批准第三方库。禁止引用其他项目模块的类型或运行时。使用 ModelKit 自有中立值和窄协议供外部注入。
- 处理推理与制品生命周期。禁止在 SDK 内决定 Agent 任务、业务提示词和历史选择、录音播放、设备行为或界面状态。模型专用协议写在其实现中，可复用图执行机制写在后端。
- 保持请求、会话和作用域所有权。流明确容量、溢出、取消和末尾语义。模型未加载、不兼容、下载失败或推理失败以明确错误报告，禁止伪造结果或悄悄更换提供方。
- 制品走已有目录和安装链路，使用已固定版本及校验规则。禁止把权重、凭据或样本放入源码。SDK 持有制品下载和驻留，业务方通过公开能力配置和请求。
- App 工程接线验证放 [Swift 测试](../../Tests/ModelKit/README.md)。模型效果、提示词矩阵和性能对照按[实验规则](../../experiments/AGENTS.md)执行。

## 示例

新增语言后端时，在 [Language/LLM](Language/LLM/README.md) 的提供方实现模型适配，复用中立请求与流接口。在现有制品目录和默认装配注册，再通过缺失制品、取消和正常输出场景验证。启用真实模型之前按仓库验证入口确认预算、制品版本和平台支持。
