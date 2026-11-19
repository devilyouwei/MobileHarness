# Tests

## 职责与运行

case 评估、提示词/业务用例对照与推理性能实验归 [experiments](../experiments/README.md)。App 模型管理、部署、适配器和推理链路测试（含真实模型验收）仍归 Tests/ModelKit。常规测试按被验证能力的职责组织；物理目录不等同于 SwiftPM 编译 target。根目录只保留全局测试契约和导航，具体回归和辅助代码归所属目录。

| 分类 | 内容 |
| --- | --- |
| [ModelKit](ModelKit/README.md) | SDK 核心、管理、下载、语言、语音与视觉适配 |
| [Agents](Agents/README.md) | 运行时、角色、上下文及提示词契约回归 |
| [Actions](Actions/README.md) | 函数契约、执行、设备和业务能力 |
| [Gateway](Gateway/README.md) | 输入、输出、调度及媒体传输 |
| [PlatformKit](PlatformKit/README.md) | 平台状态、音频、图像及连接能力 |
| [Storage](Storage/README.md) | 文件、数据库、仓库及存储生命周期 |
| [App](App/README.md) | 应用生命周期、工作流、设置与呈现组合 |
| [UI](UI/README.md) | UI 状态、请求、布局和显式原生验收入口 |

## 编译与资源边界

根 [Package.swift](../Package.swift) 的 `testSources` 使用仓库相对路径，显式记录每个既有 target 的源文件；`organizedTestTarget` 排除其他 target 的源文件及非源码。新增或移动 Swift 测试时同步更新这份成员表，非源码排除项登记在 `testNonSources`，不因目录相邻而增加依赖。测试名称、target 名称和 `swift test --filter` 标识保持稳定。跨能力测试替身仍在原 target 内共享，无新增公共测试库。

experiments 是纯 Python 数据/运行器目录，整个目录从 SwiftPM 测试 target 排除。本地模型和构建缓存不提交。

## 检查入口

从仓库根执行 `./scripts/check.sh`：模型边界、工程工具的 Python 离线回归、Swift 格式检查、Swift 测试和项目配置检查。Python 使用所属目录显式 discovery，无须把职责目录变成 Python package。

普通 Swift 用例与 `LiveRuntimeTests|NativePresentationTests` 分阶段执行，后者保留原有串行隔离。单个测试名称及 live gate 见各能力 README。真实网络、模型、原生 UI 和物理设备验收必须显式启用；合成端点、构建和自动化检查不能替代这些验收。

迁移和检查证据见 [Tests 整理验证](../docs/validation/Tests-Organization.md)。历史报告中的源路径与哈希属于当时版本，不能将旧记录的哈希改写为新源码哈希。

本地模型制品可与实验共享仓库根 [Models](../Models/README.md)，通过既有资源参数/环境变量显式选择。

## 少量真实模型链路验证

Tests 可用单个模型验证模块、通信和业务闭环；case/模型效果矩阵归 experiments。Assistant/Writer smoke 分别由 `MH_ASSISTANT_SMOKE=1`、`MH_WRITER_SMOKE=1` 启用，并显式提供 `MH_SMOKE_API_URL`、`MH_SMOKE_API_KEY`、`MH_SMOKE_MODEL`。从根目录使用 `swift test --filter assistantSingleModelRequestCompletesThroughGateway` 或 `writerSingleDelegatePublishesAndCompletes` 运行。各验证一个输入/delegate，最多8次请求；默认关闭，不自动读取凭据文件。

App通信、解析和原生渲染的辅助机制在既有 IntegrationTests target 内复用，不增加生产 API。Python评估器的schema、评分、统计及凭据隔离回归归 experiments，独立执行。

工程Python工具的离线回归与原生参考检查归仓库根 scripts；Tests 的可执行测试源码使用 Swift。scripts/check.sh 发现 scripts/checks/test_*.py。

## 跨模块链路归属

按发起工作流的业务所有者放置，不建通用 Integration 杂物目录：Assistant/Writer/感知闭环归 Agents；执行能力集成归 Actions；通信、Channel/wait 与资源调度归 Gateway；生产装配、根注册和宿主生命周期归 App。基础模块自身的机制测试留在基础模块。编译 target 不代表目录责任。

默认确定性链路随 check.sh 运行；有真实截止时间的少量回归进入已有 LiveRuntimeTests 串行阶段。生产 iOS 装配用 `./scripts/simulator/test-composition.sh`；真实 Assistant/Writer 模型 smoke 使用上文显式 gate；WebKit/Writer 原生 UI 使用 scripts/simulator 对应入口。各层单独报告，不用跳过的测试或构建成功充当链路验收。

Tests 与 experiments 完全独立：不互相导入代码，不读取对方的数据、配置、提示词或结果，也不共用项目辅助库。允许重复实现；唯一共享内容是 Models 中按来源、版本和校验和约定下载的模型制品。

Swift test sources validate App unit behavior, business logic and cross-module flows. Small model requests verify integration, never model quality or case-matrix performance.
