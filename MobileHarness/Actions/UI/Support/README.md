# UI/Support — 跨能力共享机制

## 职责与关系

跨表情、会话、视线和运行状态共用的更新端口与中立值。具体资源、反馈、骨架、表情和运行异常契约归各业务目录。

本目录由所属域及其业务能力消费，不持有异步任务、原生设备或应用装配。

## 文件与接口

| 文件 | 当前职责 |
| --- | --- |
| [UIPresentationCapabilities.swift](UIPresentationCapabilities.swift) | 跨呈现分组共享的更新端口 |
| [UIPresentationTypes.swift](UIPresentationTypes.swift) | 跨文字／语音状态／视线使用的中立值与错误 |

[所属域设计](../README.md) · [公共契约](../../Support/Contracts/README.md)
