# 基础 Skill 常驻时的调用协议小范围对照

状态：✅ 千问小范围对照完成；❌ GPT‑4.1 因 HTTP 401 未获得模型输出。仅实验，不改变生产 Skill 注册或调度规则。

## 问题与方法

BasicSkill 含 Action 且常驻，按 Skill 分开 Action/Tool 仍会在多 Skill 请求中暴露两种协议。本实验比较同 Skill 混合、分 Skill 混合、全部 Action 三组，使用 GPT‑4.1、qwen3.8-flash、qwen3.8-max。保持函数业务语义、参数、反馈与每场景目标一致；基础控制始终注册为 Action。全 Action 是假设性注册，查询也返回业务值，不将 query 的 report 伪装成 value。

选关闭相机、扫描后查询、查询后打开页面、创建任务并加载 Skill 后扫描查询再结束任务四类，逐组重复三次并轮换顺序。Task/Skill 控制独占响应，依赖后续步骤必须经过下一请求的模拟结果。读取结果和任务/技能执行均为合成替身，不执行真实设备。单次错误终止，不修复名称、不重试。临时实验脚本随测量归档；不新增生产脚本或目录。

## 验收边界

输出协议、名称、参数、依赖分轮、重复操作与结束任务顺序分别判定。API 访问失败单独报告。最小提示词不等于完整生产提示词，本轮不能替代原53场景回归、调度器或物理验收。读代码分析查询注册为 Action 后的 Channel、反馈值、ReACT 和权限约束。

## 代码分析：全 Action 的条件与影响

查询能力可以作为 Action 返回 `.value(String)`；AgentChatWorker 对 ActionResult 读取该业务值，并在完整轮次屏障结束后继续推理。`.completed`、`.report`、activity 开始/停止回执不等于查询数据，不能代替 `.value`。现有 GenerationRoundTests 同时覆盖 Action、Tool、mixed 三条路径的有值/无值和失败续轮。

现有生产 BehaviorProtocolBindings 将 History.Conversation、System.Provider 等查询投影为 Tool-only；AgentConfigurations 根据 Skill.callType 创建不同公开能力，CapabilityRegistry 分别解析 Action/Tool。若真正改成全 Action，必须同步执行绑定、Skill 声明、允许 Channel、权限、提示词及测试，而不是收到错误 native 名称后在运行时改成 Action。ActionDispatcher 将 Action 交给 ChannelScheduler；ToolDispatcher 的直接并发路径与 wait 隔离语义会改变。查询需要选择明确 Channel，避免不必要地排在长动作之后；因果依赖仍须获得真实结果后再决策。

基础 Skill 常驻意味着“每 Skill 一种协议”只是配置组织限制，无法保证请求协议单一。若坚持 Action 用于调度、Tool 用于直接执行，需要承认同请求存在两种协议，或者另行设计按请求阶段筛选能力；后一种还须处理跨轮依赖、Task/Skill 控制和可用能力选择。全 Action 是主动统一执行入口的架构选择，并非拆 Skill 的自动推论。

本报告不修改生产行为。OpenAI 官方 GPT‑4.1 指南包含 Responses 函数调用示例；本实验保留用户指定的 gpt-4.1 模型名。参考：[GPT‑4.1 Prompting Guide](https://developers.openai.com/cookbook/examples/gpt4-1_prompting_guide)。

## 2026-10-17 实测结果

| 模型 | 一个 Skill 内混合 | 按 Skill 拆开、请求仍混合 | 全部 Action |
| --- | --- | --- | --- |
| qwen3.8-flash | 1/12 | 4/12 | 12/12 |
| qwen3.8-max | 7/12 | 10/12 | 12/12 |
| gpt-4.1 | 未完成：首次请求 HTTP 401 | 未执行 | 未执行 |

每个千问模型实际完成36个 trial，四场景各重复三次；共72个模型输出 trial、151次千问请求。GPT‑4.1 向官方 `https://api.openai.com/v1/responses` 发出一次请求返回401，随后停止该模型，不重试或换端点；这不是模型调用能力失败，不计入通过率。总计73个尝试、152次 HTTP 请求。使用用户此前指定 ENV 中的对应凭据，不记录明文，不修改 ENV，不上传手机对话或媒体。

各场景通过次数（每格三次，顺序为“同 Skill 混合 / 分 Skill / 全 Action”）：

| 场景 | flash | max |
| --- | --- | --- |
| 基础 Action 常驻，关闭相机 | 0 / 2 / 3 | 3 / 3 / 3 |
| 基础 Action 常驻，扫描成功后查询 | 0 / 0 / 3 | 3 / 3 / 3 |
| 基础 Action 常驻，查询配置后打开设置 | 0 / 1 / 3 | 0 / 1 / 3 |
| 创建任务、加载 Skill、扫描、查询、结束任务 | 1 / 1 / 3 | 1 / 3 / 3 |

分 Skill 组仍有明确的 Action-as-native 错误：flash 在关闭相机时输出原生 `closeCamera`，结束任务时输出原生 `finishTask`；max 查询配置成功后把 `openPage` 输出成原生调用。反向错误也存在：max 在同 Skill 混合组两次把原生 `Bluetooth.readStatus` 写成 XML。flash 另有格式错误、多调用/依赖未分轮、控制调用夹带旁白和查询参数错误。归档保留全部失败，不把它们都称作同一种 invalidResponse。

**本轮支持“拆 Skill 不能保证不混协议”；全 Action 在所选场景中更稳定。** 这不证明 Skill 分组本身是唯一原因：分组会改变教学文本；重复仅三次。也不证明全 Action 已适合完整生产流程。各组使用最小合成提示词和简化参数，Task/Skill 加载通过确定性反馈模拟；分 Skill 是模型可见目录分组，并未改变真实资源配置/依赖加载器。全 Action 没有原生声明；基础控制和查询/操作均为 XML。查询结果真实进入下一次实验请求，但未通过生产 Gateway 执行。

统一 Action 将改变当前“需协调的 Action / 直接执行的 Tool”划分；它是可实施但需明确接受的设计取舍。保留两类职责也合理，此时不能靠每 Skill 单协议来保证请求单协议。需要进一步改善混合调用教学，或单独设计请求级能力筛选。当前没有替用户实施其中任何一种架构迁移。

## 验证、复现与限制

- [完整请求、公开响应、判定和临时脚本源码](../measurements/skill-protocol-focused-2026-10-17.json)保留四场景、十个函数定义、完整原生名称、动态目录、逐轮模拟结果、失败及计数。附带本轮临时脚本和导入的原对照脚本源码/hash；临时主脚本运行期间未改变。没有完整 SSE wire 捕获，Provider reasoning 项未存档。未取得 GPT‑4.1 的可比较结果。
- 临时脚本离线验证通过12个正向 fixture trial，验证声明分组、全 Action 无 native 声明、动态 Task/Skill 目录和原始 native call_id 配对；既有协议判定离线5测试通过，覆盖错名、错协议、参数及依赖分轮。
- 已构建测试二进制的定向复查通过3个测试声明/13个参数情况：`generationRoundActualOutputControlsContinuationForAllThreeRoutes`、`generationRoundVoidSuccessStopsAndFailuresContinueWithoutReplay`、`generationRoundToolBypassesWaitButContinuationJoinsEveryAction`。其中 Action 返回值可触发下一轮，纯完成不触发，失败保留反馈，不重放效果。这是生产框架加确定性替身，与云协议实验分开。
- 本轮仓库只添加测量/报告并更新文档；实验脚本在 `/tmp`，源码随数据归档。不改生产协议/注册，不增加目录。未为本轮冻结全部生产源码；上述 Swift 复查使用 `--skip-build`，不作新编译结论。未重复全量 check.sh 或 build-ios.sh；此前全量失败和 Simulator 外部 CoreAI 限制不因本轮通过而消失。
- 请求预算每模型100次、每 trial 六轮、每请求网络/接收期限90秒、单行64 KiB/整体8 MiB；不做自动重试或错误名称回退。只判定请求的调用序列，到最后所需调用即结束，不验证最后一次自然语言总结、Channel/wait 嵌套、生产取消/容量或物理效果。
- 主机临时证据：`/tmp/skill_protocol_focused.py`、`/tmp/skill-protocol-20261017-focused1*.json/.log`、`/tmp/skill-protocol-20261017-framework.log`、`/tmp/skill-protocol-20261017-offline.log`。没有安装、commit 或 merge。原53场景报告和原失败记录保持不变。
