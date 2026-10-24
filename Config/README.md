# Build configuration

## 职责与输入

共享 Xcode 设置、私有本地签名模板及显式资源 sandbox 文件清单。Swift 6 / iOS 27 设置来自共享配置；本地签名只保存在被忽略的 Local.xcconfig。模型图、权重、tokenizer 不属于 App 构建输入或包内资源，运行时由 Settings/ModelKit 安装。

## 打包与平台契约

- device/simulator 的 Voice-Models 清单只包含 model-catalog.json 和许可；修改元数据后运行 scripts/update-model-filelists.py。Scheme 预构建清理仅作用生成产物。
- 实机请求 increased-memory-limit，不能据此推断可用内存；Simulator 不请求此 entitlement。
- 相机用途说明覆盖本地预览、用户拍摄及请求的模型图像观察；Photos 仅请求添加显式保存照片，不请求相册读取/枚举。
- Config/AppInfo.plist 向 App 目标提供 CADisableMinimumFrameDurationOnPhone；签名包中的最终 plist 是平台元数据事实源。
- Xcode 导航与 Agents/Support、Resources/Agents/Skills 源位置一致；SwiftPM 拥有框架编译与资源复制，不重复加入 App target membership。

[Model management](../MobileHarness/ModelKit/Support/Management/README.md) 拥有制品安装与资源选择，[Resources](../MobileHarness/Resources/README.md) 拥有包内容。

## 待实现

- 签名设备性能、导出兼容性及后台传输的独立验收。

✅ AppInfo.plist 设置 NSAppTransportSecurity.NSAllowsArbitraryLoads=true，以支持用户配置任意域名或 IP 的 HTTP 模型服务；不同时设置会覆盖该值的 NSAllowsLocalNetworking 等细粒度 ATS 项。NSLocalNetworkUsageDescription 声明加载局域网模型列表和发送对话的用途。HTTPS 使用系统证书验证。策略依据 [Apple ATS 文档](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloads)。
