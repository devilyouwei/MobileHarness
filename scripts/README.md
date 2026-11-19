# Agent 批处理与仓库工具

按职责归档，不按 Python / Shell 划分。根目录只保留常用检查与构建入口；下表同时说明每个脚本的用途。命令均从仓库根执行。

| 入口 | 职责 |
| --- | --- |
| [check.sh](check.sh) | 边界、工程工具 Python 离线回归、Swift 格式、普通/串行测试及 plist 检查；不自动下载或调用真实模型 |
| [build-ios.sh](build-ios.sh) | 使用锁定依赖构建五个 Simulator scheme，校验最终 App 资源；支持 MOBILEHARNESS_SIMULATOR_DERIVED_DATA |

## checks：仓库与工具回归

| 文件 | 职责 |
| --- | --- |
| [check-modelkit-boundaries.py](checks/check-modelkit-boundaries.py) | 编译目标、依赖无环、源码所有权、模块/资源边界的静态约束 |
| [test_model_download.py](checks/test_model_download.py) | ZIP 下载安装的路径、hash、符号链接与替换保护；不联网 |

新增工程 Python 工具回归放本目录，命名 `test_*.py`，由 check.sh 发现。App 工程测试使用 [Tests](../Tests/README.md) 的 Swift；模型/提示词多用例实验归 [experiments](../experiments/README.md)。

## resources：App 构建资源

| 文件 | 职责 |
| --- | --- |
| [clean-app-models.sh](resources/clean-app-models.sh) | Scheme 预构建清理生成的 App 模型/旧资源 bundle；拒绝源目录 |
| [stage-voice-models.sh](resources/stage-voice-models.sh) | Xcode 打包 model-catalog 与许可，不嵌入权重；保留既有构建阶段名称 |
| [update-model-filelists.py](resources/update-model-filelists.py) | 重建 Config 的 sandbox 输入/输出清单 |
| [select-app-icon.sh](resources/select-app-icon.sh) | 显式选择已保存图标：original / robot-camera / lamp-arm / eyes-wink |
| [verify-app-agent-resources.py](resources/verify-app-agent-resources.py) | 最终 Bundle 的 Agent Catalog、资源集合与源字节一致性 |
| [verify-app-island-resources.py](resources/verify-app-island-resources.py) | Live Activity 扩展、版本、返回 URL 与打包契约 |
| [verify-app-localizations.py](resources/verify-app-localizations.py) | App、UI 包与扩展的已编译本地化资源 |

三个 verify 脚本各接收一个 App 路径，由 build-ios.sh 统一调用。构建脚本依赖 Xcode 环境变量，不独立执行 stage/clean。资源设计见 [Resources](../MobileHarness/Resources/README.md)。

## models：制品与原生适配检查

| 文件 | 职责 |
| --- | --- |
| [model_download.py](models/model_download.py) | 统一下载入口：d3-edge / gemma4-e2b / nemotron / silero / moss-tts-nano / yolo26-pose；保留 --platform、--force、--endpoint |
| [test-gemma4.sh](models/test-gemma4.sh) | Gemma 工程测试；HARNESS_TEST_GEMMA4=1 才启用真实推理，默认 Models/Gemma4 |
| [test-nemotron.sh](models/test-nemotron.sh) | 合成英/中文音频的真实 ASR 适配验收 |
| [test-silero.sh](models/test-silero.sh) | 合成音频的真实 VAD 适配验收；可显式开启 Nemotron 联测 |
| [test-kokoro.sh](models/test-kokoro.sh) | 合成文本的真实 TTS 适配验收 |
| [speech-fixture.sh](models/speech-fixture.sh) | Nemotron/Silero 共用合成英文 WAV 生成函数，不是独立入口 |
| [app_binary_parity.py](models/app_binary_parity.py) | 三条 Swift Vela 读数与原始 Python adapter 对照 |
| [laya_parity.py](models/laya_parity.py) | 三条 Laya 原始参考的 tokenizer/graph/readout 对照 |
| [vela31_parity.py](models/vela31_parity.py) | 三条 Vela 3.1 原始参考对照；显式 --reference、--output |

例如：`python3 scripts/models/model_download.py gemma4-e2b --platform macos`。下载器复用生产 catalog / Mac profile，四个下载工作者、有界路径、hash/大小校验与原子替换；默认复用制品，--force 显式刷新。App 在线模型管理仍由 ModelKit 拥有。原生对照工具使用本目录独立参考适配器，需要相应模型与 Python SDK；不加入默认离线检查。研究运行器回归由 experiments 独立维护和运行。

## simulator：原生 UI 验收

| 文件 | 职责 |
| --- | --- |
| [test-composition.sh](simulator/test-composition.sh) | 生产 App 装配、设置请求与生命周期闭环；专用模拟器、独立构建产物 |
| [test-webkit-simulator.sh](simulator/test-webkit-simulator.sh) | 编译 Tests/UI/Window 的最小 WebKit App，安装到 WEBKIT_SIMULATOR_ID（默认 booted），55秒内读取结果 |
| [test-writer-records-simulator.sh](simulator/test-writer-records-simulator.sh) | 用合成 SQLite/workspace 夹具验证 Writer 原生记录界面，保留 xcresult 截图 |

Writer 验收要求 WRITER_SIMULATOR_ID 和 WRITER_SIMULATOR_SEED；拒绝覆盖已有数据库。可用 WRITER_UI_ONLY_TEST 选择用例，MOBILEHARNESS_SIMULATOR_APP 指定 App。仅针对隔离模拟器，不操作物理设备数据。

检查结果与真实模型、原生 UI、物理设备验收分别记录在 [docs/validation](../docs/validation/README.md)。历史测量 JSON 保留当时路径，不作为当前命令入口。

[test-composition.sh](simulator/test-composition.sh) 在运行时支持的全新 iPhone Simulator 中验证真实 App 装配、设置请求和停止契约，180秒无结果即失败，退出时删除该专用模拟器。构建仅启用 APP_COMPOSITION_ACCEPTANCE 入口，不更改正常 App 启动逻辑；独立产物默认保留在 build/CompositionAcceptanceDerivedData，可用 MOBILEHARNESS_COMPOSITION_DERIVED_DATA 覆盖，不替换 build-ios.sh 的普通 App；结果为该目录的 composition-acceptance.json。

生产装配验收与 check.sh 分开运行；新模拟器首次初始化会产生明显负载。工程回归、构建和 Simulator 运行各自保留结果，不把超时或跳过记录为通过。

模型工程参考检查使用 scripts/models 自有适配器与清单，不导入实验代码或数据。laya_artifact_adapter.py 和 laya-model.json 分别拥有 Laya 工程参考读出与固定制品描述。

本目录是 agent 执行工程测试或模型实验的编排层。批量入口只选择任务、传参、控制执行和汇总状态；测试断言归 Tests，实验提示词/评分/数据归 experiments。两者不导入 scripts 作为共享业务库。当前具体入口以上表为准；尚无统一实验批处理命令时直接调用任务入口，不虚构命令。
