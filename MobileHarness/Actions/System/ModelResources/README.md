# System/ModelResources — 业务能力与执行

## 职责与关系

下载完成准入与制品实际下载完成分开。可变请求、偏好更改与刷新有独立界限；停止取消并加入防抖／恢复，原生后台交接最多保留十个 completion。应用只注入唯一制品根和仓库，不在这里创建第二套模型管理器。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ArtifactServices.swift](ArtifactServices.swift) | 制品配置和文件／下载适配的组合 |
| [ModelArtifactStorageAdapter.swift](ModelArtifactStorageAdapter.swift) | 制品文件、标记与存储协议适配 |
| [ModelDownloadBackgroundService.swift](ModelDownloadBackgroundService.swift) | 后台下载事件交接和有界完成回调 |
| [ModelResourceInteractionWorkflow.swift](ModelResourceInteractionWorkflow.swift) | 资源提交、恢复、防抖与真实操作反馈 |
| [ModelResourceInventory.swift](ModelResourceInventory.swift) | 有界资源事实、进度和安装资格投影 |
| [ModelResourcePreferencesService.swift](ModelResourcePreferencesService.swift) | 偏好文档的校验与排他持久化 |
| [ModelResourcesActions.swift](ModelResourcesActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ModelResourcesModule.swift](ModelResourcesModule.swift) | 模型资源端口与函数绑定 |
| [SettingsModelResourcesAdapter.swift](SettingsModelResourcesAdapter.swift) | 模型子能力到资源操作及 UI 值的适配 |

## 资源快照与偏好

ModelResourceInventory 是 version=1 的 Codable 值。read 从 capability 获得原始事实，并以 installed 项推导 installedGroups：recognition=nemotron、synthesis=moss-tts-nano、language=gemma4-e2b、vision=yolo26n-pose。Silero 不在这些必需集合中。

快照最多 64 个唯一 ID、编码最多 65536 字节；ID/name/revision/license/failure 分别限 64/256/512/512/1024 UTF-8 字节，字节计数非负。active 对应 queued/downloading/verifying/deleting，progress 对总量做有界计算。decode 校验版本、条目和大小；installedGroups 的一致性推导发生于构造读取路径，validate 不重新计算已解码集合。

ModelResourcePreferencesService 是 actor，惰性获取注入的 DocumentStore，通过 changing 标志拒绝重叠 restore/save。restore 校验存储值并依据已安装资源关闭不可用自定义语音选项；只有联网/语音开关变化时才回写，单独 endpoint 规范化不触发写入。save 先校验源与已安装前提，再以预期 revision 保存。偏好结果编码上限 2048 字节；文档存储容量由注入 store 配置。

偏好解码支持 preferDownloadedSpeech 字段映射到两个独立开关；新编码只写当前字段。持久化不负责模型绑定，已提交偏好不会因另一项绑定失败自动撤销。

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Execution ownership and lifecycle

ModelResourcesClient and ModelResourceInteractionWorkflow are Actions-owned UI facades. The root closes admission, cancels/joins restoration, autosave and up to 32 admitted UI operation workers. Coalesced source restoration has at most 32 waiters and explicit shutdown. ApplicationControl consumes typed intent and authorizes functions; actual preference/artifact services remain Actions-owned.
