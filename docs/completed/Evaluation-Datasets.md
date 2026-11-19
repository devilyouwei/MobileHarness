# 按任务归属评估集与共享制品

用户明确要求 experiments 按任务/业务组织。原始集放 experiments/assistant/datasets、Decision/Datasets、Writer/Datasets；现有 Scenarios 的输入按任务归入。Decision Benchmark fixtures 同归 Decision/Datasets。文件字节与哈希不变，测量输出仍归 docs/measurements。

纯模型评估保留/优先 Python；已有 Swift 仅保留必须使用 App 实际链路及原生推理的入口，不为目录迁移重写 SDK。模型制品集中根 Models，按 D3Edge/LayaMultilingual/Vela31Fast/Vela3Fast/Gemma4 分目录，实验和 Tests 可共享。只迁移本地评估权重并调整路径，App 生产 catalog/部署契约保持原职责。缓存、环境与运行输出不混入制品目录。

更新动态与固定路径、资源复制清单、Xcode 导航和相关 README；历史报告 JSON 的当时路径和哈希保留。验证哈希、链接、路径解析、Python离线回归、Swift格式、完整检查及iOS构建。

迁移完成，设计入口为 [experiments](../../experiments/README.md) 和 [Models](../../Models/README.md)。执行结果与限制见 [验证记录](../validation/Evaluation-Datasets.md)。
