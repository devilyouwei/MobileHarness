# Evaluation scenarios

Purpose: Own synthetic conversational inputs and archived prompt controls for Agent evaluation.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- cases.json contains evaluation scenarios; it does not define SDK behavior or production Actions.

✅ qwen-workflows.json 是 flash/plus/max 共用的有版本合成流程集，包含场景初始公开事实/Skill/Task、用户输入及调用断言。允许与禁止行为由用例定义，不在请求里提示答案；设备结果通过 IntegrationTests 的执行替身返回。真实模型与执行替身的结果分别记录。

✅ 六个 expression-sequence 专项场景覆盖指定四项纯串行、全部静默、三项逐项介绍、全部逐项介绍、逆序与多轮改序、已存在无关 Task 时保持原目标。expressionSequence 给出表情列表，unorderedExpressions 仅允许未指定顺序的全量集合重排，expressionSpeech 指定每项是否必须配套名称语音；这些判定字段不注入模型请求。

用例需要区分查询旁支与替换目标：未声明放弃原任务的查询可保留原 Task 并执行；明确考虑替换、又未决定结束旧任务时才要求先澄清。修改判定必须保留原始运行，单独记录修订后的复查，不能覆盖原失败。

## 待实现

- Representative user-study coverage and semantic acceptance scoring.

全 Action 迁移保留 qwen-workflows.json 的全部业务输入/断言与稳定 ID；部分 ID/category 含 tool/native 是既有场景身份，不声明当前调用协议。协议由真实生产目录和额外 Action-only/no-native 校验确定。

Robot-prefixed cases cover motor anatomy, signed relative angles, native parameters, ambiguous absolute angle origins, axis limits, readiness, ordered multi-motor/gesture composition and conditional failure. `robotSequence` asserts the exact count, order, axis and required parameters of every NexArm call; it is evaluation data and is never injected into model prompts. The full fixture is bounded to 96 scenarios.

writer-window-discover-read/maximize从默认目录开始；公开Writer artifact窗口身份来自合成State。用户只要求看文字或放大，断言按需加载与指定ID的XML Action，不把评分字段注入请求。

skill-discovery 场景覆盖默认目录的“浏览b站”和直接 URL、已加载浏览不重载、访问失败不重试、普通网站知识不联网及未提供的视频控制。用例不把 Skill ID 写入用户输入；必需调用、轮次隔离、次数和 Task 状态仅用于评分。Web 返回值由执行替身提供，实际模型回复的能力边界仍需审阅证据。

basic-task-confirm-completion 使用等待用户选择的通用前台目标，用户明确选择并确认完成后检查 task.end 和真实终态，不依赖摄影预览或保存夹具；评分字段不进入模型输入。旧 task-continue 的媒体参数适配限制保留在 BasicSkill 控制教学验证记录中。

## Writer prompt matrix

writer-workflows.json owns 28 scenario groups (30 independently executed cases), synthetic saved works, user goals, host events and assertions. writer-evaluation.json owns the two-model experiment selection, thinking policy and evaluation bounds; credentials remain in ignored local configuration. Assertions are never appended to model prompts. Explicit continuation receives a real saved-work reference; lookup/edit cases receive no preselected target.

Runtime matrix polling and artifact inspection resolve the current task through the request association after Writer selects an existing work. Selection is performed by the production Writer tool, not by scenario title matching or caller binding.
