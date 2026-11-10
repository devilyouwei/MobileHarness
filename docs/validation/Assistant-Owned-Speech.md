# Assistant 内聚语音合成验证

日期：2026-11-10。分支：`codex/assistant-owned-speech`；基线提交 `d9069aa6` 加本轮工作树改动。工具链为完整 Xcode、Apple Swift 6.4、iPhoneSimulator 27.0 SDK。

## 范围与实现

对应[需求与实施计划](../requirements/technical/Assistant-Owned-Speech.md)。Assistant 直接预留音频并调度内部 FIFO 合成，播放继续由 Action/Gateway 执行；删除独立 SpeechSynthesis 角色、通信授权、容器和资源。生产器拥有有界活句柄关联，按 session/input 清理，停止等待底层推理完成。

[实现契约](../../MobileHarness/Agents/Assistant/README.md#语音生产与播放)描述当前所有权、容量和失败语义。本轮没有实现全双工、多源收件箱或小模型判断。

## 自动化与构建

| 检查 | 结果与边界 |
| --- | --- |
| 定向 Swift 测试 | 语音/Action/Writer 相关定向回归通过。 |
| `./scripts/check.sh` | 最终完整复验退出 0；边界检查、Python 下载器测试、Swift 格式、Swift 测试两阶段及 plist 校验通过。主要 IntegrationTests 阶段报告 1112 项，LiveRuntimeTests 阶段报告 229 项；各阶段 opt-in 跳过项按下述边界单列，不算真实模型/设备验收。 |
| `./scripts/build-ios.sh` | 退出 0；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标均 BUILD SUCCEEDED，Agent 与 Island 打包资源检查通过。 |
| 主应用增量复核 | 去掉一处 iOS 装配代码中多余的 await 后，再次构建 MobileHarnessSimulator 并运行两项打包资源检查，退出 0；未增加异步生命周期行为。 |
| 文档与差异 | 新增/修改的 Markdown 本地链接目标有效，`git diff --check` 通过。历史摘录中的旧相对路径不作为当前路径；未改写原始历史证据。 |

本机详细输出：`/tmp/mobileharness-speech-check-final.log`、`/tmp/mobileharness-speech-ios-final.log`、`/tmp/mobileharness-speech-ios-confirm.log`。这些是本次本机运行日志，不是仓库内长期制品。

已执行的定向回归覆盖：FIFO 合成与播放独立、流式播放、Action 调度不等待整段合成、真实错误传播、Writer 通知使用 Assistant 语音、Assistant 身份展示。补充回归覆盖：错误 input 无权取消句柄、缓存满载拒绝、同 inputID 跨会话隔离、生产器自身 32 项容量、停止加入 provider cleanup 并退休排队音频。

这些测试使用合成模型/音频替身与真实生产调度、缓存、Gateway/Action 组件；不是模型质量或物理设备验证。

## 过程中的环境限制

初次直接使用默认 Command Line Tools 构建时，因缺少 `metal` 工具失败。后续选择 `/Applications/Xcode.app/Contents/Developer`；仓库检查及 iOS 构建脚本会自动选择完整 Xcode。记录该工具链失败，不将它描述成代码测试通过。

## 独立验收边界

- 未开启需要模型制品、凭据或硬件许可的 opt-in 测试；测试运行内显式 skipped 的项目不算验收通过。
- 未进行真实 TTS 模型效果、iPhone 麦克风/扬声器、连续说话/打断或长时间运行测试。
- iOS 构建是模拟器目标编译及资源校验，不等于安装、原生 UI 或真机验收。实际语音复验使用[语音验收指南](Voice.md)。

## 2026-11-10 真机交付

本次语音内聚改动随 0.1.0（2026111005）原位安装到 iPhone 17 Pro，并成功启动；签名、打包和版本核对见[安装证据](Agent-Categories.md#2026-11-10-真机安装)。安装不替代上列语音、打断和持续运行验收。
