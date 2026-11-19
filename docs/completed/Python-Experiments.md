# 纯 Python 实验

experiments 的模型 case、提示词、评分、性能测量全部由 Python 执行，不编译或启动 Swift/App。复用已有 Decision CoreAI Python 路径，补全原生 choice/boolean、生成模型、Apple Foundation Models 和 Core ML Python 调用。Assistant/Writer 直接调用模型，以实验输入/提示词/合成工具反馈验证模型；不把 App 运行链路冒充模型评估。

任务目录保持现有布局：各任务入口和评分脚本、Datasets 输入、Results 原始结果；Decision/Benchmark 保留既有对照工具。根目录仅放跨任务 Python 运行/结果基础机制与依赖说明，不增加目录。Python snake_case，配置/数据 kebab-case。删除 experiments Swift、Shell、SwiftPM 包和 Swift 构建缓存，根 Package/Xcode 不再编译实验源。

Tests 当前依赖的 Assistant/Writer 原生通信、渲染辅助机制移入既有所属目录，只供工程测试；删除多 case 真实模型评估入口。Decision 的纯评分/fixture回归转为 Python 工具测试，不保留历史 App 调度器副本。性能 case 改为 Python 模型输入/推理计时，Swift 实现特有的工程性能对照不伪称同一个 Python 测量。

保留历史数据及SHA-256；新结果明确Python执行范围，不能与旧Swift/App全链路耗时混算。报告所有case失败，校验参数/路径，限制请求轮数和超时，输出不覆盖。凭据仅按显式配置读取，不进行付费或未授权的模型实验。验证离线评分、失败/边界与运行器行为、全部入口help、静态纯Python约束、完整工程测试及iOS构建。

补充验证：完整工程检查和iOS构建结束后，使用已有本地D3/Vela3/Vela3.1/Laya制品，各运行一个Python布尔case（无下载、无云端调用），验证新原生路径。分类结果与运行器/传输成功分别记录。缺失的Gemma制品、Apple SDK及浏览器依赖不得宣称已实测。

本地验证修正：Transformers 5 的 apply_chat_template 默认返回 BatchEncoding；D3和通用Core AI调用改为显式先渲染模板，再encode为token列表，避免将映射作为token序列。使用实际本地tokenizer及模型case复验。

实现完成，检查与本地小样本验证见[验证记录](../validation/Python-Experiments.md)；缺失依赖/制品的真实模型验收范围在该记录明确列出。
