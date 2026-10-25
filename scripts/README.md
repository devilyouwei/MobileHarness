# Repository scripts

## 职责与边界

仓库检查、模型制品下载及 App 资源打包工具。脚本不拥有运行时业务策略，不提交凭据、模型权重或用户媒体；构建、合成检查和真实模型/设备验收分别报告。

## 检查与构建入口

| 文件 | 当前职责 |
| --- | --- |
| check.sh | Swift 版本、模块/依赖边界、离线 Python 检查、严格格式、根 Swift 测试及项目/权限 plist |
| check-modelkit-boundaries.py | 项目/SwiftPM 目标与 import 边界、无环依赖、独立基础模块、业务函数/资源约束 |
| build-ios.sh | 完整 Xcode 下按 Package.resolved 锁定版本依次构建四个 Simulator scheme，禁止自动更新依赖，并验证 App 中的 Agent/Skill 资源 |
| verify-app-agent-resources.py | 最终 Bundle Catalog 可发现、资源路径/字节与源码一致、Core 协议与函数声明打包边界 |

完整 Xcode/SDK、具体模型和平台能力由相应工具自身校验；不能把缺失工具或失败命令记录为通过。执行结果、失败原因、版本和设备写入 [validation](../docs/validation/README.md)。

## 资源打包

| 文件 | 接口与约束 |
| --- | --- |
| select-app-icon.sh | original / robot-camera / lamp-arm 显式选择并复制已保存的图标源，之后构建才能改变 App |
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

完整 Xcode 的 Swift Testing helper 和 swift build --show-bin-path 用于执行独立测试进程；缺失 helper／bundle 明确失败。输出前缀不得覆盖原结果；summary 保存输入 hash、实际 State／响应／调用和请求 hash，原始报告保存完整请求。输入 hash 包含 AgentCore 的 FunctionTokenPrompts.json。实际结果归 [千问报告](../docs/validation/Qwen-Workflow-Regression.md)。

compare-qwen-protocols.py 仅对显式 flash／max 运行隔离的阿里 Responses 探针，比较 xml-only、native-only、mixed、mixed-exclusive；合成调用和替身反馈不控制设备。限时、容量和调用次数有界，不自动重试，不保留凭据或私有 reasoning。探针结果不等同生产 Agent／Gateway 验收。

## 验收范围

❌ 原生 UI、麦克风／相机、真实模型准确率、设备动作和持续温度／性能由独立验收记录确认，脚本通过不能替代这些结果。

## 相册原生依赖

✅ 仅允许 UI/Settings/AlbumView.swift 使用 PhotosUI、CoreTransferable、UniformTypeIdentifiers、ImageIO 系统框架完成系统选择器及有界文件传输；UI 仍禁止项目模块依赖。根能力检查加入相册，要求 App 工厂复用 UIContainer.album。

## Container 上下文

✅ 架构检查验证Skill v3和命名空间来源，禁止恢复Storage/State及运行时StorageState导入；保留四基础模块独立性、唯一源码编译拥有者和执行授权检查。

## Qwen / GPT-4.1 提示词回归扩展

✅ 沿用59场景／85输入及生产提示词，evaluate-qwen.py接受三款Qwen与gpt-4.1；每个子进程仅注入对应Provider凭据，GPT使用OpenAI端点。运行前后记录生产上下文／Skill／解析与执行源hash，不修改提示词或放宽断言。报告保留失败与实际响应；本轮使用合成设备／仓库，不能替代真机验收。

## Gateway container ownership

✅ check-modelkit-boundaries.py rejects production Gateway core construction inside Agents, global shutdown in AgentRuntime, missing App gateway registration/dependency ordering and a missing AppStorage → Gateway target dependency. Existing SDK and source-ownership rules remain enforced.

## One-way execution boundary checks

The architecture checker enforces Gateway → FunctionContracts only, AgentCore → FunctionContracts only, Actions without AgentCore/Gateway, and Agents without Actions/CallRuntime/ExecutionRuntime. Existing ExecutionRuntime/CallRuntime targets have explicit Actions/Support source lists; no new target or per-domain container is permitted. App registration and lifecycle ordering retain all three business roots.

## Execution layer source ownership

The boundary checker requires Agents/Gateway/Actions Xcode groups to mirror the physical source directories, with one reference per file, complete Swift/README/JSON coverage and no misplaced or stale groups. This navigation check does not change target source membership or runtime behavior.
