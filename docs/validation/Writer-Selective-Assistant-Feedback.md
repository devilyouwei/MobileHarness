# Writer 精选事件播报验证

## 回归范围

- `writerFeedbackUpdatesAssistantStateWithoutModelTurns` 经 Gateway 送达认证事件。替身合成请求与受授权的播放动作各出现五次，覆盖接纳、草稿改动、恢复、追问和终态。重复递送保持一次播报，后续用户请求带入五条事实。前台任务组合另查验任务状态和模型请求计数。
- `writerBackgroundRoleUsesDirectGatewayAndPublishesActualArtifact` 验证真实 Writer 工作流和替身模型的配合，覆盖首批草稿写入、模型超时恢复和跨角色进度去重。逐轮进度仍由 Writer 本地呈现。
- iOS Simulator 编译及资源校验与物理设备验收分别记录。真机实际合成、声音、音频路由与锁屏行为需要设备验证。

## 2026-11-10 验证记录

- Writer 定向回归通过。三个参数化测试分别覆盖 20 个 Assistant 回馈组合、15 个目标选择与收尾组合、15 个真实 Writer 工作流与替身模型组合。
- `./scripts/check.sh` 退出码为 1。通用 Swift 集成阶段运行 1109 项，有一项 NexArm 跟踪测试在并行运行时未通过。`slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 单独复跑通过。单独执行的运行时阶段通过 229 项，边界、格式和 plist 检查通过。
- `./scripts/build-ios.sh` 通过四个 iOS Simulator scheme，主应用的 Agent、Skill 和 Live Activity 资源校验通过。
- 真机语音、锁屏与真实模型交互本轮未执行。真机复验可从 [语音验收指南](Voice.md) 的设备检查开始。

## 2026-11-10 真机安装

- iPhone 17 Pro 原位更新至 Mobile Harness 0.1.0（2026111002）。设备构建、签名及 Agent、Skill 和 Live Activity 打包检查通过。设备应用清单确认新版，系统启动成功。
- 本次安装验证构建、安装与启动。实际播报和锁屏表现待设备验证。
