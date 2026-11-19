# experiments

实验开发与执行规则见 [AGENTS.md](AGENTS.md)，开始工作前必读。

Research 的纯 Python 工作区：运行模型 case、提示词对照、准确率与性能评估。不得编译/启动 App 或 Swift 测试；App 模型管理、部署、适配器及业务链路验证归 [Tests](../Tests/README.md)。

| 任务 | 入口与职责 |
| --- | --- |
| [Assistant](assistant/README.md) | 提示词、模型指令与合成动作反馈 |
| [Decision](decision/README.md) | 分类、布尔判断、多问题与多模型对照 |
| [Writer](writer/README.md) | 写作、文件内容与合成工作区操作 |
| [Vision](vision/README.md) | 图片 case 的 Core ML 推理和计时 |

- 任务根：Python 入口、评分逻辑、配置和提示词。`datasets/`：原始 case、标签和冻结请求。`results/`：逐条输出、指标、请求轨迹和环境快照。
- `utils/runtime.py`：云端/Apple/Core AI 文本调用、有界运行和结果写入；`coreai_decoder.py`：Core AI 逐 token 解码与每请求独立状态。
- [Models](../Models/README.md)：按模型保存共享制品；不自动下载。docs 只保存方法、结论和文档附件。
- 云端配置使用 [model-config-example.json](model-config-example.json)，凭据只通过配置指定的环境变量读取；配置/报告不保存密钥。所有入口从仓库根运行，`--help` 不加载模型。
- 依赖见 [requirements.txt](requirements.txt)，按后端选装。Core AI 使用 Apple `coreai-core`；Core ML 使用 `coremltools`；系统模型使用 `apple-fm-sdk`；浏览器评审选装 Playwright 和 Chromium。Vela 3.1 使用已安装的 Hugging Mac Python SDK，Laya 使用本地制品固定的 Python wheel，版本/哈希由 benchmark 制品清单约束。
- 输出必须是新文件，逐 case 写入；超时/解析/模型失败计入结果。输入与配置哈希随报告保存，标准答案不传入模型。真实模型调用仅在显式运行入口时发生。

新 Python 模型实验与历史 Swift/App 全链路实验分开解释。旧 JSON/CSV 内的来源路径、哈希、失败和指标不改；不能把本次迁移当作旧效果或速度结论的复现。

## 命名规则

目录统一使用小写 snake_case，沿用任务与职责布局。Python 使用 `snake_case.py`，配置、数据与结果使用小写 `kebab-case`；主题、模型/变体、日期、批次可用于结果命名。历史日期保留，不推测缺失信息。`README.md`、`requirements.txt` 为标准名称。实验目录不放 Swift、Shell 或 SwiftPM 清单。

研究运行器离线检查独立运行：`python3 -m unittest discover -s experiments -p "test_*.py"`；不代替真实模型评估，也不要求运行 Tests。

接口参考：[Apple Core AI Python](https://apple.github.io/coreai-torch/main/coreai-core/)、[Core ML预测](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)、[Apple Foundation Models Python](https://apple.github.io/python-apple-fm-sdk/basic_usage.html)。依赖清单固定直接版本；浏览器安装命令为 `python -m playwright install chromium`。

Tests 与 experiments 完全独立：不互相导入代码，不读取对方的数据、配置、提示词或结果，也不共用项目辅助库。允许重复实现；唯一共享内容是 Models 中按来源、版本和校验和约定下载的模型制品。

Local model experiments use Apple Core AI / Core ML artifacts through Python interfaces. Research evaluates model behavior; App business flows and Swift adapter correctness belong in Tests. Explicit cloud/system-model backends remain Python-only.

Python 代码目录包含 `__init__.py`；数据目录不作为包。任务入口仍可直接执行，所有离线回归统一运行 `python3 -m unittest discover -s experiments -p "test_*.py"`。
