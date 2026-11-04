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
