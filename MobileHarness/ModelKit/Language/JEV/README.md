# Decision choice / noul / decide

## 职责和边界

DecisionCapability 提供 choice(DecisionRequest) 和 noul(NoulRequest)。choice 返回合法候选及可选分数或 abstained；noul 返回 NoulResult(value: Bool, score: Double?)，score 为 true 的未校准估计，失败抛出而不是 false。请求包括文本、问题和 InferenceContext；候选唯一且非空、至多255项，文本至多20 KiB。调用者解释业务含义并拥有队列和打断，ModelKit 不访问上层状态。ModelDecisionContainer 按所选 ID 分发三个接口，不能在容器层重建提供者的布尔候选。

## D3 执行

ModelKitD3 独立编译 D3Decision，依赖 ModelKitCoreAI 和现有 Tokenizers。默认端口 language.decision 使用 d3-edge。Edge 制品目录为 D3Edge。加载 manifest、decision_config、tokenizer，以及源图或匹配设备架构的编译图，并校验 512 token、255 项候选读出及输入名称。文本接口传入 `input_ids`、`attention_mask` 和 `position_ids`。适配器按 manifest 和实际图校验三输入或五输入。三输入图仅接收文本张量，五输入图在 ModelKit 内另绑定全零 Float32 视觉向量与全 false Bool 掩码。业务使用统一的文本 DecisionRequest 和 DecisionResult。固定 chat template 关闭 thinking，短输入左填充，position_ids 为四组同序位置；超长输入明确失败，不截断。GraphModel 使用系统默认 specialization，与发布制品验证路径一致。

一个资源租约执行一次 stateless 图并输出一个 DecisionResult；按当前候选数量裁取 logits 后 softmax。InferenceTaskControl 取消并加入原生执行，再释放租约。下载、加载和卸载由 ModelKit 资源体系拥有；调用者不得以超时冒充资源释放。

真实权重和测试证据见 [全双工验证](../../../../docs/validation/Assistant-Full-Duplex.md)。[Language](../README.md) · [CoreAI](../../Support/Backends/CoreAI/README.md)

D3 manifests may declare compiled_models mapping the native architecture to decision.<architecture>.aimodelc. Compiled manifests require an exact architecture match; missing or malformed entries fail explicitly. Source manifests without compiled_models load decision.aimodel as before. The provider exposes the iOS physical-device architecture to default artifact assembly; Mac benchmark and simulator assembly return no iOS architecture. Tokenization, graph inputs, readout and compute placement are identical for source and compiled graphs.


## Vela 与布尔适配

VelaDecision 与 D3Decision 位于现有 ModelKitD3 编译目标，共用基础契约、CoreAI 和 Tokenizers。Vela 注册 ID 为 vela3-fast，目录 Vela3Fast。固定制品使用 CPU-only specialization、动态序列（最多32768 tokens），输入 input_ids、attention_mask、option_positions、pool_mask；输出 logits 按候选 softmax。原生序列为 BOS/Q/问题/O/候选/SEP_SCHEMA/SEG_user/文本/EOS，pool_mask 覆盖 SEG_user 至正文末尾，不含 EOS。

D3 的 noul 编码使用官方 No / false、Yes / true；Vela 使用 no、yes。两者以 false/true 顺序复用候选评分，映射成功布尔值及 true 分数，平分选择 false。映射会话拥有取消与 joined cleanup，非法、缺失或多个结果明确失败。ChatDecision 为既有 Chat 模型提供通用 choice/noul：严格 JSON 字符串或布尔文本、正常完成、无工具执行；格式失败不制造默认值。Assistant 无格式分支。

资源接入见 [Management](../../Support/Management/README.md)。Swift 原生二分类与历史实验分开记录于 [二分类验证](../../../../docs/validation/Decision-Binary-Interrupt-Mac-Comparison.md)。

## 多问题接口

`decide(MultiDecisionRequest)` 与 choice、noul 并列，共享 text 和 InferenceContext；questions 按数组排列，1–32 题，ID 唯一且非空。DecisionQuestion.Kind 可混合 choice(instructions:candidates:) 与 noul(instructions:)。MultiDecisionResult.answers 按问题 ID 返回 DecisionAnswer.choice / .noul。

默认实现顺序调用提供者自身的单题接口，各题独立推理，不共享编码或合并成一次图执行。会话拥有任务，输出容量为一个聚合结果；任一题失败停止后续题并传播错误，不发部分结果。取消会加入当前子会话清理，不再开始后续题。每题必须恰好返回一个结果。D3、Vela、ChatDecision 共用此执行机制，保留各自单题格式。ModelDecisionContainer 转发给所选 provider；Assistant 只使用 noul，不调用此接口。

```swift
let request = try MultiDecisionRequest(text: "请停一下，改成中文。", questions: [
    DecisionQuestion(id: "interrupt", kind: .noul(instructions: "用户是否明确要求停止或改变当前回复？")),
    DecisionQuestion(id: "language", kind: .choice(instructions: "用户要求哪种语言？", candidates: ["中文", "英文"]))
])
let session = try await decision.decide(request)
try await session.withCleanup {
    for try await result in session.events {
        // result.answers["interrupt"] is .noul; result.answers["language"] is .choice.
    }
}
```
