# experiments 命名统一

沿用现有 PascalCase 任务/职责目录：Assistant、Decision、Writer、Vision、Benchmark、Datasets、Results，不新建目录。Python 文件统一 snake_case；Shell、JSON/CSV 统一小写 kebab-case；Swift 使用 PascalCase，评估入口统一以 EvaluationTests 结尾，辅助实现按职责命名。保留 Package.swift、Package.resolved、README.md、requirements.txt 标准名称。

改正迁移结果的大小写、数据文件混用下划线、Python 入口使用连字符及泛化 cases/fixtures 命名。历史文件已有日期、模型和运行批次标识保留，不推测缺失日期；新结果采用主题-模型或变体-日期-可选批次命名。历史数据只改文件名，不修改内容及内部历史路径/哈希。

同步运行器、Swift 资源读取、Package/Xcode 文件成员、测试工具和全仓文档引用。编译 target、测试函数、环境 gate、评估行为不改，不进行 Python 语言迁移。检查全部数据哈希、命名规则、引用、Python 工具回归、完整 check.sh 和 iOS 构建。

已完成，见[验证记录](../validation/Experiment-Naming.md)。
