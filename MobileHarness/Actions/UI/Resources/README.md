# UI/Resources — 业务能力与执行

## 职责与关系

只呈现真实资源快照、结果与已分类错误，不发起下载或修改模型偏好。generation 和请求身份由端点验证；私有 Provider 配置不进入呈现参数。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

showResources 返回本次呈现的资源快照。Provider 结果和错误展示成功只生成结构化完成回执；展示异常通过既有执行结果交给调用方。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ResourcePresentationActions.swift](ResourcePresentationActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ResourcePresentationCapabilities.swift](ResourcePresentationCapabilities.swift) | 资源事实／错误与私有 Provider 结果呈现端口 |
| [ResourcePresentationModule.swift](ResourcePresentationModule.swift) | 资源呈现函数绑定 |

[所属域设计](../README.md) · [Actions 模块](../../README.md)
