# iOS 与机器人能力边界

手机作为推理和感知中心，通过公开 API 控制本 App 获准访问的相机、音频、传感器、照片以及配对设备。普通 App 不能拥有任意系统管理权限，也不能通过通用 API 操作所有第三方 App 的界面。

| 能力 | 接入方向 | 实施约束 |
| --- | --- | --- |
| 相机 / 音频输入输出（PlatformKit） | AVFoundation / AVFAudio | 按需权限，处理中断、前后台切换与热状态 |
| 语音数据加工（ModelKit） | Speech / 系统 TTS / 本地模型 | 按系统与设备核实支持；声明实际使用的数据流 |
| 照片 / 位置 | Photos / Core Location | 限定授权范围，拒绝后降级 |
| App 与系统集成 | App Intents / Shortcuts / 已公开 URL 接口 | 只使用系统与目标 App 公开的能力 |
| 机器人连接 | Core Bluetooth / Network | 配对、授权、协议校验、超时和急停 |
| 后台任务 | BackgroundTasks 与符合用途的 background modes | 由系统调度，不承诺永久运行 |

长期存活 actor 是进程内生命周期概念，不代表 App 被系统挂起后仍可无限执行。物理机器人的低层安全控制、运动限幅和 watchdog 必须落在外部控制器；手机失联时外部设备自行停机。手机不承担硬实时安全控制。

当前生产语音由 PlatformKit 采集麦克风 PCM，ModelKit 的 Nemotron/Silero 处理识别与 VAD；系统 TTS adapter 导出 PCM，由 PlatformKit 播放。旧 Apple ASR 联网调试路径不属于当前默认装配。麦克风在用户开始语音交互时申请权限；相机在正常前台启动时独立申请权限并默认使用前置摄像头。App 协调前后台，平台 adapter 处理设备中断与释放。

PlatformKit 的职责是设备/系统数据输入输出及必要格式适配；ModelKit 负责模型前处理、推理与后处理。是否接纳帧由 Gateway 决定，摄影业务决策由 Agent 承担，UI 预览和覆盖层由 Experience 呈现。两套 Kit 不互相依赖，App 提供数据适配与服务注入。Connectivity 目前只有传输契约，尚无真实机器人控制实现。

依据（2026-09-22 查阅）：[Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)，[Background Tasks](https://developer.apple.com/documentation/backgroundtasks)。具体接入时按对应 SDK 文档核实。
