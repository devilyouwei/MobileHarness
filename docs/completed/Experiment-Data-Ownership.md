# 实验数据职责整理

将 docs/measurements 与 docs/validation 中的 JSON/CSV 原始结果按任务移入 experiments/assistant/results、Decision/Results、Writer/Results。Results 保存历史输出、请求轨迹、运行环境和工程验收原始证据；不是训练/评估输入集，不因位置变化把工程验收改称模型效果实验。Datasets 保存独立输入，任务根保存入口和配置。报告引用的截图保留为文档附件。

同步代码读写路径、报告链接、README、贡献规则和项目导航。历史 JSON/CSV 内容与哈希不改，内部历史路径解释为当时的来源记录；活动入口不再依赖 docs 数据。历史 readout 必须验证冻结输入，不再要求当前源码匹配已过期的历史路径，保留原始来源证据并记录当前 runner 哈希。Swift 入口及编译边界保留，Python 统一迁移等待用户另行确认。

验证迁移前后哈希、docs 无 JSON/CSV/脚本、链接与活动路径、完整工程检查和 iOS 构建。结果在 docs/validation 记录。

已完成。实际迁移与检查结果见[验证记录](../validation/Experiment-Data-Ownership.md)。
