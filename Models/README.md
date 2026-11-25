# Shared local model artifacts

本目录按模型保存供 experiments 和 Tests 共用的本地制品：D3Edge、Gemma4、Nemotron、Silero、MossTTSNano、YOLOPose、Qwen2.5-1.5B。各模型目录由下载器按固定版本提供；权重、tokenizer 和编译产物不提交 Git。运行环境、缓存及报告不放这里。

Decision Python runner 从仓库根 Models 读取制品；scripts/models/model_download.py 的全部 profile 均输出到 Models/<模型名>；MobileHarness/Resources/Models 已移除，不得重建。Tests 可通过既有显式资源环境变量指向这些目录。App 的生产资源 catalog、安装管理和 iOS 部署仍由原模块拥有。

Tests 与 experiments 完全独立：不互相导入代码，不读取对方的数据、配置、提示词或结果，也不共用项目辅助库。允许重复实现；唯一共享内容是 Models 中按来源、版本和校验和约定下载的模型制品。

模型从 Hugging Face 或其他明确 URL 下载到 Models/<模型名>/；已存在且校验通过的制品直接复用，双方不另存一份。此目录不放双方共享的业务代码、测试夹具或评估逻辑。

ZipformerKWS 按 Hugging Face 提交存放原生 Core ML 制品及随发布版提供的运行资产。
[Decision 回放入口](../experiments/decision/README.md#zipformer-打断口令回放)拥有下载和
校验流程，固定文件见[实验配置](../experiments/decision/zipformer-coreml-model.json)。
