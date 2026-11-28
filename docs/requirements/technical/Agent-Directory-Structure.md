# Agent 目录结构（2026-11-21，已实施）

问题：`Agents/Assistant/` 平铺 26 个文件，`Agents/Writer/` 平铺 12 个，职责混杂；`Resources/Agents/Assistant/` 的 control、输入、提示词资源也平铺。用户确认按职责分目录，范围为 Assistant 与 Writer，资源目录同步拆分。

## 骨架

一级目录只放 Agent 对外暴露的入口、容器、会话和 README。其余按职责下沉；文件少的 Agent 保持平铺。

| 目录 | 职责 |
| --- | --- |
| `Controls/` | 本 Agent 的 control：声明加载、门槛、事务 |
| `Input/` | 进入 Agent 的一切：输入分类、批处理、决策、中断、预处理 |
| `Output/` | 离开 Agent 的一切：发射、语音与字幕、表情、Island 与 UI 呈现、反馈、失败呈现。呈现属于输出，不单列 |
| `Workflow/` | 业务编排与领域规则：Decision/ReACT、模型请求构造、历史投影、生成传输、任务与委派、生命周期、恢复 |
| `State/` | 状态绑定、快照与对外状态投影 |

## Assistant

- 一级：AssistantAgent、AssistantContainer、AssistantExecutionSession、AssistantProcessing
- Controls：AssistantControls、AssistantControlExecution
- Input：AssistantChatInput、AssistantInputBatch、AssistantInputDecision、AssistantInterrupt
- Output：AssistantChatEmission、AssistantSpeechOutput、AssistantChatFeedback、SpeechPlaybackFailure
- Workflow：AssistantChatWorker、AssistantChatContext、AssistantChatLifecycle、AssistantChatGeneration、AssistantGenerationTransport、AssistantHistoryProjection、AssistantChatTaskCommunication、AssistantChatPeerEvents、AssistantSessionControl
- State：AssistantChatStatus。容器快照到模型业务上下文的适配由 Support/Context 和 Support/Chat 共用。

## Writer

- 一级：WriterAgent、WriterContainer
- Input：WriterRequestNaming
- Output：WriterIslandPresentation、WriterPreview
- Workflow：WriterWorkflow、WriterTools、WriterRecovery
- State：WriterRecords、WriterHistory、WriterDiagnostics

## 资源

`Resources/Agents/Assistant/`：一级 `Agent.json`、`Instructions*.md`；`Controls/` 放 `Controls*.json` 与 `Controls*.md`；`Input/` 放 `InputProtocol*.json`、`InputDecision*.json`。`Prompts*.json` 与 `Instructions*.md` 留在一级：`AgentPrompts.promptPath` 以 Agent.json 同级的 `Prompts.json` 为所有 Agent 的统一约定。路径常量与 `verify-app-agent-resources.py`、boundary checker、README 链接同步更新。

## 约束

只移动文件，不改行为；Swift target 与依赖边界不变。验证：`./scripts/check.sh` 各步骤与 `./scripts/build-ios.sh`。

## 实施结果

文件已按上表移动；Xcode 工程文件引用与分组、`AgentConfigurations`/提示词路径、`verify-app-agent-resources.py`、boundary checker 的路径与 README 链接同步更新；每个新目录有 README。

## 三个感知角色的目录与 Tool 回执

VisionPerception、Photographer、ApplicationControl 以 SpeechPerception 为参照，经角色绑定的端口发送独立的 Tool 请求，并直接消费相应回执。相机操作和应用设置按原请求推进事务，失败进入原有的清理和呈现流程。三个角色移除旧执行反馈订阅。加载与蓝牙状态的展示调用由发送处在返回、抛错或取消时释放在途记录。

四个感知角色共用 Input、Workflow、Output 三种目录，分别放角色输入、处理策略、输出编码或派发。根目录放角色入口、容器和会话装配。SpeechPerception 本身仅调整文件位置与文档。同步角色 README、总体设计、Xcode 工程引用、边界检查与回归测试。

## 视觉与摄影角色合并

VisionPerception 统一注册和消费相机、相册、固定任务及跟踪请求。姿态模型和原生帧订阅随独立采集代启停，视觉关闭后摄影事务仍可用。姿态结果直接驱动本地跟踪，并保留独立的姿态发布。合并角色配置、能力校验、设备资源归属、容器状态与 App 装配；保持已发布业务载荷、Actions 协议、请求回执与 Gateway 传输。输入、工作流、输出文件按职责归入 VisionPerception 对应目录。使用配置、相机、姿态、跟踪、独立调用和生命周期回归及模拟器构建验证。

## Memory 认知角色

Memory 根目录持有角色、子容器和会话。Input 放历史 UI、Task 意图、信号预处理与输入选择，Workflow 放历史事务和单次标题推理。Memory 的上下文记录随角色入口维护，容器直接投影通用角色与任务状态。当前没有独立对外的业务状态机，省略 State 目录。Memory 在角色装配中声明历史事务使用的内部 Tool，使用角色绑定的 callTool 等待真实回执，调用点推进事务；Gateway 和 Assistant 的共享 Skill 绑定保持原有语义。历史操作和单次标题请求按实际请求关联，不建立模型轮次。同步更新角色配置、目录索引、Xcode 分组、边界检查和历史回归。

## Agent Skill 装配范围

只有 Assistant 和 Writer 的模型上下文加载 Skill。三个 Perception 角色与 Memory 的 Agent.json 省略 skills，AgentConfigurations 对这些资源跳过 Skill 解析。各角色在描述符中声明业务工作流需要的内部工具，Assistant 的等待动画等内部 Tool 沿用同一机制。通过角色配置、模型目录、内部调用授权测试以及工程检查与 iOS 构建验证。

## 六个角色的输入、工作流与输出

在六个角色内部按实际调用职责整理 Swift 文件。Input 拥有信号接收、解码、筛选、批次和请求准入；Workflow 拥有业务判断、事务推进、推理与恢复；Output 拥有对外调用、发布、呈现映射及回执交付。根入口保留注册、依赖与生命周期，角色私有持久化上下文与容器公开状态区分。拆开 Assistant 的输入选择与会话上下文、Writer 的任务入口与报告、Speech 的识别与发布、Vision 的相机请求与派发、ApplicationControl 的设置和资源流程、Memory 的历史请求与执行。同步维护角色 README、Xcode 分组和工程检查引用，使用现有测试覆盖各角色。
