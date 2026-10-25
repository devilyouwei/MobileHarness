# System — 业务函数与执行设计

## 职责与模块关系

拥有模型资源、Provider 配置、设备和 Task 控制业务，以及显式应用诊断。根级 SystemModule 仅绑定固定运行信息，具体业务目录各自拥有接口、事务和执行服务；UI 草稿与本地表单机制由基础 UI 拥有。

Gateway 通过注册函数调用本域，Agents 决定请求与策略，App 注入唯一基础能力和根生命周期。本域消费 FunctionContracts 及需要的基础能力，不导入 Agents、Gateway 实现或 App。全部域内源码由 Actions 单一目标编译。

## 目录与文件

| 文件 | 当前职责 |
| --- | --- |
| [RuntimeActions.swift](RuntimeActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [SystemActions.swift](SystemActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [SystemModule.swift](SystemModule.swift) | 固定运行信息函数绑定 |

| 目录 | 责任 |
| --- | --- |
| [Device](Device/README.md) | 函数解析并限定操作专用参数，端口负责真实准入与结果 |
| [Diagnostics](Diagnostics/README.md) | 显式诊断与授权 Agent Action 执行分开，不从合成检查推导真实业务或设备验收 |
| [ModelResources](ModelResources/README.md) | 下载完成准入与制品实际下载完成分开 |
| [Provider](Provider/README.md) | URL／密钥只在会话私有暂存和凭据端口中传递，函数参数仅带请求 ID |
| [Task](Task/README.md) | 公开地址为 Agent.Task，源码归 System 的任务控制业务 |

## 函数接口与完成语义
| 地址模块 | 函数 | 完成与静态预算 |
| --- | --- | --- |
| System.ModelResources | snapshotResources、restoreSource、saveSource、configureSpeech、download、cancel、remove | 全部 60 秒；下载是准入，取消/删除/绑定等待端点返回 |
| System.Provider | discoverModels、restoreSettings、saveSettings | 60 秒；暂存请求的实际结果或 requestID |
| System.Provider | readSettings | 默认 30 秒；已确认的启用状态和模型名 |
| System.Device | control | 60 秒；accepted 操作回执，不等于连接成功或电机到位 |
| System.Device | readStatus | 默认 30 秒；设备状态与已发现设备 ID，不扫描或移动 |
| System.Runtime | runtimeInfo | 默认 30 秒；固定文字“本地聊天与语音能力已配置” |
| Agent.Task | loadSkills、releaseSkills、startTask、finishTask、cancelTask | 5 秒；宿主返回的 value completion |

TaskActions 属于 System 目录，但公开地址为 `Agent.Task`，这是显式的地址映射。它转发完整参数和 invocation，不在这里维护 Agent 状态或重复宿主的权限、参数及轮次验证。

## 参数、结果与私有数据
资源下载需要 id（最多 64 字节）、endpoint（最多 1024 字节）及严格 true/false 的 allowsCellular。source 保存同时接受 recognition/synthesis 严格布尔字符串；configureSpeech 只改变注入端点绑定，偏好持久化是另一项操作。source 编码上限 2048 字节，资源快照上限 65536 字节。

Provider 的发现、恢复、保存只传 requestID ID；URL/密钥留在同会话私有暂存中。发现结果最多 2048 个模型 ID、每项最多 512 字节、编码最多 65536 字节；过滤策略在 Support。readSettings 不返回 URL/密钥，不执行联网可用性探测。

Device.control 的模型声明提供 scan/stopScan/connect/reconnect/disconnect/forget/refresh；实际解析还支持 preset、motorVelocity、stopMotorControl、openPage、closePage、openSystemSettings 等可信操作。

DeviceActions.control 按 operation 提取适用字段，忽略其他操作专用的 id/value/action，不传到设备端口。connect/reconnect 仍要求设备 ID；motorVelocity 仍要求电机 1…6 和有限 −1…1 的 value；preset 仍使用封闭动作名。可选 fence 始终校验 UUID。XML 额外未声明参数在 AgentCore 解析别名时过滤；可信直接入口仍拒绝未知键。disconnect 不需要设备 ID，即使附带 id 或其他操作字段也只提交断开请求。

readStatus 不接收参数，限制 16384 UTF-8 字节，内容由设备拥有者提供；入口不扫描或证明物理完成。应用摘要由 agents.application、导航由 ui.navigation、原生事实由 platform.* 提供，不注册通用环境查询。runtimeInfo 直接返回固定文字，当前不解析参数，也不是实时健康检查。

Task 声明描述 JSON 数组 Skills、前台/后台 Task 字段和终态控制：foreground 使用 goal 及可选 skills/execution；target/businessContract/payload 为后台字段。finishTask 的 continueDecision 默认 false，仅为同一输入剩余新目标声明显式续轮。实际验证、提交、清理与结果屏障均在宿主端口实现。

[Actions 设计](../README.md) · [公共函数契约](../Support/Contracts/README.md)
