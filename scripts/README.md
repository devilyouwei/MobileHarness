# Repository scripts

## 职责与边界

仓库检查、模型制品下载及 App 资源打包工具。脚本不拥有运行时业务策略，不提交凭据、模型权重或用户媒体；构建、合成检查和真实模型/设备验收分别报告。

## 检查与构建入口

| 文件 | 当前职责 |
| --- | --- |
| check.sh | Swift 版本、模块/依赖边界、离线 Python 检查、严格格式、根 Swift 测试及项目/权限 plist |
| check-modelkit-boundaries.py | 项目/SwiftPM 目标与 import 边界、无环依赖、独立基础模块、业务函数/资源约束 |
| build-ios.sh | 完整 Xcode 下按 Package.resolved 锁定版本依次构建四个 Simulator scheme，禁止自动更新依赖，并验证 App 中的 Agent/Skill 资源 |
| verify-app-agent-resources.py | 最终 Bundle Catalog 可发现、资源路径/字节与源码一致、Core 协议与函数声明打包边界；只排除资源根标准签名元数据，签名包与未签名包采用同一资源校验 |

完整 Xcode/SDK、具体模型和平台能力由相应工具自身校验；不能把缺失工具或失败命令记录为通过。执行结果、失败原因、版本和设备写入 [validation](../docs/validation/README.md)。

## 资源打包

| 文件 | 接口与约束 |
| --- | --- |
| select-app-icon.sh | original / robot-camera / lamp-arm / eyes-wink 显式选择并复制已保存的图标源，之后构建才能改变 App |
| clean-app-models.sh | Scheme 预构建清理生成的 Models/旧嵌入资源输出，不删除开发者源文件 |
| stage-voice-models.sh | device/simulator 只打包 model-catalog.json 与许可文本，不打包权重、图或 tokenizer |
| update-model-filelists.py | 生成 Xcode 资源 sandbox 输入/输出列表；修改制品元数据/许可后运行 |

资源所有权和显式 Catalog 见 [Resources](../MobileHarness/Resources/README.md)，私有签名见 [Config](../Config/README.md)。

## 模型下载与本地检查

model_download.py 从生产 model-catalog.json 选择源，通过分页 Hub 元数据解析文件集合、大小和 hash；使用四个工作者、受限相对路径、partial 文件与原子替换。默认复用现有文件，force 显式刷新，错误向上返回。ZIP 校验包括成员、路径、符号链接和替换保护。

| 入口 | 制品/用途 |
| --- | --- |
| download-gemma4.py / test-gemma4.sh | Gemma 4 E2B CoreAI；2B 默认，4B 是独立比较配置；真实推理显式启用 |
| download-nemotron.py / test-nemotron.sh | 生产 Nemotron Core ML 制品与 ASR 检查 |
| download-silero.py / test-silero.sh | Silero VAD 制品及适配检查 |
| download-moss-tts-nano.py | MOSS-TTS-Nano 制品 |
| download-yolo26-pose.py | pinned 官方 pose ZIP、安全校验及替换 |
| test-kokoro.sh | 可选 Kokoro 适配检查 |

下载器与 App 安装路径分离；App 运行时资源获取由 ModelKit Management/Hub 及 Settings 工作流拥有。各 gate/模型根路径见 [Tests](../Tests/README.md) 与对应适配器 README，不在普通检查中隐式下载或执行真实模型。

## 静态边界检查

✅ check-modelkit-boundaries.py 检查 Package／Xcode 的显式依赖、无环图、源码唯一归属和基础 SDK 独立闭包；FactoryKit 仅限 AppStorage。Agents／Actions 各编译完整所属目录，AgentCore／FunctionContracts 独立编译。

| 边界 | 约束 |
| --- | --- |
| 根与生命周期 | 四个基础 Container／Failure、App 同根注册和依赖；AgentContainer、角色容器和 Support 生命周期机制按实际所有者检查 |
| App | 仅组合公开能力，不构造 SQLite 后端、执行恢复、订阅业务输入或逐帧转发；首页准备由宿主生命周期拥有 |
| 角色输入 | 构造注入 UI 子容器与原生只读端口；角色拥有订阅和回执，根／ExecutionSession 不提供外部业务路由；感知不添加额外语音队列或通用媒体适配 |
| 执行与呈现 | Agents authorizes, Gateway schedules, and Actions owns camera/voice/UI execution；禁止反向实现依赖、直接写 UI 字段和越权原生控制 |
| 存储／事实／错误 | 公开 State 不保存完整 Context；业务不依赖具体后端或 IoC；基础错误结构独立且保留原始失败，路由事实不当作执行错误 |
| 资源与系统导入 | Skill Action／Channel 声明、生产资源及模板；系统框架按实际原生实现文件许可，业务模块不能进入基础库 |

源码形状检查不能替代运行行为或硬件验收。当前根接口见 [Agents](../MobileHarness/Agents/README.md#agent-container)，验证证据只写入 [validation](../docs/validation/README.md)。

## 工具链与测试隔离

check.sh 在未显式设置 DEVELOPER_DIR 且系统选中 CLT 时优先使用标准位置的完整 Xcode，不修改全局 xcode-select。FactoryKit 宏和原生 Metal 资源需要匹配的完整工具链。

普通测试并发，LiveRuntimeTests／原生窗口测试独立串行；两阶段都执行，任一失败返回失败，不改生产期限或用例内部并发。build-ios.sh 支持 MOBILEHARNESS_SIMULATOR_DERIVED_DATA，默认 build/SimulatorDerivedData；四个 scheme 与资源验证共用该路径。模拟器通过 MOBILEHARNESS_BUILD_VARIANT=simulator 排除设备专属的默认 Gemma CoreAI 后端。

## 千问显式实验工具

evaluate-qwen.py 从指定 ENV（默认 .env.local）读取 ALIYUN_API_URL／ALIYUN_API_KEY，先编译离线检查，再对显式模型列表运行 opt-in IntegrationTests；最多四个模型并行，不自动换模型或重试。Qwen仅注入Aliyun凭据，gpt-4.1仅注入OpenAI凭据及端点（默认官方）；凭据只经子进程环境传递，不输出、不写报告。普通 check 不触发真实调用。

完整 Xcode 的 Swift Testing helper 和 swift build --show-bin-path 用于执行独立测试进程，缺失 helper 或 bundle 时明确失败。输出前缀保护原结果。summary 保存输入 hash、实际 State、响应、调用和请求 hash，原始报告保存完整请求。输入 hash 包含 Agents 的 System 协议及 Action 目录模板。实际结果归 [千问报告](../docs/validation/Qwen-Workflow-Regression.md)。

compare-qwen-protocols.py 仅对显式 flash／max 运行隔离的阿里 Responses 探针，比较 xml-only、native-only、mixed、mixed-exclusive；合成调用和替身反馈不控制设备。限时、容量和调用次数有界，不自动重试，不保留凭据或私有 reasoning。探针结果不等同生产 Agent／Gateway 验收。

## 验收范围

❌ 原生 UI、麦克风／相机、真实模型准确率、设备动作和持续温度／性能由独立验收记录确认，脚本通过不能替代这些结果。

## 相册原生依赖

✅ 仅允许 UI/Settings/AlbumView.swift 使用 PhotosUI、CoreTransferable、UniformTypeIdentifiers、ImageIO 系统框架完成系统选择器及有界文件传输；UI 仍禁止项目模块依赖。根能力检查加入相册，要求 App 工厂复用 UIContainer.album。

## Container 上下文

✅ 架构检查验证Skill v3和命名空间来源，禁止恢复Storage/State及运行时StorageState导入；保留四基础模块独立性、唯一源码编译拥有者和执行授权检查。

## Qwen / GPT-4.1 提示词回归扩展

✅ 使用生产提示词与 qwen-workflows.json 中的有界场景集，evaluate-qwen.py接受三款Qwen与gpt-4.1；每个子进程仅注入对应Provider凭据，GPT使用OpenAI端点。运行前后记录生产上下文／Skill／解析与执行源hash，不修改提示词或放宽断言。报告保留失败与实际响应；本轮使用合成设备／仓库，不能替代真机验收。

## Gateway container ownership

✅ check-modelkit-boundaries.py rejects production Gateway core construction inside Agents, global shutdown in AgentRuntime, missing App gateway registration/dependency ordering and a missing AppStorage → Gateway target dependency. Existing SDK and source-ownership rules remain enforced.

## One-way execution boundary checks

The architecture checker enforces Gateway → FunctionContracts only, AgentCore → FunctionContracts only, Actions without AgentCore/Gateway, and Agents without Actions/CallRuntime/ExecutionRuntime. Existing ExecutionRuntime/CallRuntime targets have explicit Actions/Support source lists; no new target or per-domain container is permitted. App registration and lifecycle ordering retain all three business roots.

## Execution layer source ownership

The boundary checker requires Agents/Gateway/Actions Xcode groups to mirror the physical source directories, with one reference per file, complete Swift/Markdown/JSON coverage and no misplaced or stale groups. Module documentation checks accept an explicit directory link in the immediate parent README for a simple leaf. This navigation check does not change target source membership or runtime behavior.


`evaluate-qwen.py --robot-only` selects all robot-prefixed scenarios. The default model list is `gpt-4.1 qwen3.8-flash qwen3.8-max`; `--models` overrides it. `--cases` and `--robot-only` are mutually exclusive. Credentials remain provider-specific and reports retain production-source hashes.

## Reflexivity boundaries

The boundary check requires container source owners to expose explicit stateSnapshot reads. Generic App tree serialization is isolated to ApplicationStateInspection in AppStorage; the App prohibition on concrete business adaptation and per-function registration remains active everywhere. Source-owner validation includes this composition-only file.

Assistant State selection belongs to Agents/Assistant; App inspection keeps structural serialization isolated. No shared Support/native pass-through defines Assistant visibility.

The State boundary audit checks each concrete Container direct-read return type and identical Value codecs across the seven module-local schemas plus the App view. It no longer accepts a nonstandard child read merely because another method in that file has stateSnapshot.

State audits require stateSnapshot() async throws on each Container, snapshot-only descriptor reflection, identical Value codecs and path-only child references. Read bodies cannot recursively call child stateSnapshot() or create Tasks. Resource UI passive-read validation permits the uniform async cancellation signature while still rejecting asynchronous effects.

State read audits also reject native camera/status/authorization sampling and lazy private-context initialization from direct snapshot bodies. Resident source seeding, bounded/coalesced notification updates and invalidation fences are covered by PlatformStateTests; repository initialization remains owner-driven.

Direct State producer bodies also reject debug descriptions, Assistant selection calls and Skill mutation calls; consumer selection remains separate from producer schema classification.

The boundary check enforces Actions-owned camera/device scene lifecycle and rejects Gateway root configuration inside the Agent communication assembly.

The boundary checker rejects App references to ActionsBusinessAssembly, BluetoothWorkflow and CameraStorageFactory; business service construction belongs to ActionsContainer.

App responsibility checks reject independent Agent startup from UI preparation, optional bootstrap invocation, resource-context/holding interpretation in adapters and model warmup implementation in ServiceFactories.

The UI native-rendering allowlist permits AVKit only in Components/LocalVideoPlayer.swift for local-file playback. Camera.Video declarations follow the existing filename-to-module ownership check in VideoActions.swift; capture, permissions and media storage remain forbidden UI responsibilities.

UI根边界检查包含island第十一个子能力，要求App装配复用同一实例。Island Actions源码沿用执行层Xcode引用检查。

UI保持零包产品依赖，ActivityKit仅允许Attributes与原生driver，WidgetKit仅允许Widget入口。边界检查确认Widget只编译三个中立UI源文件，两个App目标均依赖并嵌入扩展；verify-app-island-resources.py校验Live Activity声明、URL scheme、扩展ID/版本/入口/可执行文件和已移除的旧SDK资源。build-ios.sh在App构建后执行此校验。

生命周期绑定检查区分UI场景呈现端口与根停止端口；Model后台连续运行、仅前台重新接纳，不再要求每次Scene隐藏都完整暂停。

Widget源边界精确包含IslandActivityAttributes、IslandIndicators和IslandActivityWidget；原生ActivityKit驱动只允许在UI/Components/Island/IslandSystemPresentation及共享Attributes中导入。

UI目录检查要求Container、Failure、StateSnapshot在模块根有唯一声明归属，错误回调及ContainerError归Failure；不限制根文件总数。Shared仅依赖Foundation且不包含功能输入/导航类型；输入与回执跟随现有功能owner，Face原生实现归Conversation。Widget和Metal打包路径随组件归档更新。

`test-webkit-simulator.sh` compiles a standalone test host from production UI Web sources, installs it into the iOS 27 simulator selected by `WEBKIT_SIMULATOR_ID` (default `booted`), and validates local multi-file HTML/CSS/JS, a revised page, remote HTTPS loading and visible JPEG snapshots. Continuous-preview cases retain native/document/node identity, programmatically scroll and zoom, and verify viewport restoration across full script execution and subsequent editing. These assertions do not replace physical touch/visual acceptance. It creates a temporary test app, never modifies the main app configuration or credentials, and prints the evidence location. `check-modelkit-boundaries.py` confines WebKit/AppKit imports to Web's native renderer and classifies the Web Action domain explicitly.

UI原生框架白名单将WindowAppearance的AppKit字体测量和ImageIO图标校验／缩图限定在Window目录的拥有文件，UI仍无项目／第三方依赖。

## Writer 双模型回归

`python3 scripts/evaluate-writer.py --output-prefix /tmp/writer-regression-unique` reads only `ALIYUN_API_URL` and `ALIYUN_API_KEY` from ignored `.env.local`; credentials enter test child environments, never logs/arguments. The legacy six-case mode defaults to Qwen with thinking enabled and provider-default output tokens. It can explicitly select `qwen3.8-max` and `deepseek-v4.1-flash`; the explicitly reported `deepseek4.1-flash` spelling maps to the latter, as verified by this provider's model inventory. There is no runtime model fallback.

The script builds the opt-in Swift tests, runs a no-model macOS WebKit resource-reload/click preflight, then executes selected models in separate processes. `--models`, `--cases`, `--seconds` and `--skip-build` select the experiment. Resume cases require `multifile` in the selection. New output prefixes prevent overwriting evidence. The 36-request and default 600-second per-case bounds apply only to the paid experiment, not production Writer or model output. An outer process timeout is recorded as exit124. Case results checkpoint immediately; `requests.json` updates during streams so incomplete cases remain diagnosable.

Each model output contains `records.sqlite`, SQLite workspace catalog and version files, complete per-case history JSON, request timing/tool/usage traces, render DOM/errors and `report.json`; the prefix summary records hashes and whether sources changed during the run. Artifacts contain synthetic test content. Keep credentials and device/user databases out of reports. Detailed evidence and platform limitations belong to [validation](../docs/validation/Writer-Model-Regression.md).

`--skip-build --test-binary /absolute/path/to/IntegrationTests.xctest/Contents/MacOS/IntegrationTests` reuses an explicitly built test bundle without taking the SwiftPM build lock. The WebKit preflight runs through the same test helper; the summary also records the binary SHA-256. Use a binary built from the recorded source revision.

## Writer records native simulator acceptance

`test-writer-records-simulator.sh` runs actual XCTest clicks against the built application without requiring Simulator.app. Set `WRITER_SIMULATOR_ID` to an isolated booted simulator and `WRITER_SIMULATOR_SEED` to one completed synthetic `evaluate-writer.py` output root. It refuses an existing database, seeds only that simulator, and builds a temporary UI-test runner from `Tests/UITests/WriterRecordsNativeAcceptance.swift`. It checks separate Settings entries, Writer workspace/request rows, header operations, file navigation and conversation sharing. The printed xcresult contains retained screenshots. It never seeds physical-device data or configures credentials. Synthetic history with real native clicks is distinct from live voice/model acceptance.

Writer evaluator --thinking enabled/minimum changes only the paid experiment Provider configuration (default enabled). Reports record the actual value; production Writer configuration and provider output defaults are unchanged. Use the original diagram goal for latency comparisons.

Writer UI acceptance seeds the shared SQLite catalog and copies writer/workspace_N files. It does not copy a JSON workspace index; native workspace selection uses the ID displayed in the seeded list.

## Agent public resource validation

check-modelkit-boundaries.py validates bundled Agent resource schema v9 and required nonblank descriptions up to 2048 UTF-8 bytes. Runtime/tests additionally validate identities, full schema, peer discovery permissions and compiled v7 projection. Resource packaging includes each role's private instruction/template assets through the existing Resources bundle.

## Writer prompt matrix runner

`evaluate-writer.py --matrix` loads writer-evaluation.json and writer-workflows.json, selecting only qwen3.8-max and gpt-6.1-sol by default. Aliyun and OpenAI use their own keys/URLs from the ignored env file, passed only to the corresponding subprocess. `--cases` runs a subset and `--output-prefix` requires fresh outputs. `--skip-build --test-binary` uses a recorded binary, verifies all three packaged Writer resources against source, and runs no-model WebKit/window preflight. Source hashes include Writer resources and scenario/config JSON. Per-case time/request limits belong solely to the experiment; model output limits remain provider defaults. Reports preserve failures and distinguish desktop window state from iOS UI acceptance.

`render-writer-review.swift` 是离线视觉证据工具：用 `swiftc -parse-as-library scripts/render-writer-review.swift -o /tmp/mh-writer-visual-review` 编译，传入已生成 HTML 的绝对路径和 PNG 输出路径。它在本机原生 WKWebView 的 390×844 视口加载真实本地文件，25 秒超时，不调用模型、不修改原文件。截图与矩阵中的模型渲染反馈独立；矩阵未挂载原生窗口时会如实记录截图不可用。

Matrix source fingerprints also include WriterWorkspaces and WriterMessages Swift implementations so request/target/history changes are captured with the Writer runtime. The runner records source, binary and packaged-resource consistency separately from model case outcomes.

Writer record UI acceptance can select `WRITER_UI_ONLY_TEST=testDelegationWorkspaceSeparation`; its seed is the temporary SQLite/workspaces fixture exported by the real-storage integration test through `WRITER_SEPARATION_UI_SEED`. The fixture includes 27 delegations and 40 workspace messages. This route verifies newest-first display, automatic older pages and navigation without model credentials or a physical-device database.

Agent 资源静态检查与运行时 schema 一致：Agent.json 使用 v10，category 必须为 perception 或 cognition；角色的实际归类由各自资源声明。

提示词资源校验覆盖 cognition Agent 的 Shared 与角色模板；Actions 与 ModelKit 的内部文案不属于本次资源迁移。最终包验证核对合并后的 Assistant 资源、完整文件集合与源文件字节。

Writer 评估运行前对 Writer 与 Shared 全部资源核对文件集合和源字节；新增业务模板也受旧 bundle 拒绝检查。源哈希继续覆盖全部 JSON/Markdown。
