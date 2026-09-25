# iOS 与机器人能力边界

手机作为推理和感知中心，通过公开 API 控制本 App 获准访问的相机、音频、传感器、照片以及配对设备。普通 App 不能拥有任意系统管理权限，也不能通过通用 API 操作所有第三方 App 的界面。

| 能力 | 接入方向 | 实施约束 |
| --- | --- | --- |
| 相机 / 音频 | AVFoundation | 按需权限，处理中断、前后台切换与热状态 |
| 语音 | Speech / 系统 TTS / 本地模型 | 按系统与设备核实支持；声明实际使用的数据流 |
| 照片 / 位置 | Photos / Core Location | 限定授权范围，拒绝后降级 |
| App 与系统集成 | App Intents / Shortcuts / 已公开 URL 接口 | 只使用系统与目标 App 公开的能力 |
| 机器人连接 | Core Bluetooth / Network | 配对、授权、协议校验、超时和急停 |
| 后台任务 | BackgroundTasks 与符合用途的 background modes | 由系统调度，不承诺永久运行 |

长期存活 actor 是进程内生命周期概念，不代表 App 被系统挂起后仍可无限执行。物理机器人的低层安全控制、运动限幅和 watchdog 必须落在外部控制器；手机失联时外部设备自行停机。手机不承担硬实时安全控制。

当前语音功能仅在用户点击开始后请求麦克风与语音识别权限，在停止/后台/中断时关闭音频。调试版允许 Apple 联网识别，录音可能由系统发送至 Apple；关闭联网开关后强制端侧识别。App 不自行保存录音、不持久化对话，没有自建接收服务。Info.plist 与 UI 已披露联网数据流。隐私清单当前未声明 App 自行采集的数据；发布前须结合最终服务配置与 Apple 数据处理规则复核清单、隐私政策及商店披露，不能将当前构建描述成“所有音频均不离开设备”。

依据（2026-09-22 查阅）：[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)，[Background Tasks](https://developer.apple.com/documentation/backgroundtasks)。具体接入时按对应 SDK 文档核实。
