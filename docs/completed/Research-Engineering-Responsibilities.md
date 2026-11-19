# Research / Engineering 职责修正

Tests 可显式调用真实模型，以个位数请求验证通信、单次 Assistant 请求、Writer delegate 和模块链路；跨 case、跨模型、提示词/性能对照归 experiments。允许重复代码，按验证目的而非技术或模型调用与否归属。

将 Assistant Python 单元测试、Swift schema/评分/解析/指标回归、Writer 无模型 WebKit/窗口验证移入现有 Tests 所属目录，保持 target 与依赖。增加两个 opt-in 单任务模型 smoke 入口，单模型、请求上限不超过8、显式清理及失败，不启用收费运行。共用测试 target 内的 harness 不形成生产 API。

将四个 Decision parity 工程脚本及两份适配器/tokenizer 夹具迁入 Tests/ModelKit/Management/Defaults，修正引用和导入；共享的实验加载器属于测试对象，数值一致性验证归工程测试。实验运行配置移出 Datasets，修复 Writer scenarioFile。实验模板与独立原始 case 归任务目录；抽取历史报告中的现用输入快照，报告继续保留原字节。将静态代码中的研究 case/提示词常量外置为任务数据，动态生成算法保留代码。

docs 中尚在使用的人工验收用例迁到 Tests 或 experiments 的现有目录，报告仅保留结果、限制和用例链接；日期明确的历史执行预期保留证据，不改写原始 JSON。更新根贡献规则、所属 README、SwiftPM/Xcode/Python检查入口。

验证迁移前后测试标识与依赖、数据语义、路径、Python离线回归、格式、完整check与iOS构建；不运行真实模型/设备验收，保留业务失败事实。

## 完成记录

职责迁移、少量真实模型smoke入口、评估集与模板/配置拆分、文档清理均已完成。最终执行结果与全量检查失败见 [验证记录](../validation/Research-Engineering-Responsibilities.md)。真实模型smoke与物理设备验收本次未执行。
