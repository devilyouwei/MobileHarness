# ModelKit 制品所有权与 D3 Lite 移除验证

日期：2026-11-17。

## 变更范围

- ModelKitRuntime 自带模型清单、磁盘制品存储和后台完成交接；Defaults 组合 Hub 下载器。App/Actions 不再注入 Storage 空间或构造模型存储适配器。
- ModelKit 提供自定义制品目录增改查删、安装/删除、HF 与 HTTPS 单文件/ZIP 下载、URL 续传数据及原生后台传输。
- D3 Lite 从生产注册、下载清单、模型选择、后端校验和可执行基准入口移除。历史测量数据未改写。
- 旧业务偏好移至 Settings；已有模型安装目录与收据格式保持。移除声明对应的旧传输取消并加入清理、显式报告，不自动切换模型或删除已安装权重。

## 自动化范围

ModelArtifactTests 覆盖临时磁盘安装/收据、篡改检测、路径穿越/符号链接、传输索引、清单加载/持久化/增改删、URL 文件发布、续传数据绑定与后台 completion 一次完成。退役传输恢复测试不访问网络。Defaults/Provider/UI 测试验证 D3 Lite 无注册、无页面候选、保存拒绝；偏好迁移测试验证字节保持和新位置优先。

## 执行记录

- 架构边界检查通过；新增防线禁止 Actions 中的模型存储适配器、App 注入模型目录以及 Storage.models 命名空间。
- Python 下载工具测试通过（8 项）。
- 修改文档的本地链接与 `git diff --check` 通过。
- `./scripts/check.sh` 已执行，未全通过。边界、Python、格式、plist 检查通过；首轮模型磁盘回归定位到 Foundation 目录 URL 标记以及 `/var` / `/private/var` 枚举别名，修正后专项复测通过。
- 最终模型专项命令：`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ModelKitRuntimeTests|ModelKitDefaultsTests|ModelKitHubTests|removedD3LiteSelection|modelPreferenceMigration|localLanguageModels'`，82 项测试定义中 76 项通过、6 项按条件跳过（Runtime 56、Defaults 19、Hub 5、Integration 2；跳过的是需外部模型／真实 Hub／系统模型条件的用例）。包含旧传输清理、目录 CRUD、续传绑定、真实临时文件、旧偏好搬迁与已移除选择拒绝。
- 全量其他失败：AppWorkflowTests 的 Writer/Web 用例缺少 `injected Action declarations`；`speechPreferencesRejectOldSwitchAndRoundTripCurrentFormat` 仍断言旧识别模型列表；机械臂 `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 首次失败，单独复测通过；LiveRuntimeTests 的 `soundSourceSlowSubscriberDoesNotBlockFollowingDirections` 等待声音感知超时。单独复测 `soundSourceSlowSubscriberDoesNotBlockFollowingDirections` 仍超时；独立 UI 回归 `localModelSettingsExposeOnlySupportedRoles` 通过。以上失败涉及的生产逻辑及对应旧断言未在本次修改。AppWorkflow 测试出现失败后停滞，终止该测试 helper 以继续后续检查，不能将该阶段记为通过。
- 最终代码的 `./scripts/build-ios.sh` 通过：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM 五个 scheme 均构建成功，App 的 Agent/Skill、Island 与本地化资源验证通过。

首轮直接使用 Command Line Tools 的 Swift 测试遇到 xcstrings 工具不可用；后续使用完整 Xcode。中间构建捕获并修正默认参数 Self 与 Sendable 闭包写法问题；接口修改期间的并发构建曾使用旧产物，删除 Lite 时还修正了基准测试中的残留匹配分支。最终结果以静止源码的复测为准。

## 证据限制

编译与替身/临时文件测试不等于真机验收。本次没有进行物理设备后台唤醒、锁屏后下载、系统杀进程后重新关联、真实 Hugging Face 下载或真实模型推理验收。URL 续传使用系统 resume data，服务器与 OS 条件决定能否恢复；不能保证用户强制退出后的传输继续。参见 [Apple 下载暂停与恢复文档](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads)。

## 启动依赖图核对

总体设计 Dependencies and startup 的 12 条就绪依赖边逐条对照 ModuleRegistration，通过；按 ApplicationLifecycle 的首个就绪节点算法推导当前串行启动顺序，与正文一致。相关源码链接和 diff 格式通过。本次补充仅修改文档，无需重跑构建。

## 真机安装

2026-11-17：MobileHarness 真机 scheme 的 Debug 签名构建通过；Live Activity 扩展通过构建参数复用主应用现有开发团队，未改写签名设置。签名、73 项 Agent/Skill 资源、Live Activity 及中英文资源检查通过。目标为 iPhone 17 Pro（iOS 27.0.1）。无线安装两次失败：首次 RemoteConnectError，刷新连接后仍出现远端 Connection interrupted。用户连接设备并解锁后，重试安装成功；设备应用列表确认 Mobile Harness，bundle ID 为 dev.mobileharness.app，版本 0.1.0（1）。仅执行覆盖安装并保留应用数据，未执行卸载。此次证据覆盖签名构建、资源校验和真机安装，不代表后台下载或模型推理功能验收。
