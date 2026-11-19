# 实验与评估目录迁移验证

日期：2026-11-18。experiments 只拥有 case 评估、提示词/业务用例对照和性能测量。App 模型管理、部署、适配器与推理链路（包括真实模型验收）留在 Tests/ModelKit。生产 Swift 行为未改动。

## 静态核对

- 已撤回误拆的 17 个模型链路用例，11 份 SDK 测试源码恢复此次迁移前内容。Gemma 下载 profile、本地制品和四个模型检查 shell 恢复原归属。
- 仅从 D3 混合文件拆出业务 case 预测评估；原生制品验收与超长输入拒绝仍在 Tests。原评估目录中的适配器一致性、权重边界测试也归回 Tests/ModelKit。
- `swift test list --skip-build` 退出 0，2116 个测试标识与前次目录整理后的发现清单完全一致。
- 18 个测试 target 的身份、依赖、测试函数、环境 gate 保持；184 个 Swift 源文件唯一归属，生产 target 清单不变。
- 17 个 Python 离线用例通过；Qwen、Writer、Decision benchmark 的 CLI 帮助可执行。
- Xcode 305 个 Tests/experiments 文件引用全部存在；Markdown 本地链接与 Python 语法核对通过。
- 历史测量 JSON、源码 hash 与原始 Word 不改写；本地制品和缓存继续忽略。

## 执行验证

扩大范围时启动的完整检查与 iOS 构建已主动中止，不计为通过。纠正后的最终范围重新执行结果：

- `scripts/build-ios.sh` 退出 0，5 个 Simulator scheme 全部构建成功。
- `scripts/check.sh` 的边界、17 个 Python 离线用例和严格 Swift 格式检查通过；Swift 编译完成。
- 普通 IntegrationTests：1198 个测试、4 个 issue，复现 3 个英文提示词断言和 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 的时序断言失败。
- AppWorkflowTests：21 个失败测试声明，主要为缺少 injected Action declarations，另有模型列表预期不匹配。writerCancellationDuringBackoffDoesNotStartAnotherRequest 在任务失败后无截止等待首个模型请求；子进程约运行两分半仍未结束，显式 SIGTERM 后主检查继续。此阶段未完整运行，不能标记通过。
- 上述失败相关源码及 App 测试共 26 份与此次迁移前快照逐字一致；与先前 [Tests 整理验证](Tests-Organization.md) 的失败相符。本次不修改业务断言或注入配置来掩盖失败。
- 串行 LiveRuntimeTests：228 个测试，soundSourceSlowSubscriberDoesNotBlockFollowingDirections 等待声源超时，1 个 issue；与先前记录相同。NativePresentationTests 没有完整 suite 汇总，不据此宣称原生 UI 验收通过。
- 最终五项 plist/project 校验通过；`scripts/check.sh` 退出 1，完整检查未通过。目录与编译迁移完成，上述独立业务失败仍需修复。

## 证据范围

不启用真实模型、云服务或设备 gate。离线回归与构建不代表模型能力、原生 UI 或设备验收。

最终日志：`/tmp/mh-experiments-final-check.log`、`/tmp/mh-experiments-final-ios.log`。这些是本机临时证据，核心结论保存在本文。

范围与归属见 [整理记录](../completed/Experiments-Organization.md)。

后续目录规则见 [实验数据职责整理](Experiment-Data-Ownership.md)：原始运行数据现归任务 Results，docs 仅保留文档及附件。以上迁移记录描述当时状态。
