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

D3 下载沿用通用制品状态和失败呈现。选择本地 Decision 的安装错误经 Provider 设置呈现通道返回。

showResources 返回本次实际读取的资源快照；同会话刷新已被新批次替代时不再覆盖 UI，正常结束不代表该批快照曾被显示。旧批次的 showResourceFailure 同样不覆盖最新错误。当前批次的真实查询/展示失败仍沿原失败链路返回，业务保存结果不因投影过期改变。
