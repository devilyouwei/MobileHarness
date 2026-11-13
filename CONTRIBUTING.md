# 开发约定

使用 main 主分支和短期 `feat/…`、`fix/…`、`docs/…` 分支，通过 PR 合并。提交消息建议 `feat(runtime): …` 等 Conventional Commits。初始化只创建本地仓库，不自动设置远程或发布。

代码格式由工具链自带 `swift format` 和 `.swift-format` 决定；提交前运行 `./scripts/check.sh`，具备 Xcode 时运行 `./scripts/build-ios.sh`。CI 使用 macos-26 runner 并要求 Xcode 27.0；若托管镜像未提供该版本，需要更新镜像或配置具有该工具链的 runner，不能跳过检查伪装成功。

按 [MobileHarness/README.md 的项目结构](MobileHarness/README.md#target-map)放置源码并核对 target 映射；docs/history/Tech_Design.md 与 Technical_Design.docx 保留为历史设计来源。MobileHarness/App 中非 Package 管理的宿主 Swift 文件新增后加入 Xcode App target；独立 Workflows、BehaviorAssembly、UI 及其他共享模块由根 Package.swift 的显式 path 管理，不重复加入 App 的 Compile Sources。Xcode 导航分组也应同步更新。Tests 位于仓库根目录，使用 Swift Testing。依赖版本需要可复现；增加第三方依赖后提交相应 Package.resolved，并检查许可证。模型权重不入仓库，后续使用有校验和与许可证元数据的独立制品存储。

不要将签名证书、Team 私钥、API key、真实用户音视频、设备令牌写入代码、日志或测试数据。项目采用标准 [PolyForm Noncommercial License 1.0.0](LICENSE)，允许条款规定的非商业用途及特定机构用途，属于源码公开许可。

新 Agent 必须声明输入、输出、函数和工具能力；跨 Agent 通过网关事件通信。所有队列注明容量与满载策略。硬件动作必须在平台层验证参数、权限、取消和断开行为。禁止通过 `@unchecked Sendable` 或 private API 绕开架构问题。

设计变化记录 ADR；PR 描述实际结果和已执行验证。重要验证包括能力拒绝、调用关联、队列满、取消、重启和失败隔离。UI 新功能同时考虑中文、Dynamic Type 与 VoiceOver。

## Capability ownership

Organize ModelKit and PlatformKit by capability domain. PlatformKit owns device/OS data input and output (Audio, Vision, Connectivity); ModelKit owns model-driven data processing (Speech, Language, Vision), including model-specific preprocessing and decoding. Core holds each layer’s shared contracts. Keep basic capture format adaptation with PlatformKit, sampling/admission policy with Gateway, and business decisions with Agents. App bridges data and injects services without introducing dependencies between ModelKit and PlatformKit. Synthesis returns PCM; playback belongs to the device service. See the [comparison](MobileHarness/README.md#2-framework).

## Contribution licensing

提交贡献前请阅读 [LICENSE](LICENSE)。除非另有书面约定，有意提交并供本项目纳入的贡献按同一 PolyForm Noncommercial License 1.0.0 提供。你保留贡献版权，并须有权提交；请保留第三方来源和许可。此流程不包含版权转让或额外商业再许可授权，项目维护者不会仅因接受 PR 就取得这些权利。若需将外部贡献纳入商业授权版本，须先与相关权利人另行取得适当书面授权；尚未设立独立 CLA。此前有效签订或授出的授权不因此说明自动撤销。
