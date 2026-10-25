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

## 对话打开相册

UI.Navigation.open 的允许目标与参数说明补齐 album，使用既有NavigationModule与会话校验端点，将UI路径设置为settings → album。presented仅表示导航状态已提交，不表示照片已经加载；未知目标、memory占位目标及无效会话仍拒绝。

## Container 上下文

导航Action仍经真实身份／呈现准入提交路径，presented仅代表提交。页面确认及上下文属于UI NavigationState；模型按ui.navigation读取，Actions不建立第二份路由状态。
