# Decision choice / noul / decide

## 职责和边界

DecisionCapability 提供 choice(DecisionRequest) 和 noul(NoulRequest)。choice 返回合法候选及可选分数或 abstained；noul 返回 NoulResult(value: Bool, score: Double?)，score 为 true 的未校准估计，失败抛出而不是 false。请求包括文本、问题和 InferenceContext；候选唯一且非空、至多255项，文本至多20 KiB。调用者解释业务含义并拥有队列和打断，ModelKit 不访问上层状态。ModelDecisionContainer 按所选 ID 分发三个接口，不能在容器层重建提供者的布尔候选。

## D3 执行

ModelKitD3 独立编译 D3Decision，依赖 ModelKitCoreAI 和现有 Tokenizers。默认端口 language.decision 使用 d3-edge。Edge 制品目录为 D3Edge。加载 manifest、decision_config、tokenizer，以及源图或匹配设备架构的编译图，并校验 512 token、255 项候选读出及输入名称。文本接口传入 `input_ids`、`attention_mask` 和 `position_ids`。适配器按 manifest 和实际图校验三输入或五输入。三输入图仅接收文本张量，五输入图在 ModelKit 内另绑定全零 Float32 视觉向量与全 false Bool 掩码。业务使用统一的文本 DecisionRequest 和 DecisionResult。固定 chat template 关闭 thinking，分词后保留末尾最多 512 个 token，短输入左填充，position_ids 为四组同序位置；空序列或无法表示的 token ID 明确失败。截断可能移除系统提示、上下文或极长问题及选项的前部。GraphModel 使用系统默认 specialization，与发布制品验证路径一致。

一个资源租约执行一次 stateless 图并输出一个 DecisionResult；按当前候选数量裁取 logits 后 softmax。InferenceTaskControl 取消并加入原生执行，再释放租约。下载、加载和卸载由 ModelKit 资源体系拥有；调用者不得以超时冒充资源释放。

真实权重和测试证据见 [全双工验证](../../../../docs/validation/Assistant-Full-Duplex.md)。[Language](../README.md) · [CoreAI](../../Support/Backends/CoreAI/README.md)

D3 manifests may declare compiled_models mapping the native architecture to decision.<architecture>.aimodelc. Compiled manifests require an exact architecture match; missing or malformed entries fail explicitly. Source manifests without compiled_models load decision.aimodel as before. The provider exposes the iOS physical-device architecture to default artifact assembly; Mac benchmark and simulator assembly return no iOS architecture. Tokenization, graph inputs, readout and compute placement are identical for source and compiled graphs.


## Vela 与布尔适配

VelaDecision 与 D3Decision 位于现有 ModelKitD3 编译目标，共用基础契约、CoreAI 和 Tokenizers。Vela 注册 ID 为 vela3-fast，目录 Vela3Fast。固定制品使用 CPU-only specialization、动态序列（最多32768 tokens），输入 input_ids、attention_mask、option_positions、pool_mask；输出 logits 按候选 softmax。原生序列为 BOS/Q/问题/O/候选/SEP_SCHEMA/SEG_user/文本/EOS，pool_mask 覆盖 SEG_user 至正文末尾，不含 EOS。

D3 的 noul 编码使用官方 No / false、Yes / true；Vela 使用 no、yes。两者以 false/true 顺序复用候选评分，映射成功布尔值及 true 分数，平分选择 false。映射会话拥有取消与 joined cleanup，非法、缺失或多个结果明确失败。ChatDecision 为既有 Chat 模型提供通用 choice/noul：严格 JSON 字符串或布尔文本、正常完成、无工具执行；格式失败不制造默认值。Assistant 无格式分支。

资源接入见 [Management](../../Support/Management/README.md)。Swift 原生二分类与历史实验分开记录于 [二分类验证](../../../../docs/validation/Decision-Binary-Interrupt-Mac-Comparison.md)。

## 多问题接口

`decide(MultiDecisionRequest)` 与 choice、noul 并列，共享 text 和 InferenceContext；questions 按数组排列，1–32 题，ID 唯一且非空。DecisionQuestion.Kind 可混合 choice(instructions:candidates:) 与 noul(instructions:)。MultiDecisionResult.answers 按问题 ID 返回 DecisionAnswer.choice / .noul。

默认实现顺序调用提供者自身的单题接口，各题独立推理，不共享编码或合并成一次图执行。会话拥有任务，输出容量为一个聚合结果；任一题失败停止后续题并传播错误，不发部分结果。取消会加入当前子会话清理，不再开始后续题。每题必须恰好返回一个结果。D3、Vela 3/3.1、Laya、ChatDecision 共用此执行机制，保留各自单题格式。ModelDecisionContainer 转发给所选 provider；Assistant 只使用 noul，不调用此接口。

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


## Vela 3.1 与 Laya

同一DecisionCapability还由Vela31Decision（vela3.1-fast/Vela31Fast）和LayaDecision（laya-multilingual/LayaMultilingual）提供。注册、下载、选中、资源保留、取消加入及卸载沿用既有模型生命周期，失败不切换其他模型。Assistant只调用noul，所有provider支持默认顺序多问题decide。

Vela31Decision解析full-coreai/1 manifest中的decision组件，按F32 safetensors的映射绑定只读weight输入；CPU-only图接收input_ids、attention_mask、q_index、opt_index、unit_index、ent_index，返回候选logits。q_index保留Q位置及正文pool区间，候选按O位置读出。noul保持no/yes两项，32768 token容量超限抛错，不截断。

LayaDecision接收平台对应bundle根目录；App下载iOS portable JIT wfp16-s512源图，用stripPrefix安装到LayaMultilingual。Mac实验直接传入macos/wfp16-s512目录，不能加载iOS图。GPU公开specialization加载一次模型并共享main/act函数。序列为CLS/type question/instructions/SEP/MASK options/SEP/state/SEP，右填充512。候选至多48 token、问题及候选head预算256；凡上游会截掉正文/问题/选项的请求明确拒绝。按发布协议处理文本中的mask字面量，不加入业务噪声词表。

Laya的choice与noul具有不同qtype_onehot和原生选项；noul用false/true解释文本，并从true概率读取布尔值。main输出token_logits及pooled_cls，host在marker处取值并构造act四维特征；act输出验证后不作为上层路由覆盖。候选温度先按type/候选数量分桶，再用制品声明的type温度；按发布协议四位小数、noul严格>0.5。choice保持argmax。输入失败、加载失败、取消或非法输出均传播错误，不制造false或代替分类。

LayaTokenizer在内存中将发布Metaspace的prepend_scheme=always映射为当前swift-transformers所需的add_prefix_space=true；不修改下载文件。该兼容层仅适用于声明了该契约的Laya tokenizer，防止词首token差异改变模型语义。
