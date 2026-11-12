# ASR 用户输入通行验证

2026-11-12。范围为 SpeechPerception 的片段及最终文本、Assistant 订阅、旧信号和字幕桥接清理、播放准入。见[变更计划](../requirements/technical/ASR-User-Input-Plan.md)。

## 回归覆盖

| 场景 | 验证 |
| --- | --- |
| 生产通行配置 | 两份 Agent.json 的 communication 与方案示例一致。Assistant 仅订阅 `user.input.asr.final`，SpeechPerception 发布片段、最终文本和声源。 |
| 广播与定向授权 | 共享 `user.input` 主题下按契约及可信来源路由。片段进入诊断观察，最终文本送达 Assistant。订阅本身无定向权限，错误主题和来源被拒绝。 |
| 任务与呈现 | 最终文本按接纳时任务归属。识别开启更新转写槽，回复开始更新回复槽，旧回复更新被拒绝。 |
| 收音与播放 | 两段连续语音均产生最终文本，ASR 失败后可接纳下一段。受限路线暂停及恢复识别，全双工保持准入，用户关闭后不会因恢复回调重新开启。 |
| 既有观察方 | 声源诊断使用观察专用会话和 `sound.source`，姿态继续使用 `vision.pose`。 |

## 检查与构建

- `./scripts/check.sh` 退出码为 0。静态边界、Swift 严格格式、7 项 Python 测试和 plist 校验通过。IntegrationTests 首阶段 1,146 项、AppWorkflowTests 193 项、LiveRuntimeTests 228 项通过。声源诊断和姿态路由用例通过。
- 首轮检查发现两处测试仍依赖已退役的配置和能力，更新了 Assistant 内部 Action 列表断言和声源独立会话断言。首轮出现的既有 NexArm 最新跟随目标断言在最终完整检查通过。
- NativePresentationTests 日志记录了两项通过和 `cameraNativeMetalDrawStopAndLayerHandoff` 开始，缺少该项及套件的完成记录。
- `./scripts/build-ios.sh` 退出码为 0。MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron 与 ModelKitSilero 模拟器目标均成功构建。包内 49 项 Agent 和 Skill 资源以及灵动岛扩展清单校验通过。
- 两份生产配置与方案逐项核对通过，`git diff --check` 通过。

本机日志为 `/tmp/mh-asr-final-check.log` 和 `/tmp/mh-asr-final-ios.log`。

识别、音频及决策用例使用受控能力。真实 ASR、物理麦克风、音频路由、原生界面及真机安装需要单独验收。
