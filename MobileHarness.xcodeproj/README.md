# Xcode Application Project

## 职责与设计目标

✅ 构建、签名 iOS 应用宿主，提供设备、模拟器与模型验证 scheme，维护与实际目录一致的源码导航。每个源文件只有一个编译所有者；共享 SwiftPM 源码不加入 App Sources。

## 源码与目标归属

MobileHarness 和 MobileHarnessSimulator 编译 App 入口、Composition 和系统回调适配；ApplicationContainer.swift 由 AppStorage 唯一编译，ApplicationLifecycle.swift 由 Foundation 独立 AppLifecycle 编译。具体成员及排除规则以 [Package.swift](../Package.swift) 和 project.pbxproj 为准。

HarnessKit 提供共享模块；MOBILEHARNESS_BUILD_VARIANT=simulator 变体排除设备专属的默认 Gemma CoreAI 后端。Agents、Actions、Gateway、UI、基础模块及模型适配器由各自包目标编译，工程组仅导航其源码。AgentContainer、AgentFailure、七个角色容器与 Support/AgentContainerLifecycle 位于各自所属组；故障通道归 Agents。UI 页面和原生渲染资源由 UI 包拥有，工作流属于实际业务模块。

源码组应镜像物理目录，引用存在的文件，不以旧目标或已删除类型定义所有权。跨模块设计见[总体设计](../MobileHarness/README.md)，App 接线见 [Composition](../MobileHarness/App/Composition/README.md)。

## 配置与资源

共享构建设置、权限、entitlements 和 AppInfo.plist 归 [Config](../Config/README.md)，本地签名保存在忽略的 Local.xcconfig。CADisableMinimumFrameDurationOnPhone 由 AppInfo.plist 提供；最终包验证其值，高刷请求不证明设备实际帧率。

设备／模拟器资源列表只暂存模型 catalog 和许可，不嵌入权重、模型图或 tokenizer。Agent／Skill 与 Core 协议资源由 SwiftPM 声明，scheme 清理与最终包检查防止增量构建留下旧资源。资源策略见 [Resources](../MobileHarness/Resources/README.md)。

## 构建接口与验收边界

scripts/check.sh 检查源码／目标边界、测试和项目元数据；scripts/build-ios.sh 依次构建 MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 并验证 Agent 资源。MobileHarness scheme 用于签名设备构建；具体命令和工具链约束见 [scripts](../scripts/README.md)。

❌ 构建不证明真实模型、麦克风／播放、相机、蓝牙／机械臂、原生交互、延迟或持续温度验收。运行、安装和失败记录只归 [validation](../docs/validation/README.md)，导航／所有权演进只归 [history](../docs/history/README.md)。
