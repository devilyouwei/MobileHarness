# 眨眼 App 图标

采用已选定的 `output/icon-concepts/mobile-eyes-wink-v4.png`，保持深色背景、放大的蓝色睁眼和圆润 `<` 形眨眼。将图像等比规范为不透明 1024×1024 PNG，保存到现有 Resources/AppIconVariants/eyes-wink.png；选择器增加 eyes-wink，并复制至 Assets.xcassets/AppIcon.appiconset/AppIcon.png。不新增目录，不改变资源声明、运行时接口或模块边界。

同步 AppIconVariants、AppIcon.appiconset、scripts 及概念图说明；保留历史源图。检查尺寸、透明度、源图与所选资源一致性，运行 check.sh；完整 Xcode 可用时运行 build-ios.sh。安装后的桌面效果独立验收。

## 2026-11-09 交付与验证

正式资源与 eyes-wink 源已更新为相同的不透明 1024×1024 PNG，选择器支持 eyes-wink；尺寸、透明度、逐字节一致性、shell 语法及 diff 格式检查通过。

check.sh 的架构边界检查、6 项下载器测试和格式 lint 通过；Swift 测试因另一项工作占用共享 .build 而等待。build-ios.sh 已使用完整 Xcode 启动，但停留在 Resolve Package Graph。本轮停止了自身等待中的验证进程，未停止其他任务；完整检查和 iOS 构建均不能声明通过。待共享构建空闲后重跑，并在安装后确认桌面图标。执行日志：/tmp/mobileharness-icon-check.log、/tmp/mobileharness-icon-build.log。
