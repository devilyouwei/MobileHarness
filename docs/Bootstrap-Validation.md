# 初始化验证记录

日期：2026-09-22。环境：Apple Silicon Mac，Swift 6.4 Command Line Tools；尚未安装完整 Xcode。

## 已通过

- 六个 Swift Package 模块编译。
- 7 项 Swift Testing 测试：生命周期与有界队列、输出溢出失败、能力拒绝、fan-out 失败隔离与去重、工具回路关联、命名空间函数分发、工具错误回传。
- Swift 官方格式工具严格检查。
- Xcode 工程配置和 Privacy Manifest 的 plutil 校验。
- AppRuntime 在 Swift 6 / MainActor 默认隔离设置下的 macOS 类型检查。
- 检查脚本语法与工程文件引用检查。
- Git main 分支初始化。原始 Word 文档保持不变；未创建提交或配置远程仓库。

测试过程中，受限环境不允许默认用户缓存目录写入，因此使用 `/tmp` 缓存。当前 Command Line Tools 的增量构建还出现 Testing 宏插件搜索路径缺失，显式添加工具链自带插件目录后最终测试通过；`scripts/check.sh` 对此 CLT 环境做了自动适配。

本次最终核心测试命令：

```sh
CLANG_MODULE_CACHE_PATH=/tmp/mobileharness-clang-cache \
SWIFT_MODULECACHE_PATH=/tmp/mobileharness-swift-cache \
swift test --package-path Packages/HarnessKit \
  --scratch-path /tmp/mobileharness-build \
  --cache-path /tmp/mobileharness-spm-cache --disable-sandbox \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

`--disable-sandbox` 仅用于此次受限执行环境中的 SwiftPM 子进程，不是 App 沙箱配置，也不是常规开发要求。

## 待安装 Xcode 后验收

- `./scripts/build-ios.sh` 当前按预期报告缺少完整 Xcode；尚未完成 iOS SDK 编译、链接、模拟器启动和真机调试。
- 尝试对完整 UI 做 macOS 类型检查时，CLT 缺少 SwiftUIMacros；因此不能以 AppRuntime 的类型检查代替 SwiftUI / iOS 构建成功。
- 在模拟器确认文本、`/smile`、`/status` 三条路径，以及大字号和 VoiceOver。
- 真机配置开发签名，确认启动和前后台切换。
- CI 文件已建立但未在远程执行；runner 需要具备 Xcode 27.0。

模型推理、语音、媒体、设备权限与机器人连接均不在 P0 已验证范围。
