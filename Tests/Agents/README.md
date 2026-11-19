# Agents tests

## 职责与构造边界

通过真实 Agent/Gateway/Action/Tool/Storage 接口和注入模型、设备及呈现端点验证跨模块契约。ActionCatalogFixture 在每个作用域安装相同不可变生产声明；并发、失败与完成使用显式 gate/反馈同步。常规用例不推理真实模型、不控制硬件；真实 provider 和串口验收必须单独启用。


## 当前覆盖

BasicSkill 控制教学回归检查九个已注册别名均有独立效果说明，打包指令包含 Skill/Task/State 的区分与跨请求生效规则。已有 AgentTaskSkillTests 验证 Task 持有项的显式释放仍保留活动目标、非法释放原子拒绝、初始 Skill 接管及终态清理；资源教学不引入具体业务例子或业务 Skill ID。

PromptTemplateTests 动态枚举 Catalog 中所有非基础 Skill，验证默认请求可发现它们，但其私有指令/函数未加载；解析测试侧 loadSkills 调用、提交真实 Skill 状态后，下一请求获得对应教学/函数，旧目录仍拒绝新增函数。BasicSkill 的通用教学不包含这些业务 Skill ID。AssistantCommunicationFixture 为 browse 返回明确标注的合成文本或失败；不打开网站、不生成截图，模型决策结果不能当作真实网页访问验收。

PromptTemplateTests 验证摄影完成示例先单独解析为 Camera.Capture.close，下一示例才允许 Agent.Task.finishTask；装配提示保留关闭失败、独立视觉及重拍分支。此处验证资源和解析契约，不代表真实模型会遵循收尾流程。

SpeechPlaybackTests 通过真实 AudioCache／SpeechPlayback 与显式退出 gate 验证 VoiceReplyCancellation；播放取消加入前、原生停止加入前均保留未播放句柄，最后会话清理无 missingAudio 故障；中断正常返回、失败或取消时均完成清理并保留原错误。PCM／原生停止为替身，不宣称真机或真实合成验收。

PromptTemplateTests 通过生产目录和增量解析器读取 ExpressionInteraction 的子集串行/全量语音并行示例，核对每个 wait 的表情、默认 Channel、语音对应关系及全量示例对所有合法 express 值的覆盖，并检查默认请求包含教学。现有调度器 wait 回归验证组内跨 Channel 并行和组间完成屏障；合成测试不代表 Flash 真实模型遵循验收。

| 文件/用例组 | 主要边界 |
| --- | --- |
| AgentTaskSkillTests | 基础/近期/Task Skill 所有权、五次完整 Decision 闲置回收、使用续期、Task 接管及终态、等待/替换、依赖预算、在途保护、LRU、会话/重启与原子提交 |
| AssistantChatTests / GenerationRoundTests | 多轮上下文、原生配对、Action/Tool/混合屏障、第二输入优先、真实业务输出与完成证据、拒绝/取消/异常、长 ReACT 链 |
| PromptTemplateTests | 生产 XML 示例、静默 Task 入口、单次有序话术、无 Task 不关闭、目标转移询问/释放教学、模板变量及目录投影 |
| GenerationRoundTests 的 compact 用例 | JSON/文本/scalar/空值、业务 null、同名多调用序号、拒绝未执行、未知效果、部分成功/取消、内部完整 journal 与 provider ID 隔离 |
| ConversationHistoryTests / HistoryToolTests | 完整消息/请求证据、SQLite 重开、终态 Task 原位压缩、窗口、分页、原生结果及晚到写入、并发冲突与不重放 |
| HistoryIntentTests / ResourceIntentTests | 类型化历史/资源意图、两条 Gateway、提交与呈现、来源/会话隔离、删除/归档及取消 |
| FunctionTokenParserTests / GenerationTrace | UTF-8 分片、XML/实体/作用域、参数、容量、原始证据与无执行解析 |
| AgentConfigurationTests / ActionDeclarationTests | 资源 Catalog、canonical 声明、Skill 绑定、别名/Channel 冲突、固定与模型目录、最终声明覆盖 |
| RuntimeTests / AgentArchitectureTests / CommunicationTests | 接纳、incarnation/来源/会话、root/parent 关联、原子状态、根服务清理与有界输出 |
| ActionContractTests / ActionLifecycleTests / ActionObservationTests | 函数预算、共享执行、资源 lease/fence、Channel/wait、结果预留/重投递、接管、纯取消及完整终态 |
| VoiceTests / SentenceFunctionTests / SpeechPlaybackTests | VAD/ASR、冷加载期间前缀完整性/有序衔接、缓冲时长/内存/包数上限及取消隔离、分段、字幕/合成、PCM handle、播放与半双工边界 |
| AudioCaptureReadinessTests / AudioSampleBufferReaderTests | 首帧准备、格式、mono/FOA/planar PCM、溢出/失败与取消；不打开硬件的原生通知错误保真、中断分类、重复及停止后事件围栏 |
| PhotographyPipelineTests / CameraSamplingTests | 原生帧输入、最新态替换、共享姿态推理、skeleton/gaze 投影 |
| Resource/Provider/Settings 用例 | 私有参数暂存、保存/绑定/呈现顺序、版本冲突、资源准入及失败后状态 |
| Storage 用例 | domain 仓库、配置文档、提交身份、完整消息 checkpoint、容量/损坏/并发与缓存 |
| NexArm/Bluetooth 用例 | 包与几何、反馈／归位、断连与恢复、资源接管、机械臂状态和协议隔离；首次肩／肘水平准备、电机1／4有限位置目标、准入重试／替换、目标死区与前瞻限位、取消后无追加动作；取消／后台清理和最新手动意图的加入／接管 |

Task/Skill 的边界矩阵包括四种预加载接管方式（指定、加载、操作 Action、查询 Action）和完成/失败/取消终态；最后一次闲置时使用/重载、零后重载、独立计数、错误快照、32 个在途 Decision、精确字节/数量预算、批量失败回滚、跨会话取消权及失败提交重试。通过实际 Assistant 请求检查后续目录到期、历史证据保留与内部 ReACT 单次结算。用例数量从源码/测试运行报告获取，不在 README 保存某次执行的计数或通过结论。

## 文件归属

- [Assistant](Assistant/README.md)：所属子能力的测试与资源。
- [Core](Core/README.md)：所属子能力的测试与资源。
- [Photographer](Photographer/README.md)：所属子能力的测试与资源。
- [SpeechPerception](SpeechPerception/README.md)：所属子能力的测试与资源。
- [Support](Support/README.md)：所属子能力的测试与资源。
- [Writer](Writer/README.md)：所属子能力的测试与资源。
