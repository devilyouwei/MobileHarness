# experiments 命名验证

2026-11-19。统一31个文件名：Python入口改为 snake_case，混合分隔符数据集和迁入的大写结果改为小写 kebab-case，Swift评估入口统一 EvaluationTests 后缀，渲染入口为 RenderWriterReview.swift；泛化输入名改为 assistant-prompt-cases.json 和 decision-benchmark-cases.json。

现有任务/职责目录保留 PascalCase，标准清单/README 名称不变。历史日期/运行批次不改，不补造缺失日期。完整规则见 [experiments](../../experiments/README.md#命名规则)。

- 220份 JSON/CSV 内容 SHA-256 不变；历史内部路径与哈希仍代表原运行。
- Python语法、文件命名规则及全仓涉及 experiments 的 Markdown 文件链接检查通过。
- Package资源读取、运行器、工具测试和 Xcode 导航已同步；target、测试函数、gate和评估行为保留。未迁移到纯Python。

`./scripts/check.sh` 返回0：18项Python工具测试、边界/格式检查、全部Swift target及项目/plist检查通过。普通IntegrationTests 1197项、AppWorkflowTests 198项、串行LiveRuntimeTests 231项通过。日志 `/tmp/mh-experiment-naming-check.log`。

`./scripts/build-ios.sh` 返回0，五个Simulator scheme及资源检查通过。日志 `/tmp/mh-experiment-naming-ios.log`。活动代码/工程无旧文件名引用，最终diff格式检查通过。本轮未运行真实模型或物理设备实验。
