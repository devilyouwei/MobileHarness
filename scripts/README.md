# Repository scripts

✅ 边界检查约束角色专用文件归属，禁止 ExecutionSession 提供外部业务请求入口、请求表或结果等待器；Communication 只存业务值与通信契约。

✅ 基础模块检查要求四个根各有 Container／Failure 文件，旧路径退役，源码唯一归属保持；模型装配入口虽移到物理根，仍只属于 ModelKitDefaults。

✅ 源码检查要求 App 注册模型根与四子能力并接入生命周期，生产消费者不得调用静态 Defaults 或直接构造 ModelManager；基础 SDK 的依赖闭包仍独立检查。

✅ 已实现：源码回归检查约束历史只读准备不调用语音停机，导航与场景前台共同限制相机准入。

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

## App 组合根边界

check-modelkit-boundaries.py validates explicit dependency sets, one compiled owner per production source, independent foundational SDK closures and AgentCore, and direct local-input boundaries. Agents and Actions compile complete owning targets. App remains composition-only, Actions cannot depend on Agents/Gateway implementations, and retired binding targets, codecs, external subscriptions and JSON polling cannot return.

✅ 边界检查拒绝 App 直接构造 SQLiteRepositories、恢复记录或打开/关闭数据库；确认注册 SQLiteDatabaseStorage.start/stop 与 storage → agents 依赖。Agents/Actions 仍禁止导入具体后端。

## 待实现

- CoreAI 的 Simulator SDK 可用性取决于外部工具链；相应构建限制必须单独报告。
- 麦克风/相机/原生 UI、模型准确率、温度/性能和持续真机验收。

边界检查同时限制执行呈现适配器必须调用 UI 公开方法，拒绝恢复跨目标直接写 UI 字段。

Storage 四类容器边界检查覆盖 StorageCore/State/Cache/Files/Database/SQLite 与 AppStorage；源码必须唯一归属，业务不得构造具体文件后端或查询 IoC。

✅ 工具链选择：FactoryKit 的 SwiftUI 宏需要完整 Xcode；检查脚本在未显式设置 DEVELOPER_DIR 且系统选中 CLT 时，优先使用标准位置已安装的完整 Xcode，不修改全局 xcode-select。

## 公开 State 边界

✅ StorageState 仅承载公开事实；边界检查禁止完整 AgentContext 注册，校验 Skill schema v2/useState。沿用现有源码归属及目标，Actions 显式依赖 StorageState。

[公开 State 契约](../MobileHarness/Storage/State/README.md)

## 千问提示词回归

✅ evaluate-qwen.py 读取指定 ENV（默认 .env.local）的 ALIYUN_API_URL / ALIYUN_API_KEY，先编译离线用例检查，再对显式模型列表执行同套 opt-in IntegrationTests。凭据仅经子进程环境传递，禁止输出或写入报告；不读取/使用 OpenAI Key。模型并行上限3，不自动换模型或重试；每模型独立报告，失败不阻止其他模型。报告位置显式指定，普通 check 不触发真实调用。

需要完整 Xcode：编译后通过 swift build --show-bin-path 定位 IntegrationTests bundle，使用所选 Xcode 的 Swift Testing helper 和测试库路径执行独立进程，避免多个 SwiftPM 命令持有同一构建锁。缺少 helper/bundle 明确失败。输出前缀不能覆盖已有原始结果；summary 保留源输入 hash、实际 State/响应/调用和请求 hash，完整请求留在原始报告。复现及实测限制见 [千问工作流报告](../docs/validation/Qwen-Workflow-Regression.md)。

✅ 输入 hash 显式包含 Agents Core 的 FunctionTokenPrompts.json，完整覆盖 Resources 外的共享协议教学；旧报告缺少此键的历史范围保持原样。


✅ compare-qwen-protocols.py 是隔离的阿里 Responses 协议探针，只允许 flash/max。相同函数语义/输入分别使用 xml-only、native-only、mixed、mixed-exclusive；独立场景与重复采样，含同一响应必须双调用的实验。只记录合成调用并返回替身反馈，不改变生产注册或执行设备，不把 HTTP 探针当生产 Agent/Gateway 验收。原始请求/公开输出、配对结果、协议及流程判定分别保留；限时/容量/调用次数有界，不自动重试，不保留凭据或私有 reasoning。

✅ Implemented: resource boundary checks require bundled Skill functions to be Actions with explicit Channel; generic schemas and Tool infrastructure remain supported. No cloud call is added to normal checks.

## Platform 根、设备接入与同帧呈现

check-modelkit-boundaries.py 保持四大基础模块无应用依赖、FactoryKit 仅在 AppStorage；Gateway 不依赖 PlatformKit，不声明设备输入来源。相机 UI 的 CoreVideo/Metal/QuartzCore 仅开放给帧值/渲染文件。历史检查与 SDK 限制见 [专项验证](../docs/validation/PlatformKit-Containers.md)，当前验收见 [直连验证](../docs/validation/Direct-Container-Input.md)。

✅ 边界收尾：移除退役 DeviceInputAdapter 的通用层例外，同时在 Agents 与 Gateway 禁止旧适配类型；本地领域输入从 ProcessingContext 构造接纳值，不交给 Gateway 编码外部 Signal。

✅ 相机渲染的系统 Synchronization 导入仅限 Camera/CameraFrameView.swift，用于原生渲染线程的最新状态/槽位互斥；UI 的应用模块依赖和其他文件许可保持原有边界。

## UI 容器与相机能力注入

✅ 边界检查新增 App-only Coordinator 工厂、Agents 禁止构造 CameraState/Coordinator、四大基础库相互隔离和 UI 生命周期注册约束；同步新增源码的唯一归属。

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

✅ GemmaContextBudget 只允许在ModelKit本地Gemma适配及其测试出现，避免将本地模型窗口适配迁入Agent或云端路径。

✅ 已实现：源码守卫验证空间会话惰性创建及录音启动配置不再在MainActor直接调用setActive；不替代物理音频验收。

✅ 已实现：系统SDK白名单纳入OSLog，仅供原生性能signpost；保留所有基础模块项目依赖限制。

✅ 已实现：首页准备归属检查，基础库不引入模型／App依赖，准备协调器由App生命周期注册，云端不添加隐式生成探测。


✅ check-modelkit-boundaries.py比较四种独立Failure的公共结构与包装逻辑，允许模块各自分类原生错误；同时检查仅导入Foundation及退休清理类型不再出现，防止标准漂移。

✅ 已恢复：移除对应已撤回音频实验实现的形状检查，保留采集失败 token 隔离、模块边界及统一错误结构检查；不通过守卫强制保留未经硬件验收的音频实现。

✅ 已恢复（性能待真机对照）的基线：录音会话配置恢复到 6431d36f 的同步调用顺序，空间 AVCaptureSession 恢复为仅在录音后端实例创建时初始化并由后端持有；不改变四声道、首 PCM 就绪、错误上报和停止录音语义。移除仅服务于异步配置的 preparation Task／加入代码及其源码形状检查，保留 token 隔离；后端仍只在请求录音时创建，容器 boot 不打开设备。该对照不代表性能修复已验收。

## Agent-owned UI inputs

✅ Source guards require constructor-injected UI capabilities and role-owned subscription lifecycle, reject UI event dispatch/subscription in AgentApplication and reject ExecutionSession/InputGateway references in role UI handlers. Input format preparation is permitted in the actual perception Agent, including when it imports a UI capability.

## 原生输入归属检查

✅ 已实现：禁止 VoiceSessionCoordinator／AudioDetectionSession 消费原始 PCM、NativePerceptionInputs 或回调转交；要求感知角色直接注入／消费只读原生端口。保持基础模块独立和受保护的输出执行。

## 语音执行归属收敛

✅ 已实现：边界检查禁止 Agents 语音会话持有 AudioInputOutput 控制端或直接执行采集/播放/权限，禁止 SpeechPerception 直接写 UI；确认 Actions 实际拥有执行实现且无 Agents/Gateway 反向依赖。

## 直连链路收尾

✅ 边界检查覆盖角色自有订阅、Actions 实际执行、受保护的类型化历史读取及退役路径。模拟器变体显式排除不支持 Simulator SDK 的默认 Gemma 后端；四个 scheme 全部执行。检查保留普通测试并发，实际时钟和原生窗口用例在独立阶段串行运行；任一阶段失败仍执行另一阶段并返回失败。结果归验证记录。

## Runtime validation isolation

The default check runs ordinary tests concurrently, then executes the live-runtime and native-window suites separately. These suites are serialized because their assertions use real capture freshness, mechanical deadlines, media expiry, or the process-wide AppKit application. Business concurrency remains exercised inside each test. No global parallelism flag or production deadline is changed; excluded cases in the first phase must execute in the second.

✅ 构建缓存隔离：`build-ios.sh` 支持可选 `MOBILEHARNESS_SIMULATOR_DERIVED_DATA` 路径，四个 scheme 与最终资源验证使用同一路径；默认仍为 `build/SimulatorDerivedData`，可在工作区外验证。不改变 App 配置或依赖版本；迁移已有缓存时须保留编译插件缓存的绝对路径引用。
✅ 边界检查禁止感知角色通用媒体接纳、额外语音队列和旧采样包装；检查退役来源和未生效的本地工厂参数。

✅ 不透明图像附件直接保留 Sendable 原生帧本体；角色校验 CameraFrame，Gateway 无需引用 PlatformKit 即可保留和转交附件。

✅ 边界检查校验新文件归属、App 页面构造边界、独立 AgentCore 及固定 Memory 提交保护，并禁止退役别名、未使用投影和 Chat 父提交接收分支。


## Actions 接入契约

Actions 按业务能力组织源码，保持原编译目标。生产调用显式连接独立相机、语音、UI 呈现和 Task 端点；不通过无关能力的类型转换探测。验证和导航按实际源码所有权维护，业务授权与生命周期继续由原拥有者负责。

## Agents 角色与共享机制

具体角色装配归 Agents 根级，Support 保留通用机制；角色私有载荷和会话控制由角色解释，通过注入的解码／Context 钩子接入共享准入。输入身份、Task scope、取消加入和真实结果保持独立，源码和验证按其实际所有者维护。
