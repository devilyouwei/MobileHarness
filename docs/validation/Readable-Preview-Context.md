# 可读照片编号与合并用户图片输入

2026-11-06。模型使用 preview_1、preview_2 等短编号；当 State 含图片时，附件合并到本轮原始用户输入。system State 的图片清单用 ID 与从 1 开始的附件位置关联来源、MIME、尺寸和字节数。保存相册继续独立分配 media_N。

## 回归范围

- 真实 SQLite：并发编号唯一、关闭重开后继续递增、未保存编号不复用、编号分配不创建媒体行或图片文件、持久媒体编号独立。
- Camera：有效编号与非规范编号校验；UUID 只允许历史读取；异步编号期间互斥、关闭／重置／取消后的迟到结果不发布缓存；重复缓存身份拒绝。
- 历史读取：当前缓存、保存后与数据库重开后读取原图；真实旧 UUID 所有权记录仍可读取；读取不改变 State；已删除、错误所有权和未收录图片不恢复。
- 共享请求：普通输入、XML Action 和原生 Tool 续轮将图片放在原始用户文字所在消息；文字与消息数量不变；下一请求使用新选择而不累积旧图。系统清单顺序与附件顺序一致，也考虑输入已有的图片。
- 失败和隔离：不支持图片时仅报告系统元信息；重复 ID、附件超限、缺少原始输入明确失败；原生调用／结果块连续；裁剪保护本轮输入与图像；临时图像日志仍不持久化二进制。

## 自动验证

首次定向回归通过，日志 `/tmp/mh-readable-preview-targeted.log`。随后首次全量检查中主集成套件 1066 项有三处失败：摄影验收辅助代码把图片清单之后的内容也交给单个 JSON 解析器，报 Garbage at end。修正测试读取边界后重新运行全量检查；首次独立原生／时序套件 227 项通过。保留失败日志 `/tmp/mh-readable-preview-check.log`。

最终 `./scripts/check.sh` 退出码 0，主集成套件 1066 项和 LiveRuntimeTests 227 项明确通过，其他业务套件、边界、六项 Python、严格格式和 plist 检查通过；日志 `/tmp/mh-readable-preview-check-final.log`。

但不能据此声称所有原生测试通过：NativePresentationTests.cameraNativeMetalDrawStopAndLayerHandoff 在窗口可见性等待处记录失败（CameraFramePresentationTests.swift:208，visible=true、occlusion=8192、active=false），尚未进入 Metal 绘制检查；该套件没有完成摘要。随后单独复查命令退出码同为 0，却仅记录测试开始、没有通过／完成记录，仍属未验证，日志 `/tmp/mh-readable-preview-metal-recheck.log`。首次运行也没有此原生测试的明确通过记录，因此不把它算作通过。SwiftPM 命令退出码与该原生子进程日志不一致；本次未修改无关的窗口渲染或测试运行器。

`./scripts/build-ios.sh` 退出码 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个构建通过，日志 `/tmp/mh-readable-preview-ios.log`。签名真机包 0.1.0 / 2026110608 构建通过，严格签名、30 项 Agent/Skill 资源、Live Activity 嵌入与宿主／扩展版本一致性均通过；日志 `/tmp/mh-readable-preview-2026110608-build.log`。

## 真机边界

首次安装时 iPhone 17 Pro 为 unavailable，CoreDeviceError 4016 拒绝建立受信连接／设备服务断言；没有安装成功。日志 `/tmp/mh-readable-preview-2026110608-install.log` 与同名 JSON。最终设备清单仍为 unavailable，见 `/tmp/mh-readable-preview-2026110608-devices-final.json`；未再次安装或尝试启动。此前单独确认的设备版本为 2026110607，不能把本轮成功构建当作成功更新。

未执行真实视觉模型、实际拍照或聊天记录页面的原生视觉验收。自动测试使用明确的图片字节／模型替身。当前技术契约见 [共享 Chat](../../MobileHarness/Agents/Support/Chat/README.md#request-only-state-images)、[Camera](../../MobileHarness/Actions/Camera/README.md#memory-previews-and-multimodal-state) 和 [SQLite](../../MobileHarness/Storage/Database/README.md)。

变更文档的本地链接与 `git diff --check` 已校验。原生窗口测试／运行器完成性和手机连接恢复后的安装、界面与真实视觉模型验收仍需单独确认。

## 2026-11-06 — 设备恢复连接后的安装

用户再次要求安装测试。iPhone 17 Pro 恢复 available (paired)；复核既有 0.1.0 / 2026110608 签名包，源代码／配置／资源无晚于应用可执行文件的修改，严格签名、30 项 Agent/Skill 与 Live Activity 校验通过。沿用上述已验证包，未重新执行自动测试。

原地安装成功（installation sequence 6152）；独立设备应用查询确认 dev.mobileharness.app 为 2026110608，随后启动成功。没有卸载或清空数据；安装与启动不代表实际拍照、聊天记录图片展示或真实模型验收通过，这些由用户继续测试。前述离线失败保留为历史证据。

本机证据：`/tmp/mh-readable-preview-2026110608-install-connected.log`、对应 JSON、`/tmp/mh-readable-preview-2026110608-apps-connected.json` 和 `/tmp/mh-readable-preview-2026110608-launch-connected.log`／JSON。
