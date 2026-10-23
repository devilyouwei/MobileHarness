# UI/Pose — 业务能力与执行

## 职责与关系

视线和骨架是独立呈现操作，骨架载荷不拥有模型或页面。实际端点验证原始帧、会话与单调序号，预览影像不依赖姿态推理成功。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [CameraOutputHandling.swift](CameraOutputHandling.swift) | 感知状态、视线和骨架的呈现端口 |
| [GazeActions.swift](GazeActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [PoseActions.swift](PoseActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [PoseCapabilities.swift](PoseCapabilities.swift) | 骨架呈现端口 |
| [PoseOverlay.swift](PoseOverlay.swift) | 骨架载荷、统计和编码 |

## 姿态载荷与校验

PoseOverlay 是独立 Codable 调用数据，不是模型后端或 UI 页面类型。Joint 使用恰好三个整数的数组编码：x、y、confidence；坐标单位为图像的 1/10000，置信度单位为 1/1000。

showPose 入口要求 payload 最多 3000 UTF-8 字节、timestamp 有限且非负、rotation 为 0…3、最多六人、每人完整 17 个 COCO 关节。坐标范围 −10000…20000，confidence 为 0…1000。空 people 用于清除。PoseOverlay 构造器本身不自动执行这些入口校验。

Statistics 要求各项存在值有限且非负、replacements 非负；detectionIntervalMilliseconds 最多 1000，imageMotion 最多 1。queueMilliseconds 与 totalMilliseconds 必须同时存在或同时缺省；存在时 total 至少覆盖 queue+inference（允许 0.001 毫秒误差）。这些是推理结果返回前的统计，不包含 UI 绘制确认。

[所属域设计](../README.md) · [Actions 模块](../../README.md)
