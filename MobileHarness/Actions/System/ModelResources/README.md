# System/ModelResources — 业务能力与执行

## 职责与关系

下载完成准入与制品实际下载完成分开。可变请求、偏好更改与刷新有独立界限；停止取消并加入防抖／恢复；原生后台交接由 ModelKit 拥有。应用只注入唯一制品根和仓库，不在这里创建第二套模型管理器。

本目录由所属域目录绑定，接受标准 FunctionInput；调用权限、通用调度与资源仲裁由上游 Gateway 保持。下游只消费注入的基础能力。

下载准入、取消加入、移除和语音绑定的成功由结构化完成回执表示。下载进度、已安装事实由资源清单提供，保存与恢复资源偏好返回实际生效的配置。

## 文件与实现

| 文件 | 当前职责 |
| --- | --- |
| [ModelResourceInteractionWorkflow.swift](ModelResourceInteractionWorkflow.swift) | 资源提交、恢复、防抖与真实操作反馈 |
| [ModelResourceInventory.swift](ModelResourceInventory.swift) | 有界资源事实、进度和安装资格投影 |
| [ModelResourcePreferencesService.swift](ModelResourcePreferencesService.swift) | 偏好文档的校验与排他持久化 |
| [ModelResourcesActions.swift](ModelResourcesActions.swift) | 业务函数的参数校验、能力调用与完成值 |
| [ModelResourcesModule.swift](ModelResourcesModule.swift) | 模型资源端口与函数绑定 |
| [SettingsModelResourcesAdapter.swift](SettingsModelResourcesAdapter.swift) | 模型子能力到资源操作及 UI 值的适配 |

## 资源快照与偏好

ModelResourceInventory 是 version=1 的 Codable 值。read 从 capability 获得原始事实，并以 installed 项推导 installedGroups：recognition=nemotron、synthesis=MOSS 或 Kokoro 已安装、language=gemma4-e2b、vision=yolo26n-pose。Silero 不在这些必需集合中。

快照最多 64 个唯一 ID、编码最多 65536 字节；ID/name/revision/license/failure 分别限 64/256/512/512/1024 UTF-8 字节，字节计数非负。active 对应 queued/downloading/verifying/deleting，progress 对总量做有界计算。decode 校验版本、条目和大小；installedGroups 的一致性推导发生于构造读取路径，validate 不重新计算已解码集合。

ModelResourcePreferencesService 是 actor，惰性获取注入的 DocumentStore，通过 changing 标志拒绝重叠 restore/save。restore 校验存储值并依据已安装资源关闭不可用自定义语音选项。Zipformer 快速打断默认关闭，
只允许在已安装时启用，移除模型后清除偏好；只有联网/语音开关变化时才回写，单独 endpoint 规范化不触发写入。save 先校验源与已安装前提，再以预期 revision 保存。偏好结果编码上限 2048 字节；文档存储容量由注入 store 配置。

偏好解码支持 preferDownloadedSpeech 字段映射到两个独立开关；新编码只写当前字段。持久化不负责模型绑定，已提交偏好不会因另一项绑定失败自动撤销。

[所属域设计](../README.md) · [Actions 模块](../../README.md)

## Execution ownership and lifecycle

ModelResourcesClient and ModelResourceInteractionWorkflow are Actions-owned UI facades. The root closes admission, cancels/joins restoration, autosave and up to 32 admitted UI operation workers. Coalesced source restoration has at most 32 waiters and explicit shutdown. ApplicationControl consumes typed intent and authorizes functions; actual preference/artifact services remain Actions-owned.

资源偏好必须显式包含当前 endpoint、allowsCellular、useCustomRecognition、useCustomSynthesis；不接受旧单开关。安装收据只接受当前相对路径，不修复旧 UUID 前缀。网络失败后同一有效下载计划的续传属于当前恢复机制，仍可使用。

## Decision 资源

Chat 和 Decision 资源共享下载源。库存通过注册描述区分可下载制品与系统管理模型，制品行复用 ModelKit 容量、进度和错误，系统模型行复用可用性。角色选择从同一库存投影读取候选。删除由 ModelKit 围栏对应制品和引用它的模型，业务负责加入当前使用。

下载设置保留旧 useLocalDecision 字段供 [Provider 设置](../Provider/README.md) 在升级时读取，保存下载设置时保持旧值。当前 Decision 独占模型选择由 Provider 设置拥有。删除或缺少已选 D3 时，Assistant 提示错误并入队，不切换云端。

ResourcePresentationAdapter 在校验根接纳与会话后，将小于当前 refreshGeneration 的有效刷新/错误呈现视为已被替代并正常结束；不写 UI、不 acknowledge，不触发二次失败。当前序号仍应用实际快照或错误；无效/未来序号、外来会话和根关闭继续拒绝。Provider 保存事务不受页面刷新替代影响。

未存储偏好时，ModelResourcePreferencesService 按系统首选语言初始化下载源：zh（含简繁体）为 HF Mirror (China)，其他语言为 Hugging Face。已保存 endpoint 优先于系统语言。语言读取可注入，独立于应用界面语言。下载前提交当前源，ModelResourcesClient 将源值传入下载请求；后续偏好编辑不修改在途任务。

Resource preferences also persist vadOnsetWindows (1…16) and vadThreshold (0.05…0.95 in 0.05 increments). Missing fields decode as 8/0.65; validation rejects invalid ranges and steps. Speech detection edits restore the confirmed source before saving so unfinished domain edits are excluded. A read-only composition port supplies saved settings to perception; persistence errors propagate.

## Speech enhancement preference

`useSpeechEnhancement` is independent of the custom-ASR switch and defaults false when absent in stored records. Enabling requires an installed `deepfilternet3` artifact; restore disables and persists it after removal. The workflow preserves confirmed state on failed saves and does not save unfinished endpoint edits when toggling denoising. Existing bounded resource commands handle download/progress/cancel/delete; removal quiesces the voice owner before artifact deletion. The read-only enablement closure crosses App composition into Agents; Actions never processes PCM.

`speechModels.endpointConfirmation` 默认关闭，选用 Smart Turn 需要已安装制品。恢复偏好时，已移除的制品回到关闭。Gateway 参数解析按 ModelKit 语音模型目录的能力数量限制映射项，并校验 JSON 和每个标识的字节数。端点推理与音频生命周期由 SpeechPerception 管理。

Actions 只拥有用户意图、UI 投影和模型选择／下载源／语音参数偏好。偏好文档位于 Storage settings 命名空间；模型目录、制品存储、传输恢复与后台交接均由 [ModelKit Management](../../../ModelKit/Support/Management/README.md) 拥有。

Chat 和 Decision 的下载分组由已注册模型与制品的关联确定。下载不自动切换选择。

语音资源清单从 ModelKit 投影选项的 capability、model ID、名称和 artifact ID。
偏好按能力保存模型 ID，旧语音布尔值在恢复时迁移，已有制品在选择前仍需校验状态。
Kokoro 的分语言音色由同一清单投影。可选 `synthesisVoice` 字段经过 ModelKit 音色校验，
通过现有偏好事务随模型映射绑定。旧记录缺少该字段时使用提供者默认音色。
下载和移除使用现有资源事务，只有移除当前模型才将该能力回退到默认。

关键词置信度作为 `keywordThreshold` 走同一偏好事务，范围 0.10…0.60，步进 0.05，旧记录读取为 0.25。采集读取接口返回快停开关和已保存的阈值。

保存语音偏好时，服务比较已确认的能力选择、VAD 阈值与起声窗口、关键词阈值和合成音色。它在写入前把受影响的角色和新增模型交给宿主维护入口，写入结束后释放保存围栏。单独修改下载源不触发模型维护。首页配置读取保留已选模型，实际制品状态由 ModelKit 校验。
