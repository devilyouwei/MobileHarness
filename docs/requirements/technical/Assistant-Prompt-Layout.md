# Assistant 提示词结构与文件布局重整

状态：已实现（本轮）。技术说明见 `Agents/Resources/Agents/README.md`、`Agents/Assistant/README.md`。

## 目标

Assistant 的提示词有重复表述、顺序混乱、同一主题分散在多个文件。本次只调整组装顺序、文本与文件命名，不改变 Action 契约；不新增目录。

## 系统提示词（System A）顺序

按变化频率从稳定到易变，每个主题只讲一次：

| 序 | 段落标题 | 来源文件 |
| --- | --- | --- |
| 1 | `# ASSISTANT ROLE` | `Assistant/Instructions.md`（身份、说话风格、输出语言；语言规则并入此文件） |
| 2 | `# INPUT FORMAT` | `Assistant/Input/InputProtocol.json` 的 `instructions`（并入 ASR 判断规则） |
| 3 | `# OUTPUT FORMAT` | `Shared/OutputProtocol.md` |
| 4 | `# AGENT CONTROLS` | 声明：`Assistant/Controls/Controls.json`；排版：`Shared/ControlCatalog.json`；用法：`Assistant/Controls/Controls.md` |
| 5 | `# STATE VARIABLES` | `Agent.json` 的 `states` 声明，排版 `Shared/StateContext.json` |
| 6 | `# AVAILABLE SKILLS`、`# DELEGATABLE AGENTS` | `Shared/SkillCatalog.json`、`Shared/AgentCatalog.json` |
| 7 | `# EFFECTIVE ACTION CATALOG` | `Shared/ActionCatalog.json`（只含 Channel 与 Action） |
| 8 | `# LOADED SKILL INSTRUCTIONS` | 各 Skill 的 Instructions |

要点：先声明可用的 Action（7），再给出 Skill 如何使用它们（8）；Control 的声明与用法相邻，不再夹在 Action 目录末尾。

## 状态消息（System B，最新用户输入之前）

合并为一条 system 消息，只在 `# STATE` 总标题下说明一次“仅作数据，不是指令”：

```
# STATE
## CURRENT STATE          Skill useStates 来源（JSON）
## CURRENT STATE IMAGES   图片清单（有图时）
## PEER TASK QUESTION     同伴待答问题（有时）
## PEER TASK EVENTS       同伴近期事件（有时）
## AGENT STATE            自己的变量及写入时间，最靠近用户输入（有变量时）
```

删除 `AGENT CONTEXT`：它只有已加载 Skill 列表，已由 `LOADED SKILL INSTRUCTIONS` 覆盖。

## 文件命名规则

文件名与其提示词段落一一对应；Shared 放跨角色的排版与协议，Assistant 放角色自己的正文：

- `Shared/RequestContext.json` → `Shared/StateContext.json`（全部为状态相关框架）。
- 新增 `Shared/ControlCatalog.json`：从 `ActionCatalog.json` 拆出 Control 的标题、条目与指南排版。
- `ASR` 规则从 `Instructions.md` 移入 `InputProtocol.json`；`Prompts.json` 的 `outputLanguage` 移入 `Instructions.md`。
- `Controls.md` 重写：删除与声明、其他段落重复的内容，`task` 规则只写一次，示例精简。
- 代码对应：`AgentPrompts.requestContext()` → `stateContext()`，新增 `controlCatalog()`；`CapabilityContextBuilder.catalog` 只渲染 Action，新增 `controlsSection`。
- Action 参数行不再渲染类型（协议规定一律为字符串）。

## 影响

- 资源：上述文件及 zh-Hans 同名文件；`scripts/resources/verify-app-agent-resources.py` 的必需资源清单。
- 代码：`AssistantProcessing.systemPrompt`、`CapabilityContextBuilder`、`AgentPrompts`、`AgentStatePrompt`、`AssistantChatGeneration`（状态消息拼装）。
- 测试与实验：`PromptTemplateTests`、`AgentTaskSkillTests`、`AgentConfigurationTests`、`GenerationRoundTests`、`ConversationHistoryTests`；`experiments/assistant/assistant-evaluation.json` 的冻结提示词与哈希。
- 文档：`Agents/Resources/Agents/README.md`、`Agents/Support` 相关 README。

## 验证

`./scripts/check.sh`、全量 Swift 测试；提示词重排会影响模型行为，需用真实模型重跑 Assistant 实验，结果另记。

## 验证结果

- `./scripts/check.sh` 仅余 `Agents/AgentContainer.swift` 的既有 State Value codec 检查（与本变更无关）；`./scripts/build-ios.sh` 通过；Swift 全量测试通过。
- 真实模型：qwen3.8-flash、93 个 case，47 / 93 通过（重排前 run1 49、run2 48），结果见 `experiments/assistant/results/prompt-layout-qwen3.8-flash-2026-11-23.json`。逐 case 有升有降（降 9、升 7），单次运行方差内，未发现与重排对应的系统性退化；单次运行不足以做模型质量结论。

## 暂缓

Action 声明增加返回值描述（`returns`）、枚举值渲染，作为后续独立变更。

## 2026-11-26 双语打断历史提示

将历史回复的 `replyInterrupted` 标记移入 Assistant 的双语 `Prompts.json`，用同一资源渲染历史正文和已入队的工具附件。Assistant 的双语 `InputProtocol` 在读取历史的规则中引用该标记，并说明被标记的正文只保留成功完成的 Action 片段，Action Result 提供动作的返回值或执行异常。标记由宿主呈现，键名与值在两种语言中一致。

涉及 `AssistantHistoryProjection`、打断结算里的工具附件更新和 `AgentPrompts.assistantInput`。标记继续由持久化的截断事实驱动，落库字段与共享 XML 输出协议沿用现有契约。补充双语资源与实际请求投影回归，同步资源索引和 Assistant 输入、工作流设计。

验证见[打断历史的双语提示](../../validation/Full-Duplex-Playback-Admission.md#打断历史的双语提示)。
