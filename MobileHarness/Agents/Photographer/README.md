# Photographer

## 职责与直接关系

确定性摄影事务、相机事实与机械跟踪的业务 owner，不生成普通对话。可信 photography.camera 意图和 camera.state 经 Gateway 进入；VisionPerception 发布姿态。本角色发出固定摄影/瞄准调用，Actions 通过 App 注入的相机和设备能力执行，反馈回原执行者。Assistant 的摄影 Skill 直接发 Camera Actions，不把用户聊天委派到这里。

## 内部结构

| 文件 | 职责 |
| --- | --- |
| PhotographerAgent.swift | 生命周期、接纳、状态与输出 |
| PhotographerCameraWorkflow.swift | 相机固定步骤与结果关联 |
| PhotographerTrackingPolicy.swift | 新鲜姿态选择与跟踪策略 |
| PhotographerProcessing.swift | 结构化状态、预处理及调用绑定 |

## 接口与数据流

[Agent.json](../../Resources/Agents/Photographer/Agent.json) 定义 camera.state / vision.pose / photography.camera 的来源及 task.progress/result 定向消息，baseSkills=photography。固定函数在 workflow 注册；Skill 的七个 Camera 绑定用于目录复用，不创建 Chat worker。准确参数/完成语义由 [Camera Actions](../../Actions/Camera/README.md) 和 [NexArm Actions](../../Actions/NexArm/README.md) 拥有。

固定摄影状态包括事务、当前相机、产物、调用/任务关联。open/close/flip/retry/save/ignore 按真实反馈推进；调用结果不是物理状态的推测，保存与预览处置使用真实媒体身份。跟踪与相机事务独立，仅在前台、连接和权限条件满足、姿态新鲜时通过内部 NexArm.Tracking.aim 提交目标。跟踪不绕过 native 停机/资源约束。App 跟踪端点将目标提交为一个电机 1/4 同步包，肩/肘不参与实时跟踪；本角色继续拥有姿态策略、固定函数目录及相机事务，包整形见 NexArm Support。

## 状态、容量与生命周期

根服务拥有事务/输出消费，不依赖页面。最近 4096 条 Signal 证据和消费批次滚动保留并累计淘汰；相机状态、目标、调用和任务独立保存，淘汰证据不删除待执行工作。输出容量 256，状态与通信等待有界，超限拒绝。

仓库原子提交先于依赖步骤；反馈必须匹配会话/调用。取消加入拥有的动作与追踪清理；热状态使用内存，未完成持久化业务记录在重启后标记中断，不重放设备效果。基础机制见 [Context](../Support/Context/README.md)，实际采集和设备停机由 App/PlatformKit 保证。

## 待实现

- 真实相机/Photos、追踪精度、设备接管和持续运行验收。
- 声学竞争与跨原生生命周期交互的端到端验收。
