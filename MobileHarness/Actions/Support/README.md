# Actions Support — 公共函数契约与作者接口

## 职责与边界

本目录只提供跨业务域复用的契约、编译期函数声明接口和通用清理错误。具体业务目录组合、协议策略和实例端点组合由 Actions 根级拥有；域内执行服务由所属业务目录拥有。

## 文件与编译关系

| 文件／目录 | 职责 | 编译目标 |
| --- | --- | --- |
| [Contracts](Contracts/README.md) | 函数输入、声明、资源、预算、完成、报告与目录校验 | 独立 FunctionContracts，无项目依赖 |
| [ActionMacro.swift](ActionMacro.swift) | @Action 和 @ActionCatalog 作者接口，展开由 BehaviorDefinitions 插件实现 | Actions |
| [NativeCleanupFailure.swift](NativeCleanupFailure.swift) | 保存多个原始执行／清理错误 | Actions |

各业务域使用宏及公共契约，ExecutionRuntime、CallRuntime、Gateway、Agents 通过独立 FunctionContracts 使用中立值；本目录不创建基础容器、设备、任务或队列。

## 宏与失败契约

@Action 生成同名 Declaration 和 Definition 工厂，传递参数、资源、预算及完成语义，不决定调用协议或权限。@ActionCatalog 分析本类型内的工厂调用和本地 helper，生成去重、排序的静态声明列表；不进行运行时发现。展开细节由[宏插件](../../../Macros/BehaviorDefinitions/README.md)拥有。

NativeCleanupFailure 只保存原始 Error 数组，不执行清理、重试或判断成功。实际生命周期所有者负责取消、加入并收集失败，不能用后续清理异常覆盖原始执行失败。

[Actions 组装与调用关系](../README.md) · [整体目标地图](../../README.md#target-map)
