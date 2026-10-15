# iOS 与机器人能力边界

本文件描述平台和授权约束，不作为功能已接入清单。当前用户能力见 [Product scope](Product-Scope.md)，模块实现见 [Architecture](Architecture.md) 及其源码入口。

## 原生能力与权限

| 领域 | 边界 |
| --- | --- |
| 相机与音频 | 使用公开原生接口和用户授权，处理权限拒绝、前后台和路由/设备中断；能力可用不代表已开始采集。 |
| 系统照片及其他受限数据 | 仅访问实际获准范围，导出、读取与 App 内媒体保存分别确认。 |
| App 与系统集成 | 只使用系统和目标 App 明确公开的能力；普通 App 不拥有任意系统管理或第三方界面控制权限。 |
| 模型处理 | 根据实际设备、制品和配置确认能力；本地/云端选择不改变设备权限与业务执行授权。 |
| 机器人连接 | 原生连接、发送准入、设备反馈和物理到位分别确认；具体协议及失败归属由 PlatformKit/Actions 各自定义。 |

## 生命周期与物理控制

进程内长期 actor 不代表 iOS 挂起后仍能持续执行。后台机会由系统和已配置能力决定，不能把永久运行当成产品保证；根级所有者仍需定义取消、停止和清理。

物理机器人的低层保护、限幅和 watchdog 必须由外部控制器承担，手机不能提供硬实时安全保证。BLE 或 USB 实测只支持对应设备、负载、协议和测试环境；发送成功、视觉姿态或 UI 就绪不能代替物理到位事实。

语音提供者、相机初始状态和自动恢复策略会随业务配置演进，本文不重复其默认值。当前契约见 [App 生命周期](../MobileHarness/App/Lifecycle/README.md)、[PlatformKit](../MobileHarness/PlatformKit/README.md) 和 [Actions](../MobileHarness/Actions/README.md)。

## 外部资料

原文在 2026-09-22 引用 [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) 与 [Background Tasks](https://developer.apple.com/documentation/backgroundtasks)。具体接入按对应 SDK 的有效接口核实；此处不记录新的政策核验结论。
