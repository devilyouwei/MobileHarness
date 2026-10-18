# Repository scripts

## 职责与边界

仓库检查、模型制品下载及 App 资源打包工具。脚本不拥有运行时业务策略，不提交凭据、模型权重或用户媒体；构建、合成检查和真实模型/设备验收分别报告。

## 检查与构建入口

| 文件 | 当前职责 |
| --- | --- |
| check.sh | Swift 版本、模块/依赖边界、离线 Python 检查、严格格式、根 Swift 测试及项目/权限 plist |
| check-modelkit-boundaries.py | 项目/SwiftPM 目标与 import 边界、无环依赖、独立基础模块、业务函数/资源约束 |
| build-ios.sh | 完整 Xcode 下依次构建四个 Simulator scheme，并验证 App 中的 Agent/Skill 资源 |
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

## App 组合根边界

check-modelkit-boundaries.py 读取 SwiftPM 的显式源清单，区分 Agents/Actions 核心与同目录内的集成目标，验证每个生产源只有一个目标拥有者；App executable 只编译宿主文件，AppLifecycle 只依赖 Foundation。它禁止基础模块反向依赖集成、ActionBindings 导入 Agents/Gateway 实现、核心 Agents 导入 UI/执行实现，以及 App 中的领域意图/JSON/呈现转换。旧 AppWorkflows/功能目标和业务目录不能回归。

✅ 边界检查拒绝 App 直接构造 SQLiteRepositories、恢复记录或打开/关闭数据库；确认注册 SQLiteDatabaseStorage.start/stop 与 storage → agents 依赖。Agents/Actions 仍禁止导入具体后端。

## 待实现

- CoreAI 的 Simulator SDK 可用性取决于外部工具链；相应构建限制必须单独报告。
- 麦克风/相机/原生 UI、模型准确率、温度/性能和持续真机验收。

边界检查同时限制执行呈现适配器必须调用 UI 公开方法，拒绝恢复跨目标直接写 UI 字段。

Storage 四类容器边界检查覆盖 StorageCore/State/Cache/Files/Database/SQLite 与 AppStorage；源码必须唯一归属，业务不得构造具体文件后端或查询 IoC。

✅ 工具链选择：FactoryKit 的 SwiftUI 宏需要完整 Xcode；检查脚本在未显式设置 DEVELOPER_DIR 且系统选中 CLT 时，优先使用标准位置已安装的完整 Xcode，不修改全局 xcode-select。

## 公开 State 边界

✅ StorageState 仅承载公开事实；边界检查禁止完整 AgentContext 注册，校验 Skill schema v2/useState。沿用现有源码归属及目标，ActionBindings 显式依赖 StorageState。

[公开 State 契约](../MobileHarness/Storage/State/README.md)

## 千问提示词回归

✅ evaluate-qwen.py 读取指定 ENV（默认 .env.local）的 ALIYUN_API_URL / ALIYUN_API_KEY，先编译离线用例检查，再对显式模型列表执行同套 opt-in IntegrationTests。凭据仅经子进程环境传递，禁止输出或写入报告；不读取/使用 OpenAI Key。模型并行上限3，不自动换模型或重试；每模型独立报告，失败不阻止其他模型。报告位置显式指定，普通 check 不触发真实调用。

需要完整 Xcode：编译后通过 swift build --show-bin-path 定位 IntegrationTests bundle，使用所选 Xcode 的 Swift Testing helper 和测试库路径执行独立进程，避免多个 SwiftPM 命令持有同一构建锁。缺少 helper/bundle 明确失败。输出前缀不能覆盖已有原始结果；summary 保留源输入 hash、实际 State/响应/调用和请求 hash，完整请求留在原始报告。复现及实测限制见 [千问工作流报告](../docs/validation/Qwen-Workflow-Regression.md)。

✅ 输入 hash 显式包含 Agents Core 的 FunctionTokenPrompts.json，完整覆盖 Resources 外的共享协议教学；旧报告缺少此键的历史范围保持原样。


✅ compare-qwen-protocols.py 是隔离的阿里 Responses 协议探针，只允许 flash/max。相同函数语义/输入分别使用 xml-only、native-only、mixed、mixed-exclusive；独立场景与重复采样，含同一响应必须双调用的实验。只记录合成调用并返回替身反馈，不改变生产注册或执行设备，不把 HTTP 探针当生产 Agent/Gateway 验收。原始请求/公开输出、配对结果、协议及流程判定分别保留；限时/容量/调用次数有界，不自动重试，不保留凭据或私有 reasoning。

✅ Implemented: resource boundary checks require bundled Skill functions to be Actions with explicit Channel; generic schemas and Tool infrastructure remain supported. No cloud call is added to normal checks.

## Platform 根、设备接入与同帧呈现

check-modelkit-boundaries.py 保持四大基础模块无应用依赖、FactoryKit 仅在 AppStorage；Gateway 仅 DeviceInputAdapter.swift 可导入 PlatformKit 并声明设备来源。相机 UI 的 CoreVideo/Metal/QuartzCore 仅开放给帧值/渲染文件。check.sh 与 build-ios.sh 的失败和外部 SDK 限制见 [专项验证](../docs/validation/PlatformKit-Containers.md)。

✅ 相机渲染的系统 Synchronization 导入仅限 Camera/CameraFrameView.swift，用于原生渲染线程的最新状态/槽位互斥；UI 的应用模块依赖和其他文件许可保持原有边界。

## UI 容器与相机能力注入

✅ 边界检查新增 App-only Coordinator 工厂、AgentBindings 禁止构造 CameraState/Coordinator、四大基础库相互隔离和 UI 生命周期注册约束；同步新增源码的唯一归属。

## 外部输入边界

✅ 边界检查限制业务外部工厂重建信封；Gateway 不引用业务 schema，基础库不引入框架依赖。

## 统一容器异常通道

✅ 静态检查约束容器错误报告不使基础库依赖 Gateway/Signal，App 负责安装同根报告器，Gateway 不能反向依赖 UI/Storage/具体 Agents。容器异常只进被动诊断，不能注册模型执行函数。

## ApplicationControl 异常展示边界

✅ 已实现：静态检查禁止 ActionActivityWorkflow 直接从容器通道生成 UI 异常；校验 ApplicationControl 声明两类异常 Signal，内部呈现必须校验角色根身份。

## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。跨模块连接迁移仍是独立待办。

✅ 边界检查禁止把音频 routeChanged 事实直接上报为容器执行失败。


✅ 原生渲染框架导入按具体实现文件限制，业务或设备模块不能进入 UI。


✅ 守卫频谱不再使用 Canvas 绘制，并检查原生播放图由独立 actor 拥有；运行记录仍保留低频 elapsed 时间刷新。


✅ UI 守卫检查按功能归属的子容器／状态／接口，拒绝退役视觉演示、临时比较程序和旧坐标转换；系统导入仅按实际原生文件放行，UI 继续零项目依赖。

✅ 基础模块守卫拒绝通信／业务类型，检查原生能力返回协议、设备事件不采用 Error、业务不持有音频具体驱动及退役预热／错误文件。四大基础库无相互依赖，Signal 转换保留 Gateway。
