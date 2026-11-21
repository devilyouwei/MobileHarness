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
- State：AssistantStateBindings、AssistantChatStatus

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
