# Channel 覆盖与照片忽略删除验证

日期：2026-11-09。

## 范围

需求与文件归属见 [实施方案](../completed/Remove-Channel-Override-And-Photo-Ignore.md)。本次保留正常 Channel FIFO、wait、照片保存和独立视频忽略；删除模型 Channel 覆盖、照片忽略及其专用 discard 提示音。

## 残留审计

- 检查 MobileHarness、Config、scripts、Xcode 工程、Tests 的源代码、JSON、教学和 README。生产代码及资源无 ignorePhoto/discardPhoto、ChannelParser、channel.NAME 作用域、覆盖参数或旧状态兼容分支。
- 缓存仅有 pending/saved；照片回执仅有 saved。重拍直接捕获，旧原图及已显式选择的图片按会话/FIFO规则保留；关闭清空。
- Tests 中旧名字只用于拒绝回归。历史 docs/adr、completed、history、validation、measurements 及原始设计、output 实验材料保留当时证据；Native-Media-Failure-Diagnosis 的历史聊天引用不代表当前能力。
- 静态模型场景教学已移除覆盖语法，照片流程改为保存、关闭清空、同 Task 直接重拍。未运行真实模型评估。

## 自动化与构建

- 初次直接 swift test 使用 CommandLineTools，因缺少 metal 编译器失败；后续改用仓库脚本选择的完整 Xcode 工具链。
- 模块边界检查通过；工程 plist 和 git diff --check 通过。
- 初次专项 Swift 回归：42项、5项测试组通过；139项集成组中一处嵌套 wait 的预期 Channel 数组写错位置，已修正。重拍旧图可读取、旧照片动作拒绝等新增回归通过。
- 首轮 ./scripts/check.sh：边界、6项Python测试、格式、plist及228项独立运行时测试通过；普通集成组1104项中有两项失败。旧提示教学字符串断言已同步为注册 Channel；未修改的 slowTrackingDispatchExecutesOnlyTheNewestPendingTarget 出现数值时序失败。
- 对上述两个修正断言和跟踪测试进行单独复核，3项全部通过；跟踪测试未修改生产代码或测试。最终 ./scripts/check.sh 复跑退出0：全部普通测试组通过（含1104项集成与175项应用流程测试），独立运行时阶段228项通过；边界、6项Python测试、严格格式与plist检查通过。无新增失败。
- ./scripts/build-ios.sh 退出0；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标全部 BUILD SUCCEEDED。应用的30项Skill资源/Core协议以及Live Activity打包检查通过。

## 验收边界

缓存、解析、目录、请求及 UI 控制的自动化回归使用本地替身与生产机制。真实模型、原生相机操作及界面交互仍待验收。

## 真机安装

2026-11-09 按用户要求使用现有本地签名构建 MobileHarness Debug `2026110902`。签名、30 项 Agent/Skill 资源、Core 协议及 Live Activity 打包校验通过。已原位更新 Youwei 的 iPhone 17 Pro，保留 App 数据。安装回执序号为 6400，设备应用清单确认版本为 `0.1.0 (2026110902)`。证据保存在 `/tmp/mh-removals-2026110902-device-build.log`、`/tmp/mh-removals-2026110902-install.json` 和 `/tmp/mh-removals-2026110902-installed.json`。
