# 实验与评估独立目录

## 范围（按用户明确纠正）

experiments 仅承接 case 评估、提示词/业务用例对照和推理性能实验。App 自身模型的管理、部署、适配器、推理链路与原生能力验收留在 Tests/ModelKit；是否调用真实模型不是目录划分标准。

## 实施

- Tests/Agents/Evaluation 整体迁入 experiments 的 Assistant、Decision、Writer、Scenarios，独立 Decision Python/Swift benchmark 保留边界。
- Qwen、Writer、Decision 评估脚本随实验归属迁入；通用下载器、Gemma/Nemotron/Silero/Kokoro 原生链路启动脚本留在 scripts。Gemma Mac 下载配置与本地制品留在 Tests/ModelKit/Language/Gemma4。
- 撤回误拆出的 17 个模型链路测试，11 个 Tests/ModelKit 源文件恢复此次迁移前内容。删除对应 experiments/Models 推理测试与文档。
- YOLO 性能探针归 experiments/vision。D3NativeTests 混合文件仅拆出业务 case 评估；原生制品验收与超长输入拒绝仍归 Tests/ModelKit/Management/Defaults。
- 原评估目录中的 DecisionAdapterNativeTests 归 Tests/ModelKit/Management/Defaults，DecisionWeightArchiveTests 归 Tests/ModelKit/Core：它们验证适配器/tokenizer 一致性和权重边界，属于 App 模型链路。
- 保留测试 target、依赖、测试函数、gate、断言、资源 bundle；修正所有源码路径、执行入口、Xcode 导航与当前文档。历史证据不改写。

## 验证

先停止基于扩大范围启动的检查，再针对纠正后的最终文件执行静态成员/链接/资源验证、Python 离线回归、scripts/check.sh 与 scripts/build-ios.sh。验证记录区分通过、失败和中止，不启用真实模型/云服务 gate。

## 完成记录

最终目录与编译成员迁移完成，当前设计见 [experiments](../../experiments/README.md) 与 [Tests](../../Tests/README.md)。自动检查的通过项、既有失败及中止阶段见 [验证记录](../validation/Experiments-Organization.md)。这些独立业务失败不冒充本次迁移通过，也未通过改写断言掩盖。
