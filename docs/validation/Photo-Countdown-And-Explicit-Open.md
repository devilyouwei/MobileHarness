# 拍照倒计时与显式打开验证

日期：2026-11-12。范围见[需求与方案](../requirements/technical/Photo-Countdown-And-Explicit-Open.md)。

## 检查内容

- CameraEnhancementTests：可选倒计时 nil/0/3/30、非法/越界参数在完整 invocation 准备与执行前被拒绝、typed endpoint 转发、拍照不隐式打开/配置/重试、原有录像内部组合、单调倒计时及取消清理。
- GenerationRoundTests：脚本模型一次生成 open → wait 内话术 → takePhoto；预览就绪信号之前不拍照、不启动中间模型续轮；打开失败后保留真实失败，不产生快门或自动重试。
- PromptTemplateTests：解析打包的 Photography 示例、检查相机和话术顺序、同 Camera Channel 多 Action、倒计时参数，以及既有提示词预算。AgentTaskSkillTests 检查多 Skill 同时加载容量。
- `./scripts/check.sh`：边界、Python、Swift 格式、测试与配置检查。
- `./scripts/build-ios.sh`：Xcode 27.0 的四个 Simulator scheme 与打包资源校验。

## 验证过程

首轮检查发现旧教程测试仍禁止同轮 open/takePhoto，新增说明超过提示词预算；已更新断言并精简重复说明，保持预算限制。参数范围测试改为调用含领域校验的完整 invocation 接口，而非只校验传输形状的 FunctionRequest 接口。预览等待测试改用明确的开启信号，移除全量并发下两秒轮询的竞争。

首轮全量还出现独立的 NexArmAimTests.slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 目标值断言失败；保留记录，最终复验结果另列。首轮 Simulator 主应用编译成功，但修改教程期间资源校验报告旧 Photography 资产，因此重新运行完整构建。

## 最终结果

- 11 项专项测试通过（含参数化边界用例）；Photography 提示词 37,210 UTF-8 字节，小于既有 38,000 字节预算，多 Skill 容量检查通过。
- `./scripts/build-ios.sh` 退出 0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标成功；52 个 Agent/Skill 资产及 Live Activity 资源校验通过。
- 最终 `./scripts/check.sh` 的边界/Python/格式检查通过；IntegrationTests 1158 项全量运行只有 NexArmAimTests.swift:812 的上述目标值断言失败，相机新增及更新测试均通过。串行 LiveRuntimeTests 229 项通过（207.083 秒），配置 plutil 校验通过，脚本最终退出 1。NativePresentationTests 前两项通过，但日志只记录 cameraNativeMetalDrawStopAndLayerHandoff 开始、没有该项或该 suite 的完成结果，因此不将原生渲染检查描述为通过。
- 同一已编译 IntegrationTests 二进制经 SwiftPM testing helper 单独复跑机械臂失败项：1 项通过（0.039 秒）。直接运行器最初缺少 XCTest 动态库路径，未执行测试；补齐 Xcode 的 framework/library 路径后才得到此通过结果。单独通过不能覆盖全量失败，不在本次相机变更中修改机械臂实现。
- `git diff --check` 及受影响路径/现行设计描述检查通过。

## 证据边界

脚本模型与相机替身只验证参数、解析、调度、反馈和清理契约，不证明真实模型遵循教学。尚未执行真实模型、原生相机 UI 或物理设备验收。设备验收需覆盖关闭/最小化/遮挡相机、打开后话术与快门顺序、3 秒倒计时、0 秒覆盖、取消/后台无延迟快门、以及下一次拍摄仍使用原有设置。
