# UI 开发规范

适用于本目录及其子目录。先读[仓库规则](../../AGENTS.md)、[模块设计](README.md)和受影响视图或组件的 README。

## 职责归属

| 位置 | 开发职责 |
| --- | --- |
| 模块根、[Root](Root/README.md) | UIContainer 和中立公开契约，根页面组合、导航及根呈现。 |
| [Shared](Shared/README.md)、[Components](Components/README.md) | 可复用请求、接纳机制、通用呈现组件。 |
| [Conversation](Conversation/README.md)、[Camera](Camera/README.md) | 会话与 Face 展示、镜头画面、媒体与姿态呈现。 |
| [Settings](Settings/README.md)、[Diagnostics](Diagnostics/README.md) | 配置与观察页面、输入及真实结果的呈现。 |

## 开发边界

- 保持 UI 基础模块独立，使用 UI 自有的值、请求和端口。禁止导入其他项目模块、构造业务 Signal、直接执行模型、采集、设备或持久化操作。
- 用户输入通过类型化请求交给所有者。UI 持有导航、渲染、交互和呈现事实，禁止从呈现状态推断业务阶段或消耗业务回执两次。
- 根持有长期呈现能力。视图挂载和卸载只控制本地渲染或订阅。禁止从 onAppear、onDisappear 或布局回调改变跨模块业务生命周期。
- 将状态与呈现放在所属功能，通用组件留在 Components，复用机制放 Shared。Shared 禁止反向依赖具体功能。Root 负责页面组合。模块公开 API 和模块级失败留在根。
- 校验会话、代际和版本，回执区分接纳、已呈现和实际动画完成。复用中英文资源，状态、错误和可操作性保持一致。

## 示例

相机窗口的关闭按钮提交已有类型化请求，由相机事务所有者决定关闭和媒体处置。UI 根据真实结果更新窗口。通过 [UI 测试](../../Tests/UI/README.md)覆盖旧代回执、失败后可操作性和清理。触控和视觉表现单独验收。
