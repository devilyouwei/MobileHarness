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
