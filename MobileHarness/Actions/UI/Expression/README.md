# UI/Expression — 业务能力与执行

## 职责与关系

有限表情完成包含自身覆盖恢复；持续基础表情和加载／请求等待状态以接纳完成。加载 revision 与请求 ID 分开，不能互相覆盖；错误与恢复错误同时保留。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ExpressionActions.swift](ExpressionActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ExpressionCapabilities.swift](ExpressionCapabilities.swift) | 表情与加载状态的呈现端口 |
| [EyeExpression.swift](EyeExpression.swift) | 表情执行预算与呈现辅助 |
| [ExpressionTypes.swift](ExpressionTypes.swift) | 表情词汇、参数错误及双重清理错误 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
