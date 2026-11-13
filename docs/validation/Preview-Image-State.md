# 预览缓存与多模态 State 验证

日期：2026-11-06。环境：Apple Silicon macOS，Apple Swift 6.4，完整 Xcode 工具链。范围为临时照片缓存、图片选择、每次模型请求的 State 附件及保存／忽略生命周期；不包含真实模型视觉质量或 iPhone 拍摄体验验收。

## 行为证据

- `PhotoFeedbackTests` 使用实际 `CameraPreviewStore`、`PreviewImageCache` 与 `AgentStateContext`，图像准备和持久化使用可控替身：验证多轮保留、最新图替换、历史图选择、Skill 隐藏／恢复、新对话重置、容量拒绝、固定图保护、共享缓存预算、淘汰分析图和关闭释放。
- 同组测试验证保存之前不调用持久化；保存失败保留缓存；成功保存返回独立 mediaID 并清除选择；重复保存幂等；忽略清除缓存；准备失败保留原图，reset 围栏拒绝晚到的加载结果。
- `AgentTaskSkillTests` 通过真实共享 Chat Worker 捕获替身模型的请求，验证第二次用户输入仍带当前图且不再次拍照，支持／不支持图片的模型分别得到图片附件／明确不可分析说明。State 图片紧跟新鲜事实，不写入对话历史或破坏 Action 结果组。
- `AgentModelRequestRecording` 回归确认临时图片日志包含身份、大小与 SHA-256，不含图片 Base64；既有非临时 Web 图片策略保持独立。
- 既有 Camera／Photographer／AppWorkflow 测试覆盖 previewID 参数、UI 保存确认、提交后反馈失败和取消清理；这些替身测试不等于原生相机验收。

## 检查结果

- `./scripts/check.sh`：退出码 0。架构边界、资源检查、Python 测试、Swift 严格格式、Swift 测试和 plist 校验通过；其中主集成套件 1059 项、独立原生／时序阶段 227 项通过，脚本中的其他套件也通过。
- 最后补充 State 插入后的结果组保护与契约归位后，使用完整 Xcode 工具链定向复核 12 项测试通过；上下文裁剪覆盖有／无 State 图片两个分支。随后再次运行架构边界和全仓严格格式检查，均通过。
- `./scripts/build-ios.sh`：最终退出码 0；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个 scheme 均 `BUILD SUCCEEDED`，App 资源校验通过。
- 文档引用路径与 `git diff --check` 通过。没有新增目录、模块或第三方依赖。

本机原始日志为 `/tmp/preview-check-final.log`、`/tmp/preview-last-regression.log`、`/tmp/preview-ios-delivery.log`、`/tmp/preview-delivery-boundaries.log` 和 `/tmp/preview-delivery-format.log`；临时日志不作为持久仓库附件。

验证过程中修正了旧 mediaID 参数断言、缺少 preview State 的测试来源以及纯文本上下文位置断言。早期编译暴露的 actor 隔离、基础模块导入和 Xcode 文件登记问题已修复。一次直接使用 Command Line Tools 的定向测试因找不到 Metal 编译器未能构建；改用完整 Xcode 工具链后定向回归通过。第一次全量检查另出现机械臂 `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget` 时序断言失败，单独复核已通过，未修改机械臂实现。

## 未执行的独立验收

没有调用真实视觉模型，没有在 iPhone 上验证拍照、照片退场音效／动画或内存压力。建议原生验收连续拍摄两张后跨轮追问、加载旧图比较、保存非当前显示图、忽略当前图、切换新对话及后台／恢复；检查每一步实际图片、窗口与相册内容。

当前契约见 [Camera](../../MobileHarness/Actions/Camera/README.md#session-previews-state-and-gallery)、[State](../../MobileHarness/Agents/Support/Context/README.md) 与 [Chat](../../MobileHarness/Agents/Support/Chat/README.md)。

## 2026-11-06 真机安装

按用户要求，以现有本地签名配置构建当前工作区为 0.1.0 / 2026110606，未修改源码版本或签名设置。MobileHarness 真机构建、严格签名校验、30 项最终 Agent/Skill 资源校验及 Live Activity 嵌入/版本校验通过。

iPhone 17 Pro 原位安装成功（installation sequence 6136）；独立设备应用清单确认 dev.mobileharness.app 从 2026110605 更新到 2026110606。未卸载或清空应用数据。启动请求因手机锁定被系统拒绝（FBSOpenApplicationErrorDomain / Locked），因此只确认安装完成，不确认进程启动或原生交互验收。

本机证据：`/tmp/mh-preview-2026110606-build.log`、`/tmp/mh-preview-2026110606-install.json`、`/tmp/mh-preview-2026110606-apps-after.json`、`/tmp/mh-preview-2026110606-launch.json`。
