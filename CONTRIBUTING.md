# 开发约定

使用 main 主分支和短期 `feat/…`、`fix/…`、`docs/…` 分支，通过 PR 合并。提交消息建议 `feat(runtime): …` 等 Conventional Commits。初始化只创建本地仓库，不自动设置远程或发布。

代码格式由工具链自带 `swift format` 和 `.swift-format` 决定；提交前运行 `./scripts/check.sh`，具备 Xcode 时运行 `./scripts/build-ios.sh`。CI 使用 macos-26 runner 并要求 Xcode 27.0；若托管镜像未提供该版本，需要更新镜像或配置具有该工具链的 runner，不能跳过检查伪装成功。

按 [MobileHarness/README.md 的项目结构](MobileHarness/README.md#target-map)放置源码并核对 target 映射；docs/history/Tech_Design.md 与 Technical_Design.docx 保留为历史设计来源。MobileHarness/App 中非 Package 管理的宿主 Swift 文件新增后加入 Xcode App target；独立 Workflows、BehaviorAssembly、UI 及其他共享模块由根 Package.swift 的显式 path 管理，不重复加入 App 的 Compile Sources。Xcode 导航分组也应同步更新。Tests 位于仓库根目录，使用 Swift Testing。依赖版本需要可复现；增加第三方依赖后提交相应 Package.resolved，并检查许可证。模型权重不入仓库，后续使用有校验和与许可证元数据的独立制品存储。

不要将签名证书、Team 私钥、API key、真实用户音视频、设备令牌写入代码、日志或测试数据。项目采用标准 [PolyForm Noncommercial License 1.0.0](LICENSE)，允许条款规定的非商业用途及特定机构用途，属于源码公开许可。

新 Agent 必须声明输入、输出、函数和工具能力；跨 Agent 通过网关事件通信。所有队列注明容量与满载策略。硬件动作必须在平台层验证参数、权限、取消和断开行为。禁止通过 `@unchecked Sendable` 或 private API 绕开架构问题。

设计变化记录 ADR；PR 描述实际结果和已执行验证。重要验证包括能力拒绝、调用关联、队列满、取消、重启和失败隔离。UI 新功能同时考虑中文、Dynamic Type 与 VoiceOver。

## Research 与 software engineering

- **Research → `experiments/<任务>/`**：评估提示词、模型效果、业务 case 和推理性能。原始集放任务内 `datasets/`；固定数据集、模型版本、提示词和评分规则后做对照。只使用 Python 直接调用模型，不编译或启动 App/Swift。App 原生链路验证归 Tests。原始结果、请求轨迹和环境快照写任务内 `results/`，方法与结论写 `docs/validation/`，保留失败和复现命令。
- **Engineering → `Tests/<所属模块>/`**：验证接口、状态、集成、取消、资源释放和失败处理，包括模型管理、部署与推理链路。允许单模型、少量请求验证一次通信、Assistant 请求或 Writer delegate；多 case/模型效果对照归 experiments。为行为变更补充可重复的回归测试，运行 `./scripts/check.sh`；具备 Xcode 时运行 `./scripts/build-ios.sh`，如实报告失败与未执行项。
- **共享制品 → `Models/<模型名>/`**：实验与测试显式选择同一制品，固定版本并记录校验和；权重不提交，凭据、环境、数据集和运行结果不放这里。App 生产部署配置仍由原模块维护。

按验证目的归属：提示词构造、参数和解析契约放 `Tests`；模型读完提示词后的回答质量与任务成功率放 `experiments`。工程测试通过和黑盒评估达标分别报告。

## Capability ownership

Organize ModelKit and PlatformKit by capability domain. PlatformKit owns device/OS data input and output (Audio, Vision, Connectivity); ModelKit owns model-driven data processing (Speech, Language, Vision), including model-specific preprocessing and decoding. Core holds each layer’s shared contracts. Keep basic capture format adaptation with PlatformKit, sampling/admission policy with Gateway, and business decisions with Agents. App bridges data and injects services without introducing dependencies between ModelKit and PlatformKit. Synthesis returns PCM; playback belongs to the device service. See the [comparison](MobileHarness/README.md#2-framework).

## Contribution licensing

提交贡献前请阅读 [LICENSE](LICENSE)。除非另有书面约定，有意提交并供本项目纳入的贡献按同一 PolyForm Noncommercial License 1.0.0 提供。你保留贡献版权，并须有权提交；请保留第三方来源和许可。此流程不包含版权转让或额外商业再许可授权，项目维护者不会仅因接受 PR 就取得这些权利。若需将外部贡献纳入商业授权版本，须先与相关权利人另行取得适当书面授权；尚未设立独立 CLA。此前有效签订或授出的授权不因此说明自动撤销。

仓库自动化工具放 `scripts`：`checks` 管工具离线回归与静态约束，`resources` 管 App 打包，`models` 管制品和少量原生适配检查，`simulator` 管原生 UI 验收。根目录只保留通用检查/构建入口；新增工具先复用同职责实现，详见 [脚本清单](scripts/README.md)。

跨模块链路测试跟随发起工作流的模块：Assistant/Writer/感知归 Tests/Agents，业务执行归 Tests/Actions，通信调度归 Tests/Gateway，生产装配与宿主生命周期归 Tests/App。默认工程回归、单模型通信 smoke、Simulator 装配和原生 UI 验收按 [Tests 入口](Tests/README.md) 分别运行并报告。

Tests 与 experiments 完全独立：不互相导入代码，不读取对方的数据、配置、提示词或结果，也不共用项目辅助库。允许重复实现；唯一共享内容是 Models 中按来源、版本和校验和约定下载的模型制品。

scripts 为 agent 编排批量 Tests 或 experiments；双方各自拥有验证逻辑，仅共享 Models 制品。完整目录与执行规则见 [AGENTS.md](AGENTS.md#9-agent-validation-workflow-and-directory-ownership)。

## Useful contributions

Reproducible device reports, focused fixes, tests, documentation and capability integrations are welcome. Use the issue/PR templates; include the device/toolchain, expected and actual behavior, and sanitized reproduction steps. Discuss substantial architecture or dependency changes before implementation.
