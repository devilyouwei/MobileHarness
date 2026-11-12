# 网页当前截图 State 验证

日期：2026-11-12。环境：macOS、Xcode 27 / Swift 6.4。工作区同时包含此前 cognition 提示词归属调整，未提交。

## 行为与边界

网页 browse/snapshot/navigate 更新 Actions.Web 单槽内存截图；WebBrowsing 选择 actions.web.screenshot，通过相机已有的多模态 State/共享 Chat 路径附入当前请求。inspect 不捕获。新图替换旧图，窗口/页面失效清除；无历史截图列表、加载接口或 MediaStore 保存。Action 反馈保留文本与 screenshotID，Assistant 专用 Web 图片回查和 Camera readPhoto 桥接已删除。

完整模型请求日志仍保留实际提交的图片，与相机一致；该日志不用于重建当前 State 或自动向后续模型请求追加历史图片。Actions 不依赖 Resources。

## 自动验证

- 首批定向测试 7 项通过：Web 查询/多窗口、单槽替换、scope 隔离、窗口失效、准备失败、取消加入与 JPEG 压缩。日志：`/tmp/mh-web-state-focused.log`。
- 完整检查的 AppWorkflowTests 194 项通过，包含新增 State → ChatRequest 投影与页面变化后迟到图拒绝；生产 State、Skill 和请求构建被实际调用，页面使用替身，不代表真实模型或 WebKit。
- `scripts/check.sh` 的 IntegrationTests 第一阶段 1150 项中，只有既有 NexArm `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 时序断言失败；本次未修改该实现或测试。边界检查、Python 7 项检查和 Swift 格式检查通过。LiveRuntimeTests 229 项通过，plutil 全部通过；NativePresentationTests 全组没有完整终态，不能宣称全组通过。完整脚本退出码 1。日志：`/tmp/mh-web-state-check.log`。
- 第一次 iOS 构建暴露 Actions 诊断 reader 的 MainActor 跨隔离访问缺少 await，已修正，重新执行全部四个 scheme。修正后 MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 全部构建成功，52 个 Agent/Skill 资源及 Live Activity 校验通过。日志：`/tmp/mh-web-state-ios-build-fixed.log`。

- 最终串行定向复跑 8 项通过：7 项网页截图/压缩/State 投影回归，加上上述 NexArm 时序失败用例。完整并发检查的失败仍保留，不以单独复跑覆盖。日志：`/tmp/mh-web-state-final-focused.log`。
- 已清理旧生产符号，Resources JSON 全部解析成功，相关文档链接和 `git diff --check` 通过。

## 原生与设备边界

WebPageTests 新增 snapshotIdentity 在未挂载、导航、缩放、不可用状态下的断言。`webNativeLoadsLocalJavaScriptAndCapturesVisiblePixels` 单独运行通过（真实 macOS WebKit 加载、截图与身份断言，0.775 秒，退出码 0）；日志：`/tmp/mh-web-state-native.log`。此结果不代表整个 NativePresentationTests 套件通过。

上述自动验证阶段没有调用真实模型或安装本次 State 版本；当时设备上的 2026111109 是提示词资源版本。后续安装记录见下文。iOS 实际网页滚动、缩放、截图视觉内容与新用户轮次实模理解仍需真机验收。网页异步 DOM 变化不连续监听，当前 State 代表最近成功捕获且尚未被检测到失效的画面。

## 2026-11-12 真机安装

用户明确要求安装后，以当前工作区构建 MobileHarness 真机 Debug 版本 `0.1.0 (2026111201)`。版本号仅通过构建参数指定，没有修改工程签名或版本设置。签名构建、深层严格签名校验、52 个 Agent/Skill 资源和 Live Activity 打包检查通过。

已覆盖安装到 iPhone 17 Pro，设备应用清单确认版本 `2026111201`，安装序号 6704；CoreDevice 返回启动成功。本版包含网页单张当前截图 State 和此前 cognition 提示词资源迁移；Writer 的 render 截图仍保留独立工具反馈链路，本次没有修改 Writer 图片机制。

日志：`/tmp/mh-web-state-device-{build,signature,install,launch}.log`；设备回执：`/tmp/mh-web-state-device-{before,install,version,launch}.json`。本次验证覆盖构建、安装及系统启动回执，不代表真实模型图片理解或完整真机交互验收。
