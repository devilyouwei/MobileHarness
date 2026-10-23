# UI/Navigation — 业务能力与执行

## 职责与关系

导航只提交目标和真实调用上下文；导航端点决定呈现接纳，函数不持有页面或创建业务会话。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [NavigationActions.swift](NavigationActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [NavigationModule.swift](NavigationModule.swift) | 导航函数绑定 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
