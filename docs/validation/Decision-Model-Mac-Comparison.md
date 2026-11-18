# Mac 本地 Decision 模型对照

本报告保留此前的多分类实验和相关验证记录。D3 Edge 与 Vela3 Fast 的三波打断二分类实验见[独立报告](Decision-Binary-Interrupt-Mac-Comparison.md)。

日期为 2026-11-11，设备为 Apple M5 Mac，macOS 27.2（26B123）。Python 3.13、coreai-core 1.0.0b3、PyTorch 2.14.0、Transformers 5.17.0、tokenizers 0.23.3。

## 方法

复用 [D3 转换实验](D3-Edge-CoreAI.md) 的 48 条冻结中文合成样例、三套提示词、候选顺序与预期标签。三个模型串行离线执行。状态、问题和选项描述保持一致，各模型按自己的原生协议编码并读取候选分数，以最高分选一项。测试模型原始判定，Assistant 的交互保护和回退不参与计分。

另按 [Assistant 全双工与 Decision 验证](Assistant-Full-Duplex.md) 的八条原生业务探测复用请求文本、指令、候选顺序与标签。该组与 48 条样例有重合，独立计分。

- D3 使用已发布的文本 Core AI 制品，revision `0690c04ee1640c1c3fa11a882323751dda6d086a`，默认 specialization，固定 512 token。
- Laya 使用 322M FP16 Core AI 制品，revision `28067764ee0f4b43058116248d7706ffd1a5f589`。制品文件逐项通过发布清单的 SHA-256 核对。默认 specialization，按真实编码长度选 L96、L256 或 L512。采用 Laya 的问句与候选标记编码，编码源码 revision `a51fa1751fbb90c4a322bd1d42eed941179a2573`。[制品](https://huggingface.co/smdesai/laya-multilingual-coreai) · [编码源码](https://github.com/mizorewww/laya-coreml/tree/a51fa1751fbb90c4a322bd1d42eed941179a2573)
- UniMC 使用发布的 FP32 safetensors，revision `35272b4ad273e681455b696414bd264f2a15f6e6`，PyTorch CPU 四线程。复用作者的推理编码、候选间 attention mask 和候选位置“是”字 logit。将旧版 tokenizer 调用和 BERT 掩码表示适配到 Transformers 5，权重全部加载，模型卡的新闻样例输出“汽车”。[制品与示例](https://huggingface.co/IDEA-CCNL/Erlangshen-UniMC-RoBERTa-110M-Chinese)
- 每组预热三次，随后每条测一次，延迟含分词、推理与结果读出。候选模型的耗时使用各自所列后端。应用、ASR 和 TTS 并发负载未纳入。

## 结果

48 条中有 11 条预期打断、14 条预期丢弃、23 条预期入队。误打断为将后两类预测成打断，误丢弃为将应打断或入队的输入预测成丢弃，漏打断为将应打断的输入预测成另外两类。一次错误可能同时计为误丢弃和漏打断。

| 提示词／请求格式 | 模型 | 正确 | 误打断 | 误丢弃 | 漏打断 | p50 / p95（ms） |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 中文长规则＋JSON 状态 | D3 | 24/48 | 0 | 16 | 9 | 64.3 / 65.5 |
| 中文长规则＋JSON 状态 | Laya | 14/48 | 33 | 0 | 0 | 35.4 / 39.9 |
| 中文长规则＋JSON 状态 | UniMC | 22/48 | 1 | 0 | 11 | 221.2 / 326.6 |
| 中文短规则＋自然文本 | D3 | 34/48 | 11 | 3 | 0 | 65.6 / 70.0 |
| 中文短规则＋自然文本 | Laya | 15/48 | 23 | 10 | 3 | 15.5 / 18.2 |
| 中文短规则＋自然文本 | UniMC | 16/48 | 16 | 16 | 4 | 130.8 / 183.1 |
| 英文短规则＋自然文本 | D3 | 35/48 | 1 | 4 | 6 | 72.4 / 78.3 |
| 英文短规则＋自然文本 | Laya | 15/48 | 7 | 26 | 9 | 15.5 / 17.2 |
| 英文短规则＋自然文本 | UniMC | 11/48 | 37 | 0 | 0 | 140.4 / 199.8 |
| 应用请求格式 | D3 | 5/8 | 2 | 1 | 0 | 72.6 / 73.9 |
| 应用请求格式 | Laya | 3/8 | 2 | 1 | 0 | 14.5 / 15.8 |
| 应用请求格式 | UniMC | 2/8 | 6 | 0 | 0 | 84.2 / 102.8 |

D3 与三组历史记录的候选选择逐条一致，共 144/144。D3 的短中文提示识别了全部 11 次应打断，同时误打断 11 次。短英文提示压低了误打断，但漏掉 6 次应打断。八条应用探测也复现了历史的三处错误。

第二次 Core AI 复跑中，D3、Laya 各自的 152 条判定均保持一致。上表保留首次完整运行的时延。复跑时应用格式组的 p95 分别为 D3 145.2 ms、Laya 24.9 ms，说明当前采样下耗时有波动。额外核对了同一上游 checkpoint 的 12 条公开 Laya FP32 单选参考，token ID、候选标记及最终选择全部一致，softmax 分数最大绝对差为 0.000574。[Laya 参考数据](https://github.com/mizorewww/laya-coreml/blob/a51fa1751fbb90c4a322bd1d42eed941179a2573/benchmarks/results/reference-v0412-fp32-torch214.json)

| 应用探测 | 预期 | D3 | Laya | UniMC |
| --- | --- | --- | --- | --- |
| 对“是否保存文件？”回答“嗯” | 入队 | 丢弃 | 打断 | 打断 |
| “不用停，你继续” | 丢弃 | 打断 | 入队 | 打断 |
| “讲完后解释一下 stop 这个词” | 入队 | 打断 | 打断 | 打断 |
| “帮我拍张照片” | 入队 | 入队 | 入队 | 打断 |

Laya 的较低延迟伴随更差的分类结果。长中文组将 44/48 条判成打断，短英文组误丢弃 26 条。UniMC 长中文组漏掉全部 11 次应打断，短英文组和应用格式组则把所有输入都判为打断。这两款制品在此次设置下都达不到替代 D3 的业务要求。

## 证据与边界

[456 次逐条判定与延迟](../measurements/decision-model-mac-2026-11-11.csv)保留模型、提示词、样例 ID、三类分数、真实 token 数和计算窗口。脚本与模型制品位于本机临时目录 `/tmp/mobileharness-decision-compare.QYtdFu`。

历史短提示词曾用这批样例调试 D3，各组复用相同语料。结果适用于这里的冻结请求，其他模型专用提示词、独立真实转写、并发负载和 iPhone 表现仍待验证。沙盒内首次加载 D3 的 Metal delegate 失败，在获准使用本机加速器后完成复跑。UniMC 初次运行遇到 Transformers 5 移除 `encode_plus`，适配到 tokenizer 的现行调用后完整通过执行。仓库改动限于验证记录和测量数据，应用构建未运行。

## D3 请求格式与句向量追加对照

2026-11-11，沿用同一台 M5 Mac 和 D3 文本 Core AI 制品。核对 [Assistant 请求构造](../../MobileHarness/Agents/Assistant/AssistantInputDecision.swift)、[对话工作器](../../MobileHarness/Agents/Support/Chat/AgentChatWorker.swift)和 [D3 编码及读出](../../MobileHarness/ModelKit/Language/JEV/D3Decision.swift)。

- 应用把来源、采集时间、`occupied`、上下文和用户原话插入多行文本。原话和上下文能包含换行，字段边界在模型文本中没有转义。采集时间为相对时钟值，没有说明其对分类的含义。
- `occupied` 表示生成任务、待完成轮次或回复输入有占用。它不能表达实际播放状态。最近回复片段由模型流式文本逐段累积，最多 160 字，代码没有在新回复开头清空这一缓冲。正在等待的交互文本拼在同一上下文字段，`protectsAnswer` 只在模型返回后参与应用判定。
- D3 provider 将选项按 A/B/C 和候选文本渲染，再使用制品 chat template、512 token 边界及候选读出。应用提供的是三个裸标签。上游 Choice 也支持在每个选项后提供含义。[D3 模型卡](https://huggingface.co/vllm-sr/d3-edge)

继续使用历史 48 条和应用格式 8 条，再加入推理前写定的 20 条合成探测，覆盖短指令、短回答、否定、引用、稍后执行及字段形状的多行原话。历史 48 条用同一套状态重新渲染，非语音、已确认回声和对其他人说话这三类来源为样例已知属性。生产语音来源字段只说明输入来自转写。所有结果是模型的原始候选选择，应用保护和回退未计入。探测中的“拍一张啊”来自已知失败，周边状态是手工构造，原真机请求的占用和上下文未被持久化。

| D3 输入方式 | 历史正确 | 应用 8 条 | 新探测正确 | 新探测误丢弃 | 新探测误打断 | 新探测漏打断 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 当前格式与提示词 | 23/48 | 5/8 | 11/20 | 3 | 6 | 0 |
| 只把状态改成 JSON，同时移除时间 | 14/48 | 2/8 | 6/20 | 9 | 5 | 1 |
| 只为三个选项增加英文描述 | 35/48 | 5/8 | 9/20 | 6 | 4 | 3 |
| JSON 状态＋英文问题和选项 | 24/48 | 2/8 | 6/20 | 9 | 4 | 3 |
| 中文自然状态＋中文问题和选项 | 20/48 | 3/8 | 5/20 | 4 | 11 | 0 |
| 中文自然状态＋英文问题和选项 | 27/48 | 2/8 | 7/20 | 7 | 5 | 2 |

空闲、无上文的“拍一张啊”在六种设置下都判成丢弃。单独替换四个时间值或排列六种候选顺序也保持丢弃。对“要先打开相机吗？”回答“要。”，当前顺序选择入队，另外五种顺序都选择丢弃。在当前格式下，包含换行和字段名的延后请求被判为打断，最高 softmax 约 0.97。此值只表示候选相对分数。这些改写未进入应用。

### 句向量结果

使用 BAAI BGE Small 中文 v1.5，revision `7999e1d3359715c523056ef9478215996d62a620`，23,953,920 参数。PyTorch FP32 CPU 四线程，取归一化 CLS 向量。每类固定六句定义和十二条人工编写的代表例，在线只编码当前输入，复用已编码的原型。岭回归只用这 36 条代表例拟合，系数 0.1，编码器权重冻结。所有分数取最大值对应的类，不设置拒判阈值。[BGE 模型卡](https://huggingface.co/BAAI/bge-small-zh-v1.5)

| BGE 判定方式 | 历史正确 | 应用 8 条 | 新探测正确 | 新探测误丢弃 | 新探测误打断 | 新探测漏打断 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 每类一句定义 | 11/48 | 2/8 | 3/20 | 0 | 17 | 0 |
| 每类六句定义，类内取最大 | 20/48 | 5/8 | 6/20 | 7 | 7 | 1 |
| 每类六句定义，类内取前两名均值 | 19/48 | 4/8 | 6/20 | 6 | 8 | 0 |
| 代表例，原话匹配，类内取前两名均值 | 22/48 | 3/8 | 13/20 | 2 | 4 | 1 |
| 代表例，状态与原话匹配，类内取前两名均值 | 21/48 | 4/8 | 11/20 | 7 | 1 | 2 |
| 带状态的句向量加岭回归 | 28/48 | 4/8 | 10/20 | 3 | 5 | 1 |

BGE 单条分词和编码中位耗时约 7–10 ms，候选向量预先计算。原话匹配保留了三种上下文里的“拍一张啊”，但在“嗯哼”两条同文异义样例中都判丢弃，也把“不用暂停”和“说完再停”判成打断。状态和原话一起匹配区分了两条“嗯哼”，同时把“要。”误判为打断，并误丢更多有效输入。多条类定义改善总分，但相较单定义新增误丢弃。

[追加实验原始数据](../measurements/decision-request-embedding-2026-11-11.json)包含 957 次判定、输入、提示词和原型。辅助脚本在 `/tmp/mobileharness-decision-compare.QYtdFu`。本轮结果覆盖合成文本和 Mac 离线推理。真实 ASR、iPhone 时延、负载及有拒判策略的业务指标仍待验收。

## 小参数生成模型的 Core AI 对照

2026-11-13，Apple M5、16 GiB、macOS 27.2.1（26B131）。复用 48 条中文、8 条应用格式探测的业务场景和 20 条诊断探测，另在看结果前固定 12 条英文和 12 条中英混说合成探测。五组共 100 次判定，其中应用 8 条与历史组有重合。本轮用同一业务格式重渲染应用 8 条。期望动作有 24 次打断、26 次丢弃、50 次入队。

- 共享输入提供是否正在输出或执行、最近助手文本、用户转写和来源。历史夹具以最近文本末尾问号近似等待回答状态，部分来源是夹具预先标注。三类动作定义及输入 JSON 一致。D3 Edge 通过原生 Choice 接收，LLM 通过各自的本地聊天模板接收，模板支持时关闭思考。
- LLM 读取首个位置的三个候选 token logits，取最大分。逐条校验每个候选确实能以单 token 接在模板后，另保存全词表贪心输出用于诊断。D3 使用专用决策头。应用的回答保护、云端回退和动作执行均未参与计分。
- 苹果 Core AI 加载本地 `.aimodel`。LLM 通过 CoreAILanguageModels 的 sequential 路径读取分数，推理时开启 Hugging Face 离线环境变量。每组预热 3 条，单独重置请求状态。Qwen3.5 0.8B 和 LFM 的图一次输入一个 token，采用单 token 预填充并复用任务指令的共同前缀。Qwen3.5 前 8 条有缓存与无缓存的候选分数逐条完全相同，无缓存 p50 约 5.45 秒。热调用包含提示词编码、推理与读出，排除加载及一次性前缀缓存。

### 首轮结果

| 模型与制品 | 中文 48 | 应用探测 8 | 诊断 20 | 英文 12 | 混说 12 | 总正确 | 误丢弃 | 误打断 | 漏打断 | 正确丢弃 / 26 | Mac p50 / p95（ms） |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| D3 Edge，BF16 / FP32 | 25 | 4 | 6 | 8 | 8 | 51 | 20 | 29 | 2 | 16 | 44.9 / 45.1 |
| Qwen3 0.6B，INT4 | 11 | 2 | 3 | 4 | 4 | 24 | 0 | 76 | 0 | 0 | 36.8 / 40.4 |
| Qwen3.5 0.8B，INT8 | 24 | 5 | 13 | 5 | 5 | 52 | 0 | 0 | 22 | 0 | 1041.0 / 1162.2 |
| MiniCPM5 1.08B，INT8 | 23 | 4 | 13 | 5 | 5 | 50 | 0 | 0 | 24 | 0 | 51.2 / 54.0 |
| LFM2.5 1.17B Instruct，INT8 | 23 | 4 | 13 | 5 | 5 | 50 | 0 | 0 | 24 | 0 | 716.9 / 984.3 |
| Qwen2.5 1.54B Instruct，INT8 | 19 | 3 | 5 | 7 | 7 | 41 | 6 | 53 | 0 | 3 | 83.9 / 88.2 |
| 全部入队 | 23 | 4 | 13 | 5 | 5 | 50 | 0 | 0 | 24 | 0 | — |

Qwen3 0.6B 全部打断。MiniCPM 和 LFM 全部入队。Qwen3.5 只打断两条，漏掉 22 次应打断，也没有选出应丢弃的输入。Qwen2.5 找全 24 次应打断，但另外打断 53 次。D3 误丢弃 20 条，包括“拍一张啊”，也把“不用暂停，我能听清”和“你说完再停”判成了打断。

### 提示词和决策方式复测

- 中文规则、六条多轮示例和数字标签使 Qwen2.5 得到 45/100，误丢弃 9、误打断 43、漏打断 2，热态 p95 为 157.9 ms。同样配置下 Qwen3 0.6B 得 44/100，误丢弃 43 条。Qwen3.5 0.8B 识别了 24 次应打断，另有 59 次误打断。Qwen3 0.6B 只加答案前缀便从全部打断变为全部入队。
- 追加两次 A/B/C 映射轮换，同时改用等义的输出要求。Qwen3.5 最好的一次得 61/100，误打断 16、漏打断 5，26 条应丢弃全漏，p95 约 1.41 秒。三次取动作对齐后的平均 logits 得 56/100、漏打断 17。Qwen2.5 的三次平均得 39/100、误打断 58。
- 先问是否立即打断，再按需问是否保留的 Yes/No 对照中，Qwen2.5 得 41/100、误丢弃 10、误打断 48、漏打断 5。Qwen3 0.6B 首问全部答打断，MiniCPM5 首问全部答不打断。

这些制品和提示词在本轮没有达到全双工主分流的要求。参数档位同时涉及不同模型代际、架构和量化，不能隔离参数量的因果影响。约 1.5B 的千问有低于 250 ms 的 Mac 热态时延，适合继续验证有业务监督的分类头或阈值策略。真机 ASR、播报取消、并发延迟和峰值内存仍待独立验收。

### 制品与逐条证据

- D3 使用项目发布的 BF16 文本图。千问分别使用 0.6B Mac 动态 INT4、0.8B Mac INT8、1.5B Instruct INT8。对应 1.5B 上游卡报告 **1.54B** 总参数。 [D3](https://huggingface.co/hugging-mac/d3-edge-CoreAI) · [0.6B](https://huggingface.co/mlboydaisuke/qwen3-0.6b-CoreAI-official) · [0.8B](https://huggingface.co/mlboydaisuke/qwen3.5-0.8B-CoreAI) · [1.5B 制品](https://huggingface.co/kevinqz/Qwen2.5-1.5B-Instruct-CoreAI) · [1.5B 上游](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct)
- MiniCPM5 使用 INT8 block-32。LFM 旧 b1 制品在当前系统触发版本化 IR 错误，改用 b2 版后完整通过推理。 [MiniCPM5](https://huggingface.co/mlboydaisuke/MiniCPM5-1B-CoreAI) · [LFM2.5 b2](https://huggingface.co/mlboydaisuke/LFM2.5-1.2B-CoreAI/tree/3e3241cbcf368a663768dcc4e5785c4f0a02bae4/gpu-pipelined-b2)
- [逐条分数、时间、制品 revision、SHA-256 和复现脚本](../measurements/duplex-llm-coreai-2026-11-13.json)。本轮是离线模型实验，验证记录之外没有应用源码变更。

### 对话历史窗口对照

保持模型、规则、运行状态和最新转写一致，改变已发生对话的可见范围。共 14 组合成配对、28 条探测，其中 13 组在相同运行状态和相同转写下要求不同动作，2 组的区别出现在最近 10 条以外。按用户要求以实测热调用 100 ms 为上限，记录全部超限次数。上一轮已超限的 Qwen3.5 0.8B 和 LFM2.5 1.17B 从本轮剔除。

初测以英文规则和 JSON 表达状态及历史，测试 0、1、10、20 条消息。20 条时 D3 的全部请求达到 573–599 token，超过制品 512 token 上限。Qwen3 0.6B、MiniCPM5 和 Qwen2.5 1.54B 的 20 条方案分别有 2/28、28/28 和 28/28 超过 100 ms。Qwen2.5 的 10 条方案也全部超时。四个模型在此格式下均未完整判对任何一组动作不同的配对。

复测使用中文短规则、三项独立现场状态和带角色的紧凑历史，当前转写单列在末尾。下表每格为正确数 / 28 · 热态 p95，带星号表示该组至少有一次超过 100 ms。

| Core AI 制品 | 无历史 | 2 条 | 4 条 | 10 条 | 20 条 |
| --- | --- | --- | --- | --- | --- |
| D3 Edge | 15 · 46.1 ms | 19 · 46.1 ms | 13 · 46.1 ms | 13 · 46.2 ms | 13 · 46.7 ms |
| Qwen3 0.6B | 10 · 24.9 ms | 12 · 31.4 ms | 12 · 32.6 ms | 12 · 49.7 ms | 11 · 75.6 ms |
| MiniCPM5 1.08B | 12 · 29.5 ms | 12 · 46.7 ms* | 12 · 46.1 ms | 12 · 56.0 ms | 12 · 85.3 ms |
| Qwen2.5 1.54B | 7 · 77.9 ms | 7 · 73.8 ms | 7 · 77.0 ms | 7 · 122.0 ms* | 7 · 160.0 ms* |

D3 使用最近一来一回时完整判对 4/13 组，包括等待确认和一般附和中的“嗯”“OK 好”。该窗口误丢弃 0、误打断 4、漏打断 2，最长 46.2 ms。加至 4 条及以上时未保住这四组配对。紧凑 20 条让 D3 的输入降到 448–471 token，但两组依赖更早历史的配对均未判对。MiniCPM5 的 2 条窗口有一次 171.0 ms 离群，分类均为入队。Qwen2.5 在紧凑格式下各窗口均判为打断，10、20 条窗口各有 28/28 超时。

此轮实验时，应用分流读取最近回复片段和关联追问，生成请求从同一会话选择最多 10 个历史项。此轮是独立 Mac 合成实验。后续接入和英文对照见下文。候选窗口以真实 iPhone 并发下的 100 ms 端到端验收为准。

[逐条记录及复现脚本](../measurements/duplex-history-coreai-2026-11-13.json)

后续候选按 **100 ms 硬上限**筛选，任意测量样本超限即淘汰该模型与输入配置的组合。Qwen3.5 0.8B 和 LFM2.5 1.17B 已退出分流候选，其本机 Core AI 制品、编译缓存和补测临时文件已清除。

#### 2、4、8、10 条历史的续测

沿用同一组 28 条夹具和紧凑中文规则。历史长度以单条消息计数，四轮为 8 条用户／助手消息。已有四款复用相同制品和已完成的 2、4、10 条窗口，补测 8 条。新增 D3 Lite、D3 Nano、Julia-1、Qwen2.5 0.5B，以及此前已测过单条请求的 Laya Multilingual。只使用 M5 Mac 本地 Apple Core AI 图。生成模型的热耗时合计主机编码和 Core AI 调用，决策模型计端到端主机调用。任意实测请求超过 100 ms 即停止该配置的余下样例；已知超时配置沿用原记录。全部请求使用各制品的原生提示模板和候选读出。

每格为正确数 / 28 · 热态 p95。淘汰格显示触发淘汰的实测延迟或既有组最大值。

| 模型 | 2 条 | 4 条 | 8 条 | 10 条 |
| --- | --- | --- | --- | --- |
| D3 Edge | **19 · 46.1 ms** | 13 · 46.1 ms | 13 · 46.4 ms | 13 · 46.2 ms |
| Julia-1 | 13 · 26.3 ms | **15 · 26.4 ms** | 10 · 26.5 ms | 13 · 26.5 ms |
| Laya Multilingual | 11 · 10.5 ms | 11 · 10.5 ms | 11 · 10.7 ms | 12 · 21.0 ms |
| Qwen2.5 0.5B | 12 · 29.2 ms | 淘汰 · 123.2 ms | 12 · 36.8 ms | 12 · 48.9 ms |
| Qwen3 0.6B | 12 · 31.4 ms | 12 · 32.6 ms | 12 · 43.5 ms | 12 · 49.7 ms |
| MiniCPM5 1.08B | 淘汰 · 171.0 ms | 12 · 46.1 ms | 12 · 56.2 ms | 12 · 56.0 ms |
| Qwen2.5 1.54B | 7 · 73.8 ms | 7 · 77.0 ms | 7 · 93.5 ms | 淘汰 · 122.2 ms |
| D3 Lite 0.85B | 淘汰 · 109.7 ms | 淘汰 · 110.1 ms | 淘汰 · 110.0 ms | 淘汰 · 110.0 ms |
| D3 Nano，文本约 1.88B | 淘汰 · 191.1 ms | 淘汰 · 191.0 ms | 淘汰 · 192.4 ms | 淘汰 · 191.6 ms |

- Julia-1 的 4 条配置判对 3/13 组同句异义，误丢弃 1、误打断 3、漏打断 5，最大 27.9 ms。该制品为 144M、FP32、固定 512 token，GPU 优先。 [Julia-1 制品](https://huggingface.co/mlboydaisuke/Julia-1-CoreAI)
- Laya 的 10 条配置判对 2/13 组，误丢弃 14、误打断 2、漏打断 3，最大 26.5 ms。实际编码长度跨过 256 token 时切换到 512 图。 [Laya 制品](https://huggingface.co/smdesai/laya-multilingual-coreai)
- Qwen2.5 0.5B INT8 的 2、8、10 条配置全部判为入队，漏掉全部 7 次应打断。4 条配置在第 18 条触发超时。 [Qwen2.5 0.5B 制品](https://huggingface.co/kevinqz/Qwen2.5-0.5B-Instruct-CoreAI)
- D3 Lite 使用 BF16、固定 512 token 的公开 Core AI 制品。每档首个计时请求超限，未产生整组准确率。按淘汰规则清除本机模型及编译缓存。 [D3 Lite 制品](https://huggingface.co/ahmedandaloes/d3-lite-CoreAI)
- D3 Nano 使用约 3.77 GB 的公开 BF16 文本 Core AI 图，固定 512 token。仅加载文本图。首次加载含编译约 65.4 秒，每档独立预热 3 次后首个计时请求均超限，终止剩余样例。已清除本机模型及编译缓存。 [D3 Nano 上游](https://huggingface.co/vllm-sr/d3-nano) · [Core AI 制品](https://huggingface.co/ahmedandaloes/d3-nano-CoreAI/tree/8b39d9169e25a6077fb1814b9b1d73b8aea78ea0)

本轮 D3 Edge 的 2 条窗口得分最高。Julia-1 的 4 条配置是新增候选中得分最高的一组。结果仍来自原 28 条合成探测，未覆盖真实 ASR、并发播放或 iPhone 端到端延迟。 [逐条结果、制品 revision 和复现脚本](../measurements/duplex-history-windows-coreai-2026-11-13.json)

#### 同一窗口的英文提示词对照

在同一 M5 Mac 和 D3 Edge Core AI 制品上复用 28 条夹具、候选顺序与上一轮两条消息窗口。仅把固定规则、候选描述和状态／角色标签改为英文，夹具的对话原文和状态事实保持原样。英文提示词在这组夹具上筛选，得分用于本次配置对照。

| 提示词 | 正确 / 28 | 误丢弃 | 误打断 | 漏打断 | 热态 p95 / 最大 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 中文基线 | 19 | 0 | 4 | 2 | 50.36 / 50.41 ms |
| 接入的英文版 | 18 | 0 | 5 | 1 | 51.46 / 51.89 ms |

运行时采用英文版，历史、关联追问和最新输入保留原语言。以上为 Mac 上合成夹具的原生模型调用结果，包含主机编码；应用内状态、真实 ASR 和 iPhone 并发端到端延迟另行验证。 [运行提示词](../../MobileHarness/Resources/Agents/Assistant/InputDecision.json)

#### 三种动作定义与对照示例

同一台 M5 Mac 使用本地 D3 Edge Core AI 图。固定候选顺序、最近一来一回和输入格式，对照原英文版与加入动作效果及四个英文示例的版本。复用 28 条历史夹具，并加入 18 条中英文合成探测，覆盖正在播报或执行时的立即纠正、延后要求、旁人对话、简短作答、无须回应的附和和含糊 ASR。两组均用于提示词筛选。每个配置预热三次，逐条计入主机编码和本地 Core AI 调用。

| 样例 | 提示词 | 正确 | 误丢弃 | 误打断 | 漏打断 | token | p95 / 最大 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 原 28 条 | 原英文版 | 18 / 28 | 0 | 5 | 1 | 214–231 | 67.48 / 68.68 ms |
| 原 28 条 | 定义与示例 | 18 / 28 | 0 | 3 | 2 | 285–302 | 60.82 / 61.62 ms |
| 新增 18 条 | 原英文版 | 9 / 18 | 1 | 3 | 3 | 214–227 | 67.84 / 67.87 ms |
| 新增 18 条 | 定义与示例 | 10 / 18 | 0 | 0 | 4 | 285–298 | 59.32 / 59.60 ms |

新版在这次对照中减少了误打断和误丢弃。新增探测中的四条应打断输入均被入队，包括「别念了，我自己来」和计时参数的即时纠正。加入定义与示例增加了 71 token。表内时间为这一次运行，另有措辞变体遇到超过 100 ms 的单条离群值，已终止对应配置。真实语音和 iPhone 并发端到端延迟仍待验证。 [逐条对照](../measurements/duplex-decision-prompt-examples-2026-11-13.json) · [运行提示词](../../MobileHarness/Resources/Agents/Assistant/InputDecision.json)

#### D3 输入边界与双语示例

App 内的 D3 Edge 文本 Core AI 图固定为 **512 token**。计数涵盖 chat template、系统提示、指令、候选定义、示例、现场状态、历史、关联追问和最新转写。用同一制品和当前提示词在 Mac 复测边界，511 与 512 token 成功，513 token 在推理前明确拒绝，未截断。App 已有单次本地失败的云端回退，云端不可用时保守入队。

复用前两组 46 条探测，再补 12 条中文和 12 条英文，涵盖停止播报、修正执行、延后处理、旁人说话、附和与回答。新增输入正文与提示词示例不同。各版沿用候选顺序和一来一回窗口，使用 M5 Mac 本地 Core AI，预热 3 次，计时包含主机编码和推理。17 个双语变体中有一版第 7 条耗时 168.13 ms 后停止。下表选录跑完的变体及当前版本。

| 提示词 | 全部正确 / 70 | 新增中文 / 12 | 新增英文 / 12 | 误丢弃 | 误打断 | 漏打断 | token | 最大 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 当前，4 个英文例 | 46 | 9 | 9 | 0 | 3 | 11 | 273–305 | 57.40 ms |
| 6 个简短双语例 | 47 | 8 | 10 | 2 | 3 | 12 | 275–307 | 53.05 ms |
| 8 个双语例，区分立即停止和延后 | 48 | 9 | 10 | 1 | 3 | 12 | 286–318 | 54.47 ms |
| 8 个双语例，强调执行中的修正 | 49 | 9 | 10 | 5 | 3 | 11 | 284–316 | 88.20 ms |
| 8 个双语例，比较正在发送和下次再改 | 47 | 9 | 9 | 0 | 4 | 11 | 300–332 | 56.92 ms |
| 12 个详细双语例，沿用现有规则 | 43 | 10 | 9 | 2 | 5 | 10 | 402–434 | 50.54 ms |
| 12 个详细双语例，扩写规则 | 31 | 4 | 5 | 25 | 14 | 3 | 440–472 | 49.97 ms |

另以两条历史和一条关联追问各 80 个中文字符测试预算。最新输入分别为「下午吧。」、100 字中文或 100 字符英文。当前提示词分别占 419、468、435 token。8 个双语例的发送对照版占 446、495、462 token。沿用现有规则的 12 例版占 548、597、564 token，三种输入均超限。字符数与 token 的比例取决于文本。

本次保留当前运行提示词。双语候选的最高正确数为 49/70，新增了 5 次误丢弃且未减少漏打断。保住零误丢弃的发送对照版多答对 1 条，同时多误打断 1 次。12 个详细例缩小了实际输入余量。该对照使用合成文本，真机 ASR 与并发播报延迟仍待测。 [提示词、逐条输出及边界测试](../measurements/duplex-d3-bilingual-examples-2026-11-13.json)

#### 保留明确指令和可能有效的转写

沿用 70 条既有探测，增加 20 条中英文短指令、语气尾词、待答短句和噪声探测。原提示词与新提示词均使用同一 M5 Mac 本地 D3 Edge Core AI 图。原始模型结果由 Core AI 实测，采用值由各版规则离线回放。Swift 回归另行验证实际采纳路径。

| 版本 | 模型误丢弃 | 采用后误丢弃 | 采用后误打断 | 采用后漏打断 | 最大本地耗时 | token |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 原提示词及规则 | 3 | 2 | 3 | 11 | 51.83 ms | 273–305 |
| 保留指令的提示词及规则 | 1 | 0 | 5 | 10 | 51.84 ms | 313–345 |

原提示词曾将「开相机」「地址乱了呃先别发」和一个英文待答短句判为丢弃。新版模型仍把「开相机」判成丢弃，采纳规则将其保留。三条明确噪声输入最终丢弃，两条纯语气词被模型判为入队。整组采用正确数由 59/90 变为 57/90，主要变化是更少的丢弃及额外两次误打断。历史和追问各到 80 字、最新中文输入 100 字的合成样例占 508 token。没有运行真机端到端语音分类验收。 [逐条结果](../measurements/duplex-d3-discard-protection-2026-11-14.json)

#### 中英文打断近义词

同一 M5 Mac 的 D3 Edge Core AI 图比较 1 个基线与 49 个近义词变体，每版 124 条，含 90 条既有探测和 34 条新增对照。新增场景覆盖「停下」「别说了」「等下」、英文对应、执行中的纠正，以及带相同词的否定、引用、延后和空闲状态。丢弃候选及采纳规则固定，采用值按实际规则离线回放。各版独立预热 3 次，计时含编码和 Core AI 推理。下表为代表结果。

| 提示词 | 采用正确 / 124 | 误丢弃 | 误打断 | 漏打断 | token | 最大本地耗时 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 原提示词 | 77 | 0 | 8 | 21 | 313–345 | 47.60 ms |
| 近义词放在打断候选末尾 | 78 | 0 | 7 | 22 | 330–362 | 46.78 ms |
| 打断与入队候选均追加近义词 | 86 | 0 | 13 | 11 | 368–400 | 47.10 ms |
| 替换打断示例，保留重复的定义 | 82 | 0 | 11 | 14 | 320–352 | 70.63 ms |
| 接入版，替换示例并压缩规则 | 80 | 0 | 7 | 20 | 306–338 | 65.58 ms |

接入版将「停下、别说了、等下 / stop, stop talking, hold on」放到打断示例。立即停止或改变的条件继续由打断候选说明。长中文样例用满两条历史和追问时，接入版占 501 token，原版为 508 token，打断与入队同时扩写的版本为 563 token。接入版能处理测试里的英文 “Enough talking”，仍漏判单独的「别说了」「等下」和 “Hold on a second”。对应延后及空闲用例都入队。未做真机语音验收。 [配置和测量](../measurements/duplex-d3-interrupt-synonyms-2026-11-14.json)

## Decision prompt language split

2026-11-14, Apple M5 Mac, macOS 27.2.1 (26B131), Swift 6.4. The experiment used the installed D3 Edge BF16 Core AI graph with upstream revision `bee5e872f75b9c5d1405767bf244a6948b95c0af`. The graph SHA-256 was `ca54b56a901d10db4e85a046aeaaaa65cde273afd2e18c47f3bb57487c3d6a78`.

Each of 27 scenarios has English and Simplified Chinese versions with the same expected intent and playback, execution, and question state. Each language has 8 interrupt, 13 enqueue, and 6 discard cases. The two current prompt configurations load the bundled [English](../../MobileHarness/Resources/Agents/Assistant/InputDecision.json) and [Simplified Chinese](../../MobileHarness/Resources/Agents/Assistant/InputDecision.zh-Hans.json) resources at runtime. The pre-split baseline uses the archived `terse-example-cut` instruction with the current English request formatting and identical baseline candidate descriptions. All six combinations run through the Swift request renderer, real D3 and the application's adoption policy. The runner warms each prompt three times and measures native request submission through model cleanup. The times exclude ASR, playback, and any subsequent interruption cleanup. [Paired fixture](../measurements/decision-language-scenarios-2026-11-14.json)

| Prompt | Input | Raw correct | Adopted correct | False discard raw → adopted | False interrupt raw → adopted | Missed interrupts raw → adopted | Native p50 / p95 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| English | English | 18/27 | 21/27 | 1 → 0 | 2 → 1 | 4 → 4 | 50.59 / 50.83 ms |
| English | Chinese | 18/27 | 21/27 | 1 → 0 | 0 → 0 | 4 → 4 | 50.85 / 51.35 ms |
| Chinese | English | 12/27 | 21/27 | 11 → 0 | 4 → 2 | 4 → 4 | 54.46 / 54.71 ms |
| Chinese | Chinese | 18/27 | 23/27 | 7 → 0 | 1 → 1 | 3 → 3 | 54.66 / 55.45 ms |
| Pre-split mixed | English | 16/27 | 20/27 | 1 → 0 | 2 → 1 | 4 → 4 | 50.87 / 51.11 ms |
| Pre-split mixed | Chinese | 17/27 | 20/27 | 1 → 0 | 1 → 1 | 4 → 4 | 50.99 / 51.41 ms |

With input and prompt languages matched, adoption accuracy was 44/54 against 40/54 for the pre-split mixed prompt. Raw accuracy was 36/54 against 33/54. The Chinese prompt recovered the short Chinese pause request “等一下。” and still missed “别说了。” in this history. The earlier four-input smoke test used a different history and selected interrupt for the same utterance with the Chinese prompt. English “Stop talking.” during playback was correctly interrupted by the English and mixed prompts. The Chinese prompt selected discard, which the app converted to enqueue. The Chinese prompt also interrupted both English deferred-action probes. [Per-request decisions, scores, and timings](../measurements/decision-language-d3-2026-11-14.json)

There were no fallbacks across the 162 scored cases. Separate capacity probes filled both history messages and the pending question to 80 characters each. At five repeats of the test utterance, both split prompts accepted both input languages. The mixed baseline rejected the Chinese probe. At 25 repeats every configuration returned the native 512-token error, and the classifier retained the input as enqueue with no cloud fallback configured. The 18 probes are excluded from the accuracy table. The sample is synthetic and includes known difficult phrases. It provides no estimate of live transcription accuracy, iPhone latency, or cloud-provider performance.

Run the repository script with a resource root containing `D3Edge/` and a fresh output path. The script reads the saved fixture and baseline from this repository and records the exact rendered instructions, candidate descriptions, and state for every call.

```bash
./scripts/evaluate-decision-language.sh "$D3_RESOURCE_ROOT" /tmp/decision-language-result.json
```

The native experiment, `./scripts/check.sh`, four iOS Simulator schemes in `./scripts/build-ios.sh`, and `git diff --check` passed. The measured requests were checked against the current source resources, baseline and fixture. The iOS build verifies packaging. The Decision experiment ran on the Mac.

## D3 Lite 与 Edge 的四段提示对照

2026-11-15，M5 Mac、macOS 27.2.1。读取 App 提交 `f9dc3a5f` 的两份 Decision 资源，依次渲染动作定义、最近一轮历史、缓冲区用户输入和引用最新一句的问句。两款模型均通过 Core AI 原生 Choice 为 A/B/C 打分，对应打断、舍弃、入队。报告原始分类，Assistant 的采纳保护不参与。Lite 使用公开 BF16 固定 512 token 图及空视觉张量，仅走文本。两款图均核对发布版本和 SHA-256。

当前提示中英文各 36 条，包含 28 条空缓冲历史夹具及 8 条各带一条缓冲输入的合成探测。旧短中文提示对照使用相同的 28 条历史夹具。每组预热三次，逐条测量包含模板、编码、Core AI 推理和读出。500 ms 用于统计超限，所有组继续跑完。耗时不含首次装载和 ASR。

| 模型 · 提示 | 正确 | 误丢弃 | 误打断 | 漏打断 | p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Edge · 当前中文 | 13/36 | 4 | 19 | 0 | 71.21 |
| Lite · 当前中文 | 18/36 | 14 | 2 | 6 | 178.13 |
| Edge · 当前英文 | 9/36 | 2 | 25 | 0 | 62.82 |
| Lite · 当前英文 | 19/36 | 2 | 6 | 4 | 171.52 |
| Edge · 旧短中文 | 19/28 | 0 | 4 | 2 | 56.24 |
| Lite · 旧短中文 | 14/28 | 2 | 10 | 0 | 154.49 |

当前英文提示下，Lite 命中 13/15 次应入队、5/9 次应打断和 1/12 次应舍弃。Edge 命中全部 9 次应打断，额外误打断 25 次，两种语言均未选过入队。旧短提示下 Edge 的总分更高，因此排名取决于提示结构。六组共 200 条热态推理全部低于 500 ms，Lite 最慢 190.74 ms。首次运行的 Lite 默认自动编译遇到磁盘空间不足，CPU-only 探测未通过有限分数检查。清理可再生成的旧 Core AI 编译缓存后，两款均以默认配置完成，分进程运行。无 App 源码变化和真机测量。

[两款制品的 SHA-256、实际提示、逐条分数和复现脚本](../measurements/duplex-d3-lite-edge-coreai-2026-11-15.json)。

## Decision runtime-state prompt revision (2026-11-15)

This revision adds existing execution/settlement, tri-state playback and bounded pending-question facts to the shared local/cloud prompt. English and Simplified Chinese instructions protect brief answers, distinguish immediate correction from ordinary additions, and prefer enqueue under uncertainty. Latest input and the pending question use quoted, escaped data. This is a snapshot projection, not a conversation-mode state machine; adoption and interruption cleanup remain unchanged.

Validation on the local Mac:

- `scripts/build-ios.sh`: all four Simulator schemes passed; packaged Agent/Skill, Live Activity and English/Simplified Chinese resources passed verification.
- Focused `swift test --skip-build --filter 'decisionPrompt|inputDecision|readyD3|slowTrackingDispatchExecutesOnlyTheNewestPendingTarget'`: 13 tests passed, including both prompt languages, all execution/playback combinations (unknown included), bounded/escaped question data, cloud/local prompt agreement, fallback and adoption protections.
- `scripts/check.sh`: architecture boundaries, seven Python tests and strict formatting passed. Full concurrent IntegrationTests reported a failure in `slowTrackingDispatchExecutesOnlyTheNewestPendingTarget`; its focused rerun passed, which does not erase the original failure. AppWorkflowTests reported Writer/Web failures involving `resourceMissing("injected Action declarations")`; that process then produced no new output for over three minutes while consuming CPU and was terminated. The complete check exited 1. Its subsequent isolated LiveRuntimeTests phase passed all 228 tests, and project/privacy/entitlement/plist validation passed; these do not erase the earlier failures.
- The initial sandboxed check could not write the Swift module cache; validation was restarted with cache access. No production source was changed to accommodate validation failures.

Logs: `/tmp/mobileharness-decision-check.log`, `/tmp/mobileharness-decision-focused.log`, `/tmp/mobileharness-decision-ios.log` (local ephemeral evidence). Real D3/cloud accuracy, tokenizer capacity distribution and physical-device speech behavior were not measured for this revision. Earlier model scores in this document belong to their recorded prompts and do not establish improvement for this revision. The fixed 512-token rejection/fallback contract remains in effect.


## Apple system model Decision comparison (2026-11-15)

使用新增 [Swift 实验测试](../../Tests/IntegrationTests/AppleDecisionEvaluationTests.swift)，通过 `ModelKitAppleLLM.AppleChat` 调用 `SystemLanguageModel.default`。实验目标依赖 Apple provider，ModelKit 不依赖 Agents 或其他业务模块。未修改生产 Decision 路由、提示词或模型选择。

### 固定方法与基线

第一组直接读取上面的 D3 Edge/Lite 四段提示原始报告，逐条核对两模型的 ID、预期和完整提示一致。保留原 system/user 文本及 A/B/C 到打断/舍弃/入队的映射，只移除 D3 原生聊天模板控制符，交给 Apple 原生会话编码。Apple 使用生成文本的严格单标签解析；D3 历史结果来自候选头，不假设两者拥有相同 logits 接口。英文提示组仍使用历史报告中的中文场景，不能称为英文输入测试。

| 冻结条件 | 用例 | Edge 历史正确 | Lite 历史正确 | Apple 本次已测 |
| --- | ---: | ---: | ---: | --- |
| 四段中文提示 | 36 | 13/36 | 18/36 | 0，系统模型不可用 |
| 四段英文提示 | 36 | 9/36 | 19/36 | 0，系统模型不可用 |
| 旧短中文提示 | 28 | 19/28 | 14/28 | 0，系统模型不可用 |

第二组复用已有的 27 条中英文配对场景，通过现行 `InputDecisionSnapshot.prompt()` 渲染语言匹配的 54 条请求，使用严格数字 1/2/3 输出。它保留现行执行、播放与待答问题字段，单独分组，不拿旧提示词的 D3 分数直接衡量模型优劣。本次也未执行这 54 条推理。两组均不应用 Assistant 采纳保护或回退，不将它们混合成一个准确率。

计划每个条件预热三次，随后串行执行，temperature=0、最大输出 16 token。每次完整接收并加入 provider 清理后再计总时延，另记录首次文本时延。250/500 ms 是统计阈值，不提前丢掉慢请求；60 秒生成超时取消并加入清理。保留原始文本、格式失败、原生错误、完成原因和系统返回的 token 用量。准确率以全部已测请求为分母，格式错误和模型错误均不算正确；p50/p95 使用无原生错误请求的 nearest-rank 百分位。系统模型版本随 OS 管理，不声称固定 Apple 权重 revision。

### 本次真实运行结果

正式测试入口与独立可用性查询均返回 `deviceNotEligible`，报告状态为 `blocked:model-unavailable`。预热 0 次、测量 0 次，准确率、误判率和延迟均无结果；没有使用假响应、其他模型或入队回退补齐。测试因此显式失败，这与普通实验代码回归通过是不同结论。

本次主机报告 `Mac17,5`、Apple A18 Pro、macOS 27.2.1（26B131）；历史 D3 对照来自 M5 Mac。因此即使以后本机可用，也不能将旧 M5 的耗时当作相同硬件下的延迟对照。此处只记录系统 API 返回值，不据此推断所有同型号设备永久不支持。仍需在返回 `.available` 的主机上完整运行。

[本次报告](../measurements/decision-apple-system-2026-11-15.json)保存全部 154 条待测请求、100 条配对基线、设备信息、可用性和来源 SHA-256。代码、当前提示和原始基线均保留指纹。运行命令见 [测试说明](../../Tests/IntegrationTests/README.md#apple-system-decision-comparison)，必须使用新的输出文件路径。

### 工程验证

冻结输入/当前 renderer、严格解析器、错误分母与延迟指标三项离线回归通过。iOS 五个 Simulator scheme 构建完成并通过。完整检查的边界、8 项 Python 检查及格式阶段通过；全量 Swift 测试执行期间按用户要求暂停，不能报告完整通过。此前 Apple 适配器验证记录中的全量失败仍保留；编译或合成测试不代表 Apple 真实推理验收。

### 暂停与另一台 Mac 复跑

用户说明本机为中国大陆购买的 MacBook Neo，并要求暂停本机实验，提交后在美行 MacBook Air 拉取再测试。API 的 `deviceNotEligible` 已独立记录；设备购买地区是用户提供的背景信息，不是本次实验验证出的唯一原因。

在另一台设备上启用 Apple Intelligence、等待系统模型就绪并安装 Xcode 27+ 后，先 `git pull --ff-only`，再按测试说明运行到一个不存在的新 JSON 路径。美行身份本身不保证 `.available`，仍以测试入口的实际可用性为准。

用户随后要求一并提交当前工作区的代码、文档和测试，包含生成这份快照的 Decision renderer/资源修改；本地 DEVELOPMENT_TEAM 签名设置留在工作区。154 条请求中的 100 条冻结基线可直接复现；54 条 current 请求按运行时 checkout 的 renderer/资源重新生成。复跑时仍须核对请求及 sourceSHA256，以识别后续代码或提示词变化。

### M5 Mac 完整复跑

在 `main` 的 `1312362d` 上运行。主机为 Mac17,3、Apple M5、16 GiB、macOS 27.2.1（26B131），Xcode 27.0（27A266a）。独立 API 查询与 Swift 实验均返回 `available`。新增记录独立于 MacBook Neo 的阻塞记录。

原 Swift 实验完成五组 154 条 Apple 调用与 15 次预热。补测用同机默认 Core AI 的 Edge 和 Lite，各跑相同 154 条，每组预热三次。冻结组逐条校验完整 D3 模板与历史版本相同。当前组从 Swift 实验保存的同一业务文本拆出 State 和 Question，再通过 D3 原生 Choice 编码。Apple 接收同份业务文本并生成单个标签，D3 使用候选读出。每款模型串行分开运行。耗时含各自宿主的文本准备、推理和读出，排除首次载入与 ASR。准确率和误判均为模型原始输出。

| 条件 | Apple 正确 / p95 | D3 Edge 正确 / p95 | D3 Lite 正确 / p95 |
| --- | ---: | ---: | ---: |
| 冻结四段中文 | 15/36 · 336.57 ms | 13/36 · 47.57 ms | 18/36 · 112.82 ms |
| 冻结四段英文 | 16/36 · 333.46 ms | 9/36 · 48.64 ms | 19/36 · 110.41 ms |
| 冻结旧短中文 | 17/28 · 287.77 ms | 19/28 · 49.96 ms | 14/28 · 110.73 ms |
| 当前英文提示与英文输入 | 17/27 · 303.78 ms | 10/27 · 49.01 ms | 18/27 · 110.01 ms |
| 当前中文提示与中文输入 | 10/27 · 305.39 ms | 11/27 · 46.99 ms | 20/27 · 110.61 ms |

两款 D3 在冻结 100 条上的预测逐条与历史一致。当前 54 条合计，Apple、Edge、Lite 的正确数分别是 27、21、38。Apple 漏打断 9/16、误丢弃 22 条、误打断 4 条。Lite 漏打断 1/16、误丢弃 7 条、误打断 8 条。英文 Apple 的分类准确率接近 Lite，中文下尤其容易把应入队的内容判成舍弃（10/13）。当前两组分别使用对应语言的同场景改写，结论反映提示与输入语言共同变化。

三款共 462 条计时请求均在 500 ms 内。Apple 154 条全部无原生错误且格式有效，最长 393.59 ms，149 条超过 250 ms。四项 Apple Decision Swift 测试通过。仅测 Mac 文本和原始模型输出。 [逐条输出、同机 D3 读出和复现代码](../measurements/decision-apple-system-m5-2026-11-15.json)

### Mac Decision 实验迁入 Tests

将满足 500 ms 和 2B 条件且有代表性的 D3 Edge、D3 Lite、Qwen2.5 1.54B 的可执行基线迁到 `Tests/DecisionBenchmarks`。目录拥有冻结样例、版本化下载配置、独立 runner、计分和使用说明。Apple 的现行 Assistant renderer 对照仍由已有 Swift 集成测试负责。Mac Gemma profile 和制品归 `Tests/Gemma4Tests`，App 继续从生产 catalog 取得手机图。下载复用仓库的开发下载器。旧实验报告用于解释历史结果，继续归档。

新增 [独立实验入口](../../Tests/DecisionBenchmarks/README.md) 在 M5 Mac 复跑 D3 Edge/Lite 各 154 条、Qwen2.5 四种输出协议各 100 条。708 条预测与对应归档逐条一致，逐条耗时均在 500 ms 内。Qwen 单词打分及生成各 62/100，数字打分及生成各 57/100。Lite 下载入口验证并复用已存在的模型图后补齐许可文件。Gemma 开发下载入口验证并补齐迁移后的 Mac 制品，默认根为 `Tests/Gemma4Tests/.local/Gemma4`。未运行 Gemma 真实推理。

独立 Swift release 构建、开发下载器的 8 项测试和 `git diff --check` 通过。iOS 的五个 Simulator scheme 与 App 资源校验通过。全量 `scripts/check.sh` 在既有 Lite 路由夹具、NexArm 以及 Writer/Web 声明注入用例上失败。AppWorkflow helper 约 90 秒未继续输出后终止。

## Settings recommendation index

Settings uses the M5 [production protocol comparison](#assistant-decision-protocol-benchmark), pooling the 54 current Chinese and English cases per model. It uses the accuracy and nearest-rank warm p95 of each model's selected protocol. The UI index is `5 × (0.8 × accuracy + 0.2 × max(0, 1 − p95_ms / 500))`, rounded to the nearest half star.

| Local Decision model | Raw correct | Pooled warm p95 | Stars |
| --- | ---: | ---: | ---: |
| D3 Lite | 38/54 | 117.67 ms | 3.5/5 |
| D3 Edge | 21/54 | 53.34 ms | 2.5/5 |
| Apple system model | 31/54 | 305.21 ms | 2.5/5 |
| Gemma 4 E2B | 32/54 | 10,203.26 ms | 2.5/5 |

These are Mac text classification results from the recorded model versions and prompts. Assistant and Writer have no equivalent local model measurements for their role. Prompt parser and smoke tests alone do not supply an accuracy denominator.

Implementation verification recomputed the three pooled p95 values from the archived rows. Both recommendation tests passed, covering role isolation and the accuracy/latency formula. The iOS Simulator App built and launched, and its compiled Chinese resources include the recommendation title and spoken score. The Mac was locked during the direct UI check, so menu appearance was not inspected. The repository-wide check reported the existing D3 Lite selection and Writer/Web fixture failures. The stalled AppWorkflow helper was stopped after about a minute.
All five iOS Simulator schemes built successfully. The isolated native-runtime phase passed 228 tests and plist validation passed. The repository check exited 1.

## Gemma 4 E2B Decision comparison

On the same Mac17,3 M5 with 16 GiB and macOS 27.2.1, Gemma used the pinned Mac non-AOT QAT package at revision `d669ab2b44c691e35e2b795f0535c0e1937b8390` through the native `Gemma4Chat` adapter. The run replayed the 27 English and 27 Chinese business prompts from the M5 Apple/D3 comparison. It supplied the same output instruction as the current Gemma Decision request, temperature 0, and at most 16 tokens. The strict parser accepted only one digit with a normal stop. The adapter strips system messages on this path, so a second diagnostic arm placed the same instruction at the front of user content.

Each mode and language was warmed three times and run serially. Timings include tokenization, full generation and cleanup, excluding warmup and fixture preparation. The 500 ms production deadline was applied when counting timely results; the sampler allowed slower requests to finish so the raw choices and timing distribution remained observable. The initial process exited after writing 44 production samples without a terminal test result. The remaining 10 Chinese samples were collected after a new warmup, and the diagnostic languages ran in separate processes. The combined production and diagnostic rows are matched by fixture identity to the archived baseline. Previous Apple/D3 figures come from their recorded runs on the same Mac.

| Production output | Raw correct | Invalid format | p95 | Correct within 500 ms |
| --- | ---: | ---: | ---: | ---: |
| English | 7/27 | 17 | 7.44 s | 0/27 |
| Chinese | 14/27 | 0 | 7.98 s | 0/27 |
| Combined | 21/54 | 17 | 7.58 s | 0/54 |

Production recorded no native errors. All 54 measured requests took more than 500 ms, with a minimum of 3.55 s. There were 11 false interrupts and 8 missed interrupts. The Mac replay earns 1.5 stars under the Settings formula. The iPhone uses a separate AOT artifact and was not measured.

| Format instruction in user content | Raw correct | Invalid format | p95 | Correct within 500 ms |
| --- | ---: | ---: | ---: | ---: |
| English | 17/27 | 0 | 9.61 s | 0/27 |
| Chinese | 14/27 | 0 | 9.70 s | 0/27 |
| Combined | 31/54 | 0 | 9.70 s | 0/54 |

The diagnostic arm eliminated the 17 format failures and added 10 correct classifications in English. Chinese accuracy was unchanged. The diagnostic arm had 4 false discards, 12 false interrupts and one missed interrupt. All 54 calls still exceeded the deadline. Only the production arm contributes to the Settings recommendation.

[Reproduction command](../../Tests/Gemma4Tests/README.md#decision-对照) and [108 measured rows with warmups, source hashes and segment metadata](../measurements/decision-gemma4-m5-2026-11-15.json).

Validation passed the three segmented native runs, the role-rating tests and all five iOS Simulator schemes. The repository check exited 1 after reproducing the known D3 Lite, NexArm tracking and Writer/Web failures. The stalled AppWorkflow helper was stopped. The isolated runtime phase passed 228 tests.

## Assistant Decision protocol benchmark

The protocol comparison calls the production Assistant projection and parser, with the matching 27 English and 27 Chinese fixtures. It measures the provider and complete protocol decoding before queue admission policy, class adoption, or device work. Counts include invalid and failed cases in the denominator. p95 is computed over valid responses. Gemma segments retain their own warmups and process exits. The cloud runs used the existing Aliyun Responses endpoint. Only Qwen3.7 Flash and Qwen3.8 Flash received requests, and all input was synthetic.

| Model | Mode | Raw correct | Within 500 ms | Within App budget | Valid p95 | Invalid or failed |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Qwen3.7 Flash | Tool | 41/54 | 3/54 | 41/54 (2 s) | 969.76 ms | 8 |
| Qwen3.7 Flash | Text | 48/54 | 32/54 | 48/54 (2 s) | 1,050.74 ms | 0 |
| Qwen3.8 Flash | Tool | 47/54 | 0/54 | 47/54 (2 s) | 1,140.90 ms | 2 |
| Qwen3.8 Flash | Text | 52/54 | 14/54 | 52/54 (2 s) | 888.01 ms | 0 |

Text led on timely accuracy and raw accuracy for both cloud IDs, and the application selects it for those exact IDs. Qwen3.7 Flash Tool had eight invalid tool argument objects. Qwen3.8 Flash Tool had one invalid tool argument object and one transport failure. The Text arm had zero false discards for either model. The 500 ms comparison emphasizes fast useful results independently of the cloud Decision ceiling of two seconds.

[Cloud per-case report](../measurements/decision-protocols-cloud-2026-11-15.json) and [benchmark commands](../../Tests/IntegrationTests/README.md#assistant-decision-protocol-comparison).

| Local model | Mode | Raw correct | Within 500 ms | Within App budget | Valid p95 | Invalid or failed |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| D3 Edge | JEV | 21/54 | 21/54 | 21/54 (250 ms) | 53.34 ms | 0 |
| D3 Lite | JEV | 38/54 | 38/54 | 38/54 (250 ms) | 117.67 ms | 0 |
| Apple system | Text | 31/54 | 31/54 | 31/54 (500 ms) | 305.21 ms | 0 |
| Gemma 4 E2B | Tool | 19/54 | 0/54 | 0/54 (500 ms) | 11.65 s | 25 |
| Gemma 4 E2B | Text | 32/54 | 0/54 | 0/54 (500 ms) | 10.20 s | 0 |

Gemma Text had zero false discards, 15 false interrupts and zero missed interrupts. Tool had six false discards, four false interrupts and five missed interrupts. Its 25 failures failed strict tool argument validation. The App selects Text for Gemma based on raw accuracy and valid-response coverage. Both protocols exceeded the Mac real-time budget. Rankings reflect raw classifier outputs before Assistant's speech guards. The iPhone artifact and end-to-end voice latency require separate measurements.

The local comparison ran on Mac17,3 with Apple M5 and macOS 27.2.1. Local segments used three warmups and cloud cells used one warmup per language. Transport failures were recorded as observed. The launcher uses opt-in synthetic tests and keeps cloud credentials and endpoint out of the archived evidence. The older independent D3/Qwen experiments and the earlier Gemma prompt comparison remain historical baselines. [Local per-case report](../measurements/decision-protocols-local-2026-11-15.json)

Final validation passed the Decision protocol, route, request-log and recommendation tests, all five iOS Simulator schemes, and the 228-test isolated runtime phase. `check.sh` exited 1 after the existing NexArm tracking and Writer/Web fixture failures. The stalled AppWorkflow helper was stopped. The two archives were verified against the same fixture IDs and recomputed summaries.

## A18 Pro Mac 最新代码复测（2026-11-15）

用户要求先拉取最新代码，再检查 D3 Edge/Lite 的本机加载、调用与现有用例评分。main 从 db614c96 快进到 b87eb69c；此前未提交的日志/UI修改及本地签名设置保留。本轮未修改模型实现、提示词、测试用例或 UI 评分配置。测试运行于 Mac17,5、Apple A18 Pro、8 GiB、macOS 27.2.1（26B131）、Xcode 27.2（27B52），并非历史 M5/16 GiB 主机。

### 制品与方法

复用 `Tests/DecisionBenchmarks/models.json` 固定版本：Edge `0690c04ee1640c1c3fa11a882323751dda6d086a`，Lite `863963d371d5af6784bf726fb85a508c08751d65`。用户批准创建被忽略的 `.local` 测试缓存并下载制品；两张图均通过固定 SHA-256 校验，manifest 均为三输入文本图，所有必需文件齐全。

使用现有 `D3NativeTests` 经生产 ModelContainer/ModelKit 端口验证预热到 ready、四候选推理、有限分数及超长输入拒绝；Edge 另验证公开参考分类/分数。再使用 `scripts/evaluate-decision-protocols.py MODEL --skip-build --output NEW_PATH`，每个模型串行执行27条英文和27条中文场景，语言组各预热3次。评分直接调用生产 JEV 投影与解码，不经过 Assistant 的采用规则。采样允许请求完成，250 ms预算只用于事后统计，不实际取消请求。

### 加载与调用

- Edge 首次本轮原生预热83.984秒；两项原生测试均通过。两项测试在同一进程并发执行，不能作为隔离的冷启动性能基准。
- Lite 首次本轮原生预热302.302秒；原生测试通过。加载期间采样位于 `D3Graph.init → GraphModel.init → CoreAICompiler → MPSGraph` 的编译和资源写入路径，尚未进入分类推理。
- 新进程中的缓存后预热：Edge 5.722秒，Lite 7.894秒；两次原生回归均通过。未清空系统模型缓存，不能称为严格冷/热对照。
- Lite 加载期间全盘可用空间曾从约27 GiB降到11 GiB，结束后回升到47 GiB。这是全盘观测，不是该进程临时文件或交换空间的精确统计。
- 本轮未复现图接口不匹配、无效输出或原生调用失败；首次编译长、缓存后加载仍需数秒是实际观测。不能据此宣布 iPhone 加载问题已解决。

### 当前生产提示词评分

| 模型 | 英文正确 | 中文正确 | 总正确率 | 有效结果 | p50 / p95 | 250 ms内完成 | 误丢弃 / 误打断 / 漏打断 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D3 Edge | 13/27 | 8/27 | 21/54（38.9%） | 54/54 | 209.07 / 229.24 ms | 54/54 | 18 / 15 / 3 |
| D3 Lite | 21/27 | 20/27 | 41/54（75.9%） | 54/54 | 670.52 / 786.26 ms | 0/54 | 4 / 7 / 1 |

Edge热态范围198.44–234.35 ms；Lite为540.74–807.68 ms，54条均超过500 ms。因此这台Mac上Lite虽然原始准确率更高，却不满足当前D3的250 ms执行预算；在这些测得耗时下会触发生产超时，而本次评分本身没有模拟该取消路径。Edge执行正常但分类质量低，不能将其误丢弃解释为加载故障。

按已有推荐公式重新计算，本机Edge为2/5、Lite为3/5；此值仅作为本次硬件测量的派生结果，不更新UI所用历史Mac基准。当前样例与历史54条相同，但提示词/源码哈希不同：Edge总数仍为21/54，13条预测与早期协议报告不同；Lite与hugging-mac制品报告同为41/54。不得把相同总分称为完整条件复现，也不能把A18 Pro延迟直接解释为相对M5的代码性能退化。

### 验证与证据范围

构建最初因生成计划引用已失效的Metal工具链挂载路径失败；备份XCBuildData并重新生成后测试构建成功，协议选择回归1项通过。Edge原生2项、Lite原生1项、缓存后原生2项均通过；两个模型的英文/中文评分进程均exit 0且每组27条完整。下载的远端断开/停滞通过固定版本续传恢复，完整哈希验证在推理前完成。

[原始结果与元数据](../measurements/decision-d3-a18-mac-2026-11-15.json)保存108条评分、预热记录、原生测试日志、加载采样片段、制品身份、混淆矩阵、硬件及源码哈希。这里没有四分类continue_listening语义评分（四候选原生接口单独验证），没有真实ASR/原生UI/iPhone验收，也未重跑全仓检查或iOS构建。

### App 与此次实验流程核对

针对用户报告“App Edge 经常 discard、Lite 一直 loading”，静态核对实际调用链后确认以下覆盖差异。这里没有修改业务逻辑，也未取得 iPhone 加载线程采样。

| 项目 | App 全双工语音 | 本轮54条评分 |
| --- | --- | --- |
| 快照与选项 | AssistantChatWorker 对 final ASR 设置 allowsContinueListening=true，拼接保留片段，加入第4项 continue_listening | DecisionLanguageScenario.snapshot 未传此参数，保持默认false，仅3项 |
| 提示词 | 共用 InputDecisionSnapshot.prompt；语音增加continueDefinition并选latestSpeech | 共用同一renderer，但选latest，无第4项定义 |
| 上下文 | 真实历史、排队输入、播放/执行状态、交互问题与语音接续 | 固定合成历史/状态，缓冲默认空，无接续 |
| 语言 | App 当前语言设置 | 英文/中文用例分别强制匹配语言 |
| 加载 | 检查ready；未就绪时启动独立preparation任务，本条输入立即fallback | 明确await model.warmup成功，然后预热分类3次再计分 |
| 加载失败 | localFailure保留，阻止后续普通分类重试；切换模型或资源呈现更新可重置 | 原生实验抛出错误结束，不经过Assistant失败缓存 |
| 截止/清理 | 就绪后D3推理250ms，队列接纳起总预算2秒；超时取消，清理未完时拒绝下一次调用 | 直接调用协议等待完成，按250/500ms事后统计；分段进程另有420秒上限 |
| 采用 | outcome可覆盖模型判定 | 无采用规则，直接统计模型输出 |

源码位置：AssistantChatWorker.swift的classifyPendingInputs；AssistantInputDecision.swift的prompt/classifyInput/race；DecisionLanguageEvaluationTests.swift的Transcript.snapshot；DecisionProtocolBenchmark.swift的warmup与measure。两边共用AssistantDecisionProtocol.JEV、ModelKit D3Decision、Tokenizer、图输入适配和候选解码；第4选项加入并不改变前3个数字的映射。App catalog和实验模型revision一致，最后一次设备构建包内中英文InputDecision JSON与当前源码逐字节一致。尚未读取手机实际已安装模型文件，不能据此证明手机制品与Mac缓存相同。

用户补充Lite显示loading：若执行日志为not ready (loading)，它尚未进入分类；提示词、输出映射和250ms推理截止不能解释这条加载中状态。App的preparation没有独立加载截止，可持续等待Core AI加载；缓存后的失败阻塞与持续loading是不同分支，不应混为一谈。Mac上已观测到约302秒首次Lite图编译，但iPhone上的持续加载根因仍需设备证据，不能仅凭Mac测试判为已解决。

上次由本聊天安装的设备包基于db614c96；Mac复测已拉取到b87eb69c，后者统一三/五输入图适配。其变化不改三输入Lite的提示词或分类映射，但这不是同一构建的端到端对照。独立原生四候选测试证明接口能收发4项，不等于App的continue_listening提示与语义评分。后续若要复现“始终discard”，需用App完整快照及四项请求回放；本轮Edge是26/54条discard、Lite14/54，并非全discard。

### iPhone Lite loading 现场采集（2026-11-15）

用户授权采集手机Lite加载日志。本轮没有重启、重新安装或改动应用。iPhone17 Pro（iPhone18,1、iOS27.0.1/24A446）经局域网由CoreDevice访问；Instruments设备列表却为Offline，15秒Time Profiler附加未成功。`log collect`要求root，`sudo -n`提示需要密码，未取得统一日志，也未请求或读取密码。随后通过CoreDevice读取应用专属系统CPU资源报告，获得了留存现场采样。

手机Lite安装记录的制品revision为863963d371d5af6784bf726fb85a508c08751d65，实际图文件大小1,510,776,860字节；manifest和main.hash文件与本机测试制品逐字节一致。未下载手机整张图重新计算哈希，因此只确认身份/元数据/大小一致，不能替代完整文件校验。

21:10:18–21:12:03的CPU资源报告对应采集时App进程PID34782。约105秒内消耗90秒CPU，平均86%；43次采样中最重的ANE编译链有34次。内存footprint由73.88MiB增长至525.64MiB。报告Action taken为none，不能称为系统杀进程或崩溃证据。19:19的早期报告也出现相似ANECompiler栈，但不据此推断两次之间持续编译。

本地已安装版本的debug dylib UUID与现场镜像匹配。使用其符号还原，确认 `ModelResource.ensureLoaded → ModelLoadGate.run → D3Decision.init → D3Graph.init → GraphModel.init`，随后进入 `CoreAIDelegates/CoreAICompiler → MPSGraph → AppleNeuralEngine → ANECompiler`。结合用户当前选择Lite并持续loading的反馈，证据指向D3图加载中的神经引擎编译阶段；尚未进入分类请求，因此不能用提示词或250ms推理超时解释这段loading。

仍未确认编译最终是否完成、耗时根因、其他系统版本或限制计算单元后的差异。手机iOS27.0.1与Mac macOS27.2.1并非相同系统实现；同一automatic配置也不能保证不同硬件采用相同编译路径。后续受控对照应保留制品与模型请求不变，分别观察默认编译及明确限制计算设备的加载/数值结果，不能直接把GPU偏好当作排除ANE，也不能跳过分类一致性验证。此轮不修改模型路由。

[脱敏采集摘要](../measurements/decision-d3-lite-iphone-loading-2026-11-15.json)保留身份、指标、符号化链和限制。原始应用系统报告与设备元数据仅保留在本机/tmp，未将设备标识或原始诊断包加入仓库。实时Instruments采样仍待USB连接恢复；已有系统microstackshots提供了独立的加载卡点证据。

#### 直连后的实时采样

用户改为直连后，Instruments将iPhone列为在线。对相同App进程附加Time Profiler成功，21:24:59–21:25:20录制约21.20秒，正常达到时间上限并保存。未重启或重新安装App。

导出20,984条CPU采样，其中20,828条（99.26%）包含ANECompiler／MPSToANECValidation；20,751条包含associateUnmaterializedOpIds。栈经过MPSGraph的ANERegionFormationPass、specializedModule和specializeWithDevice，正在进行MPS到ANE的转换/校验。它是运行中的编译计算热点，不是只凭UI文案推断的loading，也没有进入本次分类推理。与21:10–21:12的同进程留存报告相比，21:25现场仍处于ANE编译；两个采样窗口之间没有连续记录，不声称已证明同一循环始终未前进。

这份证据将加载瓶颈进一步定位到ANE编译转换/校验，但无法单凭采样判定死循环、复杂度退化或具体系统编译器缺陷。后续需要保持制品一致的计算设备限制对照及数值验证；仅增加分类250ms预算不能解决尚未完成的模型加载。原始trace和XML留在/tmp；上述脱敏JSON已增加实时采样统计及符号栈。此前USB连接阻塞已经解除，历史失败记录保留。

## D3 Edge 继续聆听四分类实验（2026-11-16）

### 目的与冻结条件

只测现有本机 D3 Edge，逐字使用最新 App 的 `InputDecisionSnapshot.prompt()` 和 `AssistantDecisionProtocol.JEV`，生产提示词、期限及采纳规则未改。旧 `DecisionLanguageEvaluationTests` 的快照未显式开启 `allowsContinueListening`，因此旧实验只有三候选，不能解释第四类的效果。本次语音请求均显式携带 `1/2/3/4`，D3 模板映射 `A/B/C/D`；键盘对照仍为三候选。

主机为 Apple A18 Pro、8 GiB、macOS 27.2.1（26B131）。模型保持在 `Tests/DecisionBenchmarks/.local/models/D3Edge`，源 revision 为 `bee5e872f75b9c5d1405767bf244a6948b95c0af`，BF16 源图 SHA-256 为 `ca54b56a901d10db4e85a046aeaaaa65cde273afd2e18c47f3bb57487c3d6a78`。制品文件及生产输入相关源码在运行前后核对一致。请求 token 数由同一 Swift Tokenizers 和制品模板计算，并验证记录请求与真实 D3 入参一致。

### 样例与方法

冻结194条合成快照，中英文各97条，按输入语言使用对应生产提示。每种语言含91条语义样例与6条独立探测：

| 组 | 每种语言条数 | 用途 |
| --- | ---: | --- |
| 历史锚点 | 27 | 保留原双语实验标签，检测扩大候选后的表现；不是新提示的重新标注集 |
| 应继续聆听 | 24 | 缺宾语、参数、条件后半句、连接词、混说、未完成更正及已有缓冲 |
| 已补全片段 | 25 | 将持有片段与本次最终 ASR 用换行拼接，检查补全后是否正常处理 |
| 完整短回答 | 5 | 肯定、否定、数量、选择、“嗯”等待答回答 |
| 完整控制 | 8 | 停止、短暂停、新请求、补充、否定、引用及延后停止 |
| 噪声／填充音 | 2 | 噪声与独立犹豫音 |
| 采纳探测 | 2 | 有旧片段时的新噪声、持有空间不足 |
| 键盘探测 | 1 | 相同短文本仍只提供三候选 |
| 容量探测 | 3 | 历史、问题及三条缓冲填满后的长输入 |

预期在推理前固定，未根据输出改标签。“别说了，改成”已含明确停止指令，预期打断而不是继续聆听。已补全对使用预设的持有上下文，是条件快照对照，不声称上一条真实预测一定进入持有状态。每个请求的 payload 只含本次最终转写，Decision text 才拼接旧片段，符合 App 的噪声检查路径。`canHoldTranscript`遵守三片段和640 UTF-8字节限制；没有模拟整个到达队列。

两轮均串行，每语言预热三次。第一轮走真实 Assistant 分类器，包括250ms本地期限、2秒总期限、取消收尾及后置保护；第二轮逐字重放首轮的194条 DecisionRequest，仍用真实 D3 适配器但绕过 Assistant 截止和采纳，专门观察原生分类。没有云端或其他模型。两轮共388条计分/探测请求，另12条预热请求；超长拒绝和取消不算成功图读出。完整报告保留预热失败。

### 继续聆听命中

| 条件 | 应继续聆听 | 正确选4 | 召回率 | 其他语义样例误选4 | 语义样例超时 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 英文 · App真实期限 | 24 | 3 | 12.5% | 0 | 16/91 |
| 中文 · App真实期限 | 24 | 0 | 0% | 0 | 20/91 |
| 英文 · 原生读出诊断 | 24 | 3 | 12.5% | 1 | 不施加250ms期限 |
| 中文 · 原生读出诊断 | 24 | 0 | 0% | 0 | 不施加250ms期限 |

去掉期限也没有提高应继续聆听样例的命中。英文24条的原生结果为3继续聆听、17舍弃、3排队、1打断；中文为0继续聆听、12舍弃、1排队、11打断。两轮中首轮有及时有效结果的146条语义请求，重放选择全部一致。

原生读出的实例：

| 实际最新输入或拼接输入 | 预期 | D3选择 | App首轮采纳 |
| --- | --- | --- | --- |
| `Please help me` | 继续聆听 | 继续聆听 | 继续聆听 |
| `请帮我` | 继续聆听 | 打断 | 排队（该条首轮超时） |
| `明天提醒我，时间是` | 继续聆听 | 舍弃 | 排队（保护有效输入） |
| `如果明天下雨的话，` | 继续聆听 | 舍弃 | 排队（保护有效输入） |
| `我还没说完，我想要的是` | 继续聆听 | 排队 | 排队 |
| `Stop talking, and instead\nshow the photo.` | 打断 | 继续聆听 | 排队（该条首轮超时） |

英文正确的另外两条是 `Translate this sentence:` 和 `I have not finished. What I want is`。英文原生读出的误继续聆听表明“有持有片段”不保证模型能识别它已补全。

### 原始分类与采纳分开看

以下91条分母包含历史锚点；不要把它当成真实用户分布的准确率，也不能直接与此前三候选、不同主机/提示条件的总分相减。

| 条件 | 原始正确 / 91 | App采纳正确 / 91 | 未完成话语最终进入排队 |
| --- | ---: | ---: | ---: |
| 英文 · App真实期限 | 16 | 52 | 21/24 |
| 中文 · App真实期限 | 11 | 52 | 24/24 |
| 英文 · 原生读出诊断 | 21 | 不执行采纳 | 不执行采纳 |
| 中文 · 原生读出诊断 | 13 | 不执行采纳 | 不执行采纳 |

采纳保护主要把可理解文本的“舍弃”和空闲时的“打断”转成排队。它提高了输入保留率，但不会把明显未说完的话改成继续聆听。因此只看排队/未丢失，会掩盖第四类低召回。中文5条短回答全部被App保留，却没有一条在首轮得到正确的原始排队分类；中文25条已补全片段有23条经保护后正确处理。

### 容量、时延和因果边界

- 英文91条语义请求为341–370 tokens，中文为334–360 tokens，全部小于512。漏选4不是这些请求超长造成的。
- 填满历史、待答问题和三条缓冲时，英文容量探测为492、507、607 tokens；中文为674、695、835 tokens。英文最长及中文三条均被原生适配器明确拒绝，App排队。没有截断原文或扩展上下文上限。
- 第二轮无期限读出的英文原生p50/p95为240.07/253.17ms，10/91超过250ms；中文为257.94/272.26ms，76/91超过250ms。首轮App实际超时分别16/91与20/91。二者是不同轮次，不能按超时数量逐项对应。
- 两轮均先英文后中文，没有随机化顺序或热状态控制；这些时延是本机本次观测，不能把差值全归因于语言，不能替代iPhone时延。分数是候选softmax，不是校准置信度。
- 持有上限探测中模型没有选择4，因此本实验未实际触发“4→容量拒绝”的后置分支；没有据此声称该分支通过真实模型验收。

结论：第四选项已进入真实请求，语义上下文未超长，采纳层也未普遍拦截4；当前提示＋D3 Edge组合本身对未完成话语的召回很低，且250ms预算在这台A18 Pro Mac上存在压力。仅放宽期限不能解决本轮中文0命中。下一步可独立比较第四项边界/位置、候选文字描述和成对短例；这只是后续实验方向，本轮未改生产提示、模型选择或超时。

### 复现和证据

- [冻结194条样例](../measurements/decision-continue-listening-scenarios-2026-11-16.json)
- [App路径完整请求、原始输出、采纳及计时](../measurements/decision-continue-listening-d3-edge-2026-11-16.json)
- [无Assistant期限的原生读出诊断](../measurements/decision-continue-listening-readout-2026-11-16.json)
- [混淆矩阵、分类别统计与误判清单](../measurements/decision-continue-listening-summary-2026-11-16.json)
- [主机、制品manifest及前后哈希](../measurements/decision-continue-listening-artifact-2026-11-16.json)
- [实验入口和运行命令](../../Tests/IntegrationTests/README.md#d3-edge-continuation-classification-experiment)

两项真实D3实验均完成，源码前后校验通过。新增读出入口首次编译出现Swift并发捕获错误，修正后再执行；没有把失败编译计为模型请求。仓库验证结果另列在本节末尾。原有测试文件、模型位置和历史报告保持原样，仅新增本次入口/样例/结果并追加导航。

仓库验证：`scripts/build-ios.sh` 五个scheme及资源验证通过；新增两份Swift实验入口的严格格式检查、JSON结构/194条双轮配对/候选/哈希/新增链接验证、`git diff --check`通过。`scripts/check.sh`的架构边界和8项Python测试通过，但在本次未修改的`Actions/Speech/Listening/VoiceNativeEffects.swift:108`遇到`OnlyOneTrailingClosureArgument`格式错误并退出1，后续全量Swift测试未执行；未为通过检查改动该文件。日志为`/tmp/decision-continuation-{check,ios}-2026-11-16.log`与两项实验日志，属于本机临时证据；可长期查阅的请求与测量已保存到上述JSON。

## D3 Edge 提示词结构优化实验（2026-11-16，仅实验环境）

### 官方与公开集成调研

检索并阅读官方模型卡、vLLM serving/recipe、官方`d3_format.py`及公开集成方的自身文档，未把搜索摘要或社区讨论当成准确率证据：

- [官方格式代码](https://huggingface.co/vllm-sr/d3-edge/blob/main/d3_format.py)：原生模板按State、Question、Options排列；State被声明为数据，choice选项由键与说明组合。它支持把事实、任务指令和候选语义分开，不支持“规则必须放State、候选只写数字”的假设。
- [官方D3 Edge模型卡](https://huggingface.co/vllm-sr/d3-edge/blob/main/README.md)与[vLLM recipe](https://recipes.vllm.ai/vllm-sr/d3-edge)：公开用例把业务文本放state、具体分类问题放question.instructions、候选名称和解释放criteria。返回候选读出，无需模型生成解释或JSON文本。
- [Ollaya自己的D3集成示例](https://ollaya.cobanov.dev/library/d3)：同样使用事实state、短问题和有含义的criteria；其GPU性能数字不能替代本地CoreAI测量。
- [Vis自己的D3集成说明](https://vis.blockether.com/decision-models.html)：强调用自己的标签评估，状态、指令和候选共同占用token预算。它的ONNX容量及FP32运行设置与本仓库512-token BF16制品不同，未照搬参数。

据此形成实验假设：将规则移出State，给Options直接提供语义描述，可能比当前State内长规则加数字候选更符合D3格式。该假设不能由文档本身证明，以下用本地真实模型检验。官方公开资料没有提供本应用“继续聆听”任务的现成最优模板。固定旧revision的格式网页未能由检索工具打开；本地适配器模板与已读main格式核对，制品仍用原revision，未下载或执行网络代码。

### 方法与开发集结果

只修改实验请求，生产资源/实现、现有模型位置和旧测试文件保持不变。首轮7组×194请求，第二轮4组×194请求，另有每条件3次预热。每组排除12条容量/采纳/键盘探测，语义分母为182，含48条预期继续聆听。比较的是原生选择，无App采纳、无250ms截止；所有期限超标只是观测，不能算生产已接纳。候选行显式映射回业务标签，重排不改变评分含义。按样例ID配对，轮转条件次序，串行执行。

48条新留出快照在开发实验前冻结，直到完成开发选择后才运行。第二轮追加的原因和方案在运行前记录：首轮仍有大量误舍弃，尝试直接分类“话语状态”而不是让小模型选择应用操作。最后按全部开发集四类macro-F1最高选一组，误判作为风险同时保留，没有用留出调模板。三次实验的生产源码前后哈希均一致。

| 方案 | 正确 / 182 | macro-F1 | 继续聆听命中 / 48 | 继续聆听精确率 | 误继续 | 误打断 | 误舍弃 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 生产原样基线 | 34 | 0.183 | 3 | 75.0% | 1 | 49 | 92 |
| 只将规则移到Question | 34 | 0.170 | 0 | 0.0% | 3 | 35 | 93 |
| 紧凑事实＋语义动作选项 | 44 | 0.263 | 3 | 37.5% | 5 | 19 | 114 |
| 语义动作＋边界短例 | 58 | 0.340 | 8 | 47.1% | 9 | 22 | 87 |
| 继续聆听候选前置 | 62 | 0.369 | 15 | 53.6% | 13 | 22 | 80 |
| 统一英文规则＋短例 | 82 | 0.464 | 17 | 45.9% | 20 | 16 | 50 |
| 官方式短问题＋说明选项 | 34 | 0.212 | 0 | 0.0% | 0 | 5 | 143 |
| 直接描述话语状态（入选） | 113 | 0.625 | 23 | 51.1% | 22 | 10 | 15 |
| 话语状态＋语法缺口说明 | 100 | 0.573 | 35 | 43.8% | 45 | 10 | 18 |
| 语法缺口＋最小状态 | 99 | 0.557 | 39 | 45.9% | 46 | 10 | 24 |
| 未完成状态候选前置 | 99 | 0.583 | 36 | 42.4% | 49 | 10 | 14 |

“官方式”只是格式对齐，不能自动保证本任务有效：仅移动规则没有改善；最短问题组仍把48条未完成话语全部判为舍弃。统一英文规则比同语种规则有帮助；这些是本组实验的结果，不是官方宣称只支持英文。入选方案用英文询问“哪种描述符合用户话语”，候选描述stop_request、non_speech、complete_utterance、unfinished_utterance，再由实验映射到原四类动作。它没有加few-shot例子，保留当前问题、历史和缓冲事实。

入选方案开发集正确113/182（62.1%），原样基线34/182（18.7%）；中英文分别50/91与63/91。继续聆听召回23/48（47.9%），但误继续22条，其中18条应排队、4条应打断。将未完成候选前置或强调语法缺口可提高召回，却让误继续进一步增加，因此没有仅按召回选方案。

### 预冻结留出复核

留出48条是24个双语情境，包括8个未完成/补全对、短回答、完整命令、明确停止、引用/否定、噪声。它们是合成且双语配对的小样本，不等于48个独立真实用户场景。只运行基线与入选方案，共96请求，另6次预热。没有依据结果再改提示。

| 条件 | 正确 / 48 | macro-F1 | 继续聆听命中 / 16 | 继续聆听精确率 | 误继续 | 误打断 | 误舍弃 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 生产原样基线 | 6 | 0.106 | 0 | 0.0% | 0 | 24 | 14 |
| 直接描述话语状态（入选） | 29 | 0.658 | 13 | 52.0% | 12 | 2 | 3 |

入选方案留出正确率为60.4%，继续聆听召回81.3%，但精确率只有52%；12条应排队的完整话语被误认为未说完。中文未完成8条命中6条，英文8条命中7条。该结果支持作为下一轮实验基线，不足以直接替换生产；开发集中4条应打断话语被延后也不能被留出中的停止命中掩盖。

### 实验模板与使用边界

[完整实验模板及动作映射](../measurements/decision-prompt-optimization-template-2026-11-16.json)保留实际测试的英文Question与Options。State只放事实，输入原文保留中文/英文，接续片段仍用换行组合。布局为：

```text
State: {utterance, assistant_busy, question_to_user,
        preceding_assistant, preceding_user, queued_inputs}
Question: Which description best matches the user utterance? ...
Options:
A: stop_request: ...
B: non_speech: ...
C: complete_utterance: ...
D: unfinished_utterance: ...
```

以上是实验概览，精确英文内容以JSON为准。它沿用D3固定系统模板和候选读出，没有要求生成解释、思维链或JSON文本。生产JEV仍传数字候选；未来采用语义候选需要同时适配候选到动作的映射，不能只替换资源文字。本轮没有实施这类生产变更，也未重新安装手机。

入选方案开发集288–309 tokens，基线334–370；本机图仍固定512长度，因此token缩短不保证图推理变快。开发集原生p95分别287.76ms与280.84ms；留出入选p95为259.82ms，仍有8/48超过250ms。热状态和样本不同，不能据此宣称延迟降低；本轮仅A18 Pro Mac原生读出，未验证App竞速、ASR、真实对话到达或iPhone体验。

### 文件与复现

- [首轮完整请求](../measurements/decision-prompt-optimization-input-2026-11-16.json)、[首轮逐条结果](../measurements/decision-prompt-optimization-results-2026-11-16.json)、[首轮汇总](../measurements/decision-prompt-optimization-summary-2026-11-16.json)
- [第二轮完整请求](../measurements/decision-prompt-optimization-refined-input-2026-11-16.json)、[逐条结果](../measurements/decision-prompt-optimization-refined-results-2026-11-16.json)、[汇总](../measurements/decision-prompt-optimization-refined-summary-2026-11-16.json)
- [预冻结留出样例](../measurements/decision-prompt-optimization-holdout-2026-11-16.json)、[选型记录（留出前）](../measurements/decision-prompt-optimization-selection-2026-11-16.json)、[留出实际请求](../measurements/decision-prompt-optimization-holdout-input-2026-11-16.json)、[逐条结果](../measurements/decision-prompt-optimization-holdout-results-2026-11-16.json)、[汇总](../measurements/decision-prompt-optimization-holdout-summary-2026-11-16.json)
- [请求生成/评分说明](../../Tests/DecisionBenchmarks/README.md#实验环境提示词优化)、[Swift原生入口](../../Tests/IntegrationTests/README.md#experimental-d3-prompt-optimization)

三次真实D3实验均通过，共2230条计分/探测请求，另39条预热。超512的探测拒绝不计为成功图调用。新留出基线的生成器已与194条存档生产请求逐字校验一致。所有输入/结果保留哈希和选项映射；第一次生成输入时处理了可选question字段缺省的JSON解析问题，该准备错误没有计作模型推理。

### 工程验证

三组opt-in真实模型测试通过；输入、实验runner和8项冻结源码/样例哈希复核一致。`./scripts/build-ios.sh`成功完成五个scheme构建，属于构建验证，不代表真机验收。`./scripts/check.sh`通过边界检查和8条Python测试后，因原有工作区`MobileHarness/Actions/Speech/Listening/VoiceNativeEffects.swift:108:27`的`OnlyOneTrailingClosureArgument`格式错误退出，未执行后续完整Swift测试；未修改该任务外文件。本次新增Swift实验入口另行严格格式检查，Python脚本语法及diff空白检查通过。

## App 采用话语状态 JEV 提示（2026-11-16）

经用户明确要求，将上述utterance_status模板接入Assistant生产JEV路径。State包含原文及有界上下文JSON；Question和四个描述选项与实验模板逐字一致（中英文资源均使用英文规则），候选按提交顺序映射回四个业务动作。键盘仍只有前三项。日志记录真实State/Question/Options。Chat Tool/Text保持原协议，D3 Edge/Lite共用JEV适配器；本轮没有新增Lite模型测量，旧实验结论仍仅适用于Edge。

这次接入不会消除前述误继续风险，也未改变250ms预算、512token容量和语音持有上限。历史实验JSON及哈希保持原样；要求旧源码哈希的历史重放必须在相应代码版本运行，不能把生产迁移后哈希不一致视为旧实验通过。

生产两份JEV模板与入选JSON逐字校验通过；修改文件的Swift严格格式检查及diff空白检查通过。验证命令为`./scripts/check.sh`、`./scripts/build-ios.sh`与`swift test --filter 'Decision|decision|PromptTemplate|promptTemplate'`。首次受沙箱缓存/模拟器服务限制，已按工具权限重新运行；结果见下方最终记录。本轮未安装手机，未进行新一轮真实ASR或真机模型验收。

最终记录：五个iOS scheme全部构建成功。Decision/Prompt专项命令退出0，其中IntegrationTests的92项通过（包含双语JEV新回归），其余匹配目标也通过，opt-in真实模型实验未开启。全量check通过边界、8条Python和严格Swift格式检查；其IntegrationTests共1204项运行有4项失败：readyD3ReportsItsSelectionAndDoesNotCallCloud、slowTrackingDispatchExecutesOnlyTheNewestPendingTarget、nativeVoiceProcessingKeepsRecognitionActiveDuringReplies、completedASRContinuesWithoutAcknowledgmentAndPlaybackUsesRouteCapability。AppWorkflowTests另有多项resourceMissing("injected Action declarations")，该阶段运行超过五分钟且日志不再推进后主动中止，因此全量检查未通过，后续阶段未完成。

D3替身断言在专项回归中通过，全量并发中失败（该测试使用5秒本地预算）；随后用SwiftPM testing helper直接执行已编译的三个D3测试（readyD3、jevSpeechState、speechDecisionFourthChoice），补齐Xcode XCTest framework/library路径后退出0，三个测试及双语参数均通过。直接启动前两次因XCTest动态加载路径不完整而未能启动测试，不计为通过。上述差异与并发负载相符，但没有证明全量失败的唯一原因；不通过扩大生产期限隐藏问题。运行日志位于本机`/tmp/decision-app-semantic-{tests-authorized,ios-authorized,check-authorized,direct-recheck}.log`。

## 仅保留模型丢弃结果（2026-11-16）

按用户再次限定的范围，仅移除AssistantInputDecision.outcome中将`discard + possibleSpeech`改为enqueue的分支。有效语句、键盘文本、短回答及绑定问题的答案也保留模型discard。其他噪声判定、idle interrupt转enqueue、缓冲满转discard、模型失败默认enqueue、全部聆听与播报策略保持原样。此前未完成的可选采用值、失败不入队和执行端容量迁移已全部撤回。

回归覆盖本地/云端模型丢弃、短答案与idle interrupt区别，以及worker对噪声/有效语音/键盘的实际丢弃反馈和不调用主模型。旧实验记录仍是历史证据，不重算原结果。

验证：专项`swift test --filter 'inputDecision|readyD3|speechDecision'`退出0，13项测试及参数化用例通过，覆盖模型discard保持、worker不调用主模型，同时验证噪声、idle interrupt、失败入队和接续流程仍保持原行为。五个iOS scheme构建全部成功。按代码段比较确认outcome及transcriptContent相对于原实现仅少了discard→enqueue分支。diff空白检查通过。

`./scripts/check.sh`通过边界、8项Python和Swift格式检查；全量IntegrationTests的1204项有8个问题，后续AppWorkflowTests出现缺少injected Action declarations及UI/采集生命周期断言失败，运行超过三分钟无新日志后停止。本轮未修改这些模块以追逐全量失败，后续全量检查阶段未完成。日志为`/tmp/decision-discard-only-{tests,check,ios}.log`，不将全量检查称为通过。本轮未安装真机。

## 继续聆听容量满时释放入队（2026-11-16）

用户要求容量满不能丢弃当前输入：仅把continueListening且canHoldTranscript=false的采纳结果改为enqueue，并记录容量原因。worker复用已有入队批次逻辑，将原持有片段与当前输入合并释放。扩展speechDecisionHoldsIncompleteInputOutsideQueueAndReclassifiesJoinedText的bufferFull参数，验证模型仍选continue_listening、采纳enqueue、所有片段送入主模型、只创建一次消息；正常继续聆听/噪声丢弃/补全释放场景仍保留。

前置噪声处理与文本规则不等价：音频增强和VAD不保证ASR最终不会输出非空噪声标记。SpeechRecognitionTurn.finish仅修剪空白，SpeechPerceptionAgent.finishUtterance仅对空字符串停止投递；非空final会进入Assistant Decision，噪声词表在模型输出后的outcome执行。此轮未修改这条路径及其优先级。

验证：`swift test --filter 'speechDecisionHolds|inputDecision|readyD3'`退出0，12项专项测试及参数化用例通过；缓冲满/未满的worker用例均通过。`./scripts/build-ios.sh`五个scheme全部构建成功。`./scripts/check.sh`通过边界、8项Python及Swift格式检查，但全量IntegrationTests的1204项出现5个问题（含并发下分类断言失败，专项通过）；AppWorkflowTests再次出现缺少injected Action declarations等失败后停止，后续阶段未完成，不算全量通过。未扩大修改范围处理这些失败。日志为`/tmp/decision-buffer-enqueue-{tests,check,ios}.log`。diff检查通过；未进行新的真机/ASR模型验收，噪声说明是代码路径分析，不代表已实测当前ASR会输出这些标记。

## ASR 输出协议核查与删除文本噪声猜测（2026-11-16）

核查范围由生产注册确定：Nemotron本地模型以及Apple Speech的en-US、zh-CN实例，并非从其他ASR的输出习惯推断。

- Apple：生产使用SpeechTranscriber + SpeechDetector(reportResults:false)。[官方初始化文档](https://developer.apple.com/documentation/speech/speechdetector/init(detectionoptions:reportresults:))说明检测器默认启用VAD而不向调用方报告结果；[results文档](https://developer.apple.com/documentation/speech/speechdetector/results)明确当前结果流除抛错外保持空。它不是噪声词表，也不能当作可接入的逐条噪声分类标签。该原生检测器已经使用，未删除。
- Nemotron：生产为FluidInference的Nemotron 3.5 multilingual CoreML。其[发布方模型卡](https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML)说明RNN-T转录部署；[NVIDIA原模型卡](https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b)定义输出为输入语言的文字字符串，公开的特殊输出涉及语言标签，没有为本项目noiseMarkers提供协议支持。当前适配器仅发布转录text/revision/finality；RNN-T blank不是可当作噪声文字的标签。
- 结论是“没有可依赖的噪声词表协议”，不是断言模型永远不可能生成这些字符。之前把手写词表称为ASR能力没有依据。历史实验中的[noise]等输入是人工构造场景，不能反过来证明ASR会输出它们。

删除内容：AssistantInputDecision的TranscriptContent、noiseMarkers、标点/问号/语气词启发式、噪声强制discard、失败时噪声discard例外，以及无调用方的protectsAnswer计算属性。Decision提示中去掉“ASR noise/silence marker”的假设，不再宣称与旧实验模板逐字一致，不推断准确率提升。旧实验JSON保留为历史证据。

保留内容：模型discard决定、idle interrupt转enqueue、继续聆听容量满转enqueue、失败默认enqueue，以及所有音频增强/VAD/原生SpeechDetector/播报准入/空识别结果处理。本轮没有新加一个Decision前的文本黑名单。回归将旧词表文字、标点、语气词作为普通人工文本，检查四类模型输出不被内容规则覆盖，并检查失败按既定策略入队。

验证结果：14项Decision专项测试及参数化用例通过，包含四类动作对人工标记/标点/语气词的保真及失败入队；五个iOS scheme构建成功。`check.sh`通过边界、8项Python及格式检查，全量IntegrationTests的1205项有7个问题（包含本轮专项通过而全量并发失败的分类断言）；后续AppWorkflowTests再次出现resourceMissing("injected Action declarations")后停止，未完成其余阶段。全量检查未通过，没有因此改动其他模块。日志：`/tmp/decision-remove-noise-{tests,check,ios}.log`。diff检查通过。未进行新的ASR/真机实测，不将文档核查描述为识别效果验收。

## 真机 discard 反馈复核（2026-11-16 22:05）

用户截图显示 D3 Edge 原始与采纳结果均为 discard，包含 Open the camera.；附件给出了 Do not ignore this message. 的完整 State/Question/Options。后者作为逐字回放，其他截图话语与中文/未完成话语作为构造对照，分别保留附件历史或清空历史。没有将构造上下文冒充手机实际快照。

确认当前 JEV 中 A/B/C/D 与 interrupt/discard/enqueue/continue_listening 映射一致。当前资源与附件 Question/Options 一致，但与原入选实验的 B 不同：删除噪声词表时，B 从历史的 “The input is only an ASR noise/silence marker or a standalone hesitation sound with no question to answer.” 改为 “The input contains no meaningful speech or is a standalone hesitation sound with no question to answer.”。旧描述仅作为实验控制，不恢复它的 ASR 协议假设。

复用现有 D3PromptOptimization 原生入口、同一 Mac D3Edge 本地制品，逐对仅改变 B，其他 State/Question/A/C/D、动作映射相同；制品及源码哈希运行前后相同，无生产超时/采纳覆盖。首次准备因对模型目录调用 read_bytes 失败，修正为逐文件哈希后再运行；失败准备没有计入模型结果。使用已构建测试产物 --skip-build，未修改任何 Swift/App 资源。

| 请求集 | 历史候选 | 当前候选 |
| --- | --- | --- |
| 现场及构造对照 12 条 | discard 3/12 | discard 12/12 |
| 原冻结留出 48 条：正确 | 29/48（60.4%） | 13/48（27.1%） |
| 原冻结留出 48 条：discard | 7/48 | 35/48 |

原留出历史候选的 48 个标签与原存档逐条一致，支持历史实验可复现；当前候选明显退化。原样附件当前输出 discard，候选归一化分数 0.5592；历史 B 输出 enqueue，分数 0.3515。这些分数不是校准后的正确概率。清空历史后的 Open the camera. 当前也输出 discard，说明这组失败不依赖历史。旧版也会误判相机请求，因此不能仅回退 B 就宣称修复。

结论：历史实验测量可复现，但它只达到 60.4% 留出正确率，不能称为生产可靠。删除噪声描述后的实际新模板没有经过真实模型复测，之前的模拟回归/构建不能覆盖这个语义退化。这是实验结论应用与后续变更验证的缺口。当前模板在这些样本上对 B 有强偏向；单因素对照证明 B 的措辞变化会导致分类变化，不能据此推断模型内部的具体原因。

Mac 使用源图，手机 catalog 指向 h18p AOT；本轮未重新读取手机模型制品，也未测两者逐 logits 一致性。但 Mac 已复现当前模板的大量 discard，不能仅归因于手机 AOT。请求均小于512token，模型输出有效；不是容量拒绝或 fallback。两个真实实验完成 120 个评分请求与 12 次预热，源码哈希验证通过。本轮只追加实验输入、结果和文档，未修改 App 提示词、结果采纳或安装版本；未重复 App 构建/全量检查。

证据：[汇总](../measurements/decision-discard-recheck-summary-2026-11-16.json)、[现场回放输入](../measurements/decision-discard-device-replay-input-2026-11-16.json)、[现场回放结果](../measurements/decision-discard-device-replay-results-2026-11-16.json)、[留出对照输入](../measurements/decision-discard-holdout-recheck-input-2026-11-16.json)、[留出对照结果](../measurements/decision-discard-holdout-recheck-results-2026-11-16.json)。

## 精简 JEV 接入与安装（2026-11-16）

用户要求将前述简短模板用于 App。JEV State 仅保留 utterance 和 assistant_busy；中英文资源统一短 Question 与 Interrupt/Discard/Enqueue/Continue listening 定义。历史、待回答问题与队列仍由原快照供 Chat 协议使用，不再进入 JEV；接续文本仍按现有流程合并。未改变任何结果采纳规则。Assistant README 与双语契约回归已同步。

双语 JEV 契约回归通过，验证 State 仅两项、原文转义、播放态 busy、四类映射及键盘三候选。真实 D3 Edge 使用原位置模型重放六条最小上下文请求，原始分类仅1/6正确：Do not ignore this message.、Do not discard this message.、不要忽略这条消息。均选择interrupt；Open the camera. 与 I want to 均选择discard；打开相机。选择enqueue。输入186–188token，全部有效返回，源码/模型哈希前后相同。原有idle interrupt采纳入队不计为模型分类正确。该小样本不代表总体准确率，但明确显示精简后仍不能稳定判断基本输入。

[最小请求](../measurements/decision-minimal-app-input-2026-11-16.json)与[原始结果](../measurements/decision-minimal-app-results-2026-11-16.json)保存原实验位置。直接调用SwiftPM测试helper的前两次尝试因XCTest动态依赖缺失失败，未执行模型；补齐Xcode的DYLD_FRAMEWORK_PATH/DYLD_LIBRARY_PATH后，使用刚编译的同一测试bundle成功完成6条及3次预热。标准swift test排队入口在共享构建锁等待期间终止，没有重复写结果。并行构建与全量检查影响延迟，本轮不作性能结论。

真机 Debug 构建成功，严格深层签名、73项Agent/Skill、Live Activity及中英文资源检查通过。安装包两份InputDecision资源与源码逐字节一致。已原位安装至Youwei’s iPhone 17 Pro，回执序号7220，并收到Launched application成功启动回执。构建、安装及启动日志 `/tmp/decision-minimal-device-{build,install,launch}.log`。未清除用户数据；安装启动不等于真机分类效果验收。

仓库检查：`./scripts/build-ios.sh` 五个scheme全部成功。`./scripts/check.sh` 的边界检查、8项Python及严格格式检查通过；全量IntegrationTests 1204项报告19个问题，另AppWorkflow出现Writer/Web缺失injected Action declarations等错误并持续不再推进，主动停止本次检查及其子进程，后续独立原生阶段和plist阶段未运行。因此全量检查未通过。没有修复范围外测试。日志 `/tmp/decision-minimal-{tests,ios,check}.log`；diff空白检查通过。

## Vela3 Fast 本地补充对照（2026-11-17）

### 制品与接口

核对[发布模型](https://huggingface.co/hugging-mac/vela3-fast-CoreAI/tree/6aaa9ccd747c4bad65037979e7f9373a76fb7683)，固定 revision 6aaa9ccd747c4bad65037979e7f9373a76fb7683，上游 revision fa60e3aa41132c60bf05a84cabfdced39cb6d4f7。网页工具连接失败后读取 HF API，核对另一项目发布目录的26个文件，均与远端 LFS SHA-256 或 Git blob 哈希匹配。逐文件 SHA-256 在 Tests/DecisionBenchmarks/vela-model.json。经用户批准，制品存放于 .local/models/Vela3Fast，与 D3Edge 并列。

这是 FP32 decision backbone 的实验转换，支持 choice/noul，不是完整上游任务适配器或生成模型。Vela 使用 [Q]/[O]/[SEP_SCHEMA]/[SEG_user] 编码，输入 input_ids、attention_mask、option_positions、pool_mask，输出动态候选 logits。声明输入上限32768，发布方实际CPU校验到2048token；本轮未验证长输入、GPU/ANE或iPhone。D3使用聊天模板、固定512token和255码读出，两者不能混用编码。发布说明中的12/12上游一致性不是本App四分类准确率。

### 方法与结果

固定原48条留出场景，对比历史 utterance_status 和当前 minimal 两套条件，各另加6条诊断，共108条。每条件预热3次，轮转条件顺序，串行推理；不套App采纳规则或250ms deadline。候选键A/B/C/D、候选描述及顺序与D3相同，使用Vela发布适配器原生编码。两个模板同时改变上下文和描述，不能据此单独归因于上下文长度。本轮未根据输出改提示或重标答案。

复用另一项目已安装的Python3.12环境，coreai-core1.0.0b3、numpy2.3.5、tokenizers0.23.3，Vela显式CPU。耗时包括编码和推理，排除加载及预热；加载约16.5秒。所有108条有效返回，源码及输入哈希前后相同，制品结束后复核。只测固定A/B/C/D格式，不声称已找到Vela最佳候选命名或提示。

| 模型及模板 | 正确/48 | macro-F1 | 误discard | 继续聆听命中/16 | P50/P95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Vela CPU，minimal | 19（39.6%） | 0.401 | 19 | 0 | 144 / 161 |
| Vela CPU，utterance_status | 7（14.6%） | 0.205 | 40 | 0 | 235 / 267 |
| D3自动模式，utterance_status，历史已复现 | 29（60.4%） | 见历史留出 | 3 | 13 | 不作本轮速度配对 |
| D3，本轮minimal留出 | 未取得 | — | — | — | — |

Vela minimal留出0/48超过250ms，utterance_status为5/48。6条诊断单列：minimal仅1/6正确，英文Open the camera.入队，中文打开相机。却discard，I want to错误入队；utterance_status为0/6且全部discard。诊断不混入留出分母。

D3历史utterance_status的48条完整请求已与本次逐项核对一致，可作带日期的历史准确率参照；不是本轮成功原生重测，不能进行当前负载下速度比较。历史minimal诊断1/6也不能外推D3在48条minimal场景上的成绩。

### 失败与限制

Vela完成后磁盘耗尽。本轮复制的大图已改为APFS克隆并重新验哈希；未清理向用户请求但尚未获批准的模拟器缓存。D3自动模式两次加载失败，重试明确报LLVM IO failure / No space left on device，均0条评分。CPU首轮因transformers返回BatchEncoding造成编码失败，改回原有render字符串再encode；随后发现输出形状(1,255)，但全部255项非有限。最终入口在第一次预热明确失败并停止，0条评分。一次脚本缩进错误在模型执行前修正。编码、加载、非有限值失败均不计为语义准确率0%，不能据此证明iOS AOT有问题。

结论：Vela四候选推理可运行，但当前两套固定模板没有显示可替换D3的分类能力，继续聆听召回为0。精简条件相对较好，完整表达误discard仍明显。后续可独立验证Vela语义候选键和任务描述，但不能凭12个基础发布例子或低时延直接接入。App目录、生产提示、采纳及手机安装本轮均未修改。

证据：[配对输入](../measurements/decision-vela-d3-input-2026-11-17.json)、[Vela结果](../measurements/decision-vela-results-2026-11-17.json)、[汇总](../measurements/decision-vela-d3-summary-2026-11-17.json)、[D3最终CPU失败](../measurements/decision-d3-cpu-vela-final-results-2026-11-17.json)、[运行说明](../../Tests/DecisionBenchmarks/README.md#vela3-fast-paired-comparison)。自动模式空报告及中间失败报告保留为失败记录，不作为完成结果。

验证收尾：Vela全部108条完成，结果JSON、脚本语法、概率归一化、制品/源码/输入哈希及git diff --check通过。`build-ios.sh`五个scheme全部构建通过。`check.sh`边界、8项Python和严格Swift格式通过；1204项IntegrationTests有7个问题，AppWorkflow随后报缺失Action声明等错误并停止推进，终止本次检查及子进程，未执行后续独立原生/plist阶段。全量检查未通过。日志 `/tmp/vela-comparison-{check,ios}.log`。新实验没有生产代码修改，构建结果不代表Vela iOS验收。

## Hello 真机请求原样回放（2026-11-17）

用户提供的完整State为`{"utterance":"Hello.","assistant_busy":false}`，Question/四候选与当前minimal资源逐字一致。原Mac D3自动模式入口完成3次重复评分，均输出discard，分数0.7523189187，184token，约200–208ms；源码和输入哈希前后相同。该误判不是仅在手机出现，也不能与旧utterance_status的60.4%混比。原始请求及结果为decision-hello-phone-replay-{input,results}-2026-11-17.json。

只读检查手机D3Edge目录和安装收据，确认已装decision.aimodel源图，revision为0690c04ee1640c1c3fa11a882323751dda6d086a；不是此前h18p AOT目录。元数据不能单独证明内存中正在执行的图或全权重内容一致。

手机完整main.mlirb已只读导出并计算SHA-256，ca54b56a901d10db4e85a046aeaaaa65cde273afd2e18c47f3bb57487c3d6a78与Mac完全一致；manifest、decision_config和main.hash也一致。见[手机制品核对](../measurements/decision-hello-device-artifact-check-2026-11-17.json)。这排除已检查文件内容不一致，不证明跨平台运行数值一致，也不排除共同转换问题。

## 恢复自有制品及discard边界对照（2026-11-17）

用户反馈第三方制品也频繁discard，要求恢复自有repo并优化提示。App Edge source及requiredFiles完整恢复到DecisionBenchmarks/models.json中的hugging-mac/d3-edge-CoreAI、revision0690c04ee1640c1c3fa11a882323751dda6d086a，原始三输入decision.aimodel，大小1013189709，无AOT覆盖。Lite未变；生产提示及模型结果采纳均未改。

在自有Mac制品及原生Swift入口运行两轮，各4条件×55请求=220条，合计440条评分及24次预热。48条旧留出已经多次观察，本轮称回归集，不再称独立留出；另有7条诊断，包括Hello及既有6条。使用同一冻结预期动作，不根据输出重标。第一轮仅修改minimal的C定义、B定义、或两项组合；第二轮回到历史utterance_status，只改B，保留历史原样作为控制。第二轮方案在执行前写入计划；未将ASR噪声词表或相关假设恢复到生产。

| 条件 | 正确/48 | 误discard | 继续聆听命中/16 |
| --- | ---: | ---: | ---: |
| minimal原样 | 18 | 21 | 0 |
| minimal仅C补问候/命令 | 8 | 32 | 0 |
| minimal仅B改为unintelligible | 24 | 9 | 0 |
| minimal两项组合 | 8 | 21 | 0 |
| 历史utterance_status参考 | 29 | 3 | 13 |
| 历史结构，B的ASR短语替换为unintelligible text | 18 | 21 | 4 |
| 历史结构，B仅保留hesitation | 29 | 5 | 12 |
| 历史结构，B改为no recognizable words | 14 | 27 | 2 |

补问候定义让Hello进入enqueue，但使总体准确率下降；不能把单条修正当成整体改善。仅收窄discard虽减少误丢弃，仍未恢复继续聆听能力。历史结构hesitation条件回归正确29/48，但7条诊断仅I want to正确继续聆听，Hello及中英文相机命令等仍discard。因此本轮没有可上线的新候选，也未自动应用分数最高项。现有证据支持模型对候选文字高度敏感，不能单凭这两轮推断内部原因或宣布纯提示工程能达到目标。

两轮无推理错误，源文件和输入哈希前后相同。证据：[第一轮输入](../measurements/decision-discard-boundary-input-2026-11-17.json)、[第一轮结果](../measurements/decision-discard-boundary-results-2026-11-17.json)、[第二轮输入](../measurements/decision-discard-status-refinement-input-2026-11-17.json)、[第二轮结果](../measurements/decision-discard-status-refinement-results-2026-11-17.json)、[汇总](../measurements/decision-discard-refinement-summary-2026-11-17.json)。


## Vela 3.1 Fast 固定矩阵对照（2026-11-18）

结论：在本项目冻结的四分类模板上没有改善。minimal 比旧 Vela 少正确5条，误丢弃增加9条；utterance_status 两版结果相同；继续聆听均为0/16。不能依据新模型的公开通用基准提升推断本任务改善。

### 制品、方法和范围

使用 [hugging-mac/vela3.1-fast](https://huggingface.co/hugging-mac/vela3.1-fast)，revision `108e385769cbd0da463706b24cac5a535604d2c6`，SDK decision-only CoreAI CPU 路径。仅准备决策图、权重与配置/tokenizer九个必要文件，保留原目录中的旧 Vela/D3。原始权重来源为 vllm-sr/vela3.1-fast。[上游模型说明](https://huggingface.co/vllm-sr/vela3.1-fast#why-31)声称增加多语言训练、问题/选项格式扰动及带定义的 noul；这些不等于本任务实测结论。具体制品见 [模型说明](../../Tests/DecisionBenchmarks/vela31-model.json)。

原样复用108条请求：两种模板各48条既有回归样本和6条诊断；这批样本已多次使用，不再视为新的独立留出集。候选顺序、定义、预期标签不调整。Vela 3与3.1在同一Mac、同一 Python 3.12/coreai-core 1.0.0b2 环境串行运行；每条件3次预热。D3只引用逐项请求一致的历史结果，未重跑。

| 模型/模板 | 正确/48 | macro-F1 | 误discard | 继续聆听命中/16 | P50/P95 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Vela 3 minimal，本轮 | 19 (39.6%) | 0.401 | 19 | 0 | 179 / 200 |
| Vela 3.1 minimal，本轮 | 14 (29.2%) | 0.328 | 28 | 0 | 341 / 512 |
| Vela 3 utterance_status，本轮 | 7 (14.6%) | 0.205 | 40 | 0 | 290 / 332 |
| Vela 3.1 utterance_status，本轮 | 7 (14.6%) | 0.205 | 40 | 0 | 585 / 991 |
| D3 utterance_status，11-16历史 | 29 (60.4%) | 0.658 | 3 | 13 | 不作本轮速度比较 |

两版各108条正式推理均无执行错误。诊断与回归集分别计分，详见原始数据。额外用3条原始 checkpoint 参考请求检查3.1的完整输出/usage/标签，最大绝对分数差9.69e-8以内；包括多语言、多问题和单选项。这支持所用加载/读出路径在这些案例上与原模型一致，不代表所有输入都已验证，也不是iOS数值验收。

8 GiB主机存在约7.6 GiB交换空间使用，记录于环境文件。时延包含编码、推理与解码，不含加载/预热；固定串行执行也不能消除不同时段的内存压力，不能把所有延迟差归因于模型架构。新制品使用外部FP32主干权重，旧制品布局不同。初次普通复制因磁盘空间不足失败，删除本任务的残缺目标后改用APFS克隆并核对内容；未删其他项目文件。

证据：[Vela 3.1逐条结果](../measurements/decision-vela31-comparison-vela31-four-2026-11-18.json)、[Vela 3复测](../measurements/decision-vela31-comparison-vela3-four-2026-11-18.json)、[配对汇总](../measurements/decision-vela31-comparison-paired-2026-11-18.json)、[参考输出对齐](../measurements/decision-vela31-native-parity-2026-11-18.json)、[主机记录](../measurements/decision-vela31-environment-2026-11-18.json)。二分类另见[独立报告](Decision-Binary-Interrupt-Mac-Comparison.md#vela-31-fast-固定矩阵对照2026-11-18)。本轮不修改App，不安装真机，不将Mac结果当作手机效果。

本轮脚本/汇总/工程检查记录统一见[二分类报告本次工程验证](Decision-Binary-Interrupt-Mac-Comparison.md#本次工程验证)，不以工程构建代替模型或手机验收。


## Laya Multilingual CoreAI 固定矩阵（2026-11-18）

使用 [mlboydaisuke/Laya-Multilingual-CoreAI](https://huggingface.co/mlboydaisuke/Laya-Multilingual-CoreAI/tree/3fe58a5ed7857b41f5c7ba8c0f46ce420b42cf02) 的 macOS wfp16-s512 源图，固定revision `3fe58a5ed7857b41f5c7ba8c0f46ce420b42cf02`；来源为 convaiinnovations/laya 的multilingual子目录 `1c5edc17a7acd8701df6fc341c0d179f1c62c982`。FP16仅为权重存储，计算FP32；正式运行显式GPU、debug-enabled specialization。发布host完成marker读出、act调用和温度解码，act不参与分类覆盖。App未改。

先试的 ahmedandaloes/laya-multilingual-CoreAI 1024图未能加载，b2 CPU、默认模式及隔离b3 CPU均无评分。该失败图已删除以释放空间，制品说明/失败日志保留。替代512图CPU亦加载失败，GPU成功；随后遇到明确磁盘不足，改为复用本任务已生成的GPU specialization，未删除其他模型或用户文件。不能据此断言首轮通用加载错误全部源于磁盘，也不能把它们计为分类错误。

正式运行前完成发布201条reference：输入token/marker全部一致，选择全部一致，T=1最大概率误差8.11e-6，小于1e-3门槛。这同时检验Laya0.4.2 host与发布者0.3.4 fixture的兼容性；不代表iOS或所有可能输入验证。正式业务case使用bundle自带校准温度，不针对本任务拟合。

| 模型/模板 | 正确/48 | macro-F1 | 误discard | 误interrupt | 继续聆听命中/16 | P50/P95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Laya minimal | 6 (12.5%) | 0.114 | 11 | 25 | 1 | 157 / 166 |
| Laya utterance_status | 17 (35.4%) | 0.257 | 3 | 2 | 15 | 157 / 162 |
| Vela 3 minimal，前轮CPU | 19 (39.6%) | 0.401 | 19 | 1 | 0 | 179 / 200 |
| Vela 3.1 minimal，前轮CPU | 14 (29.2%) | 0.328 | 28 | 2 | 0 | 341 / 512 |
| Vela 3 utterance_status，前轮CPU | 7 (14.6%) | 0.205 | 40 | 1 | 0 | 290 / 332 |
| Vela 3.1 utterance_status，前轮CPU | 7 (14.6%) | 0.205 | 40 | 1 | 0 | 585 / 991 |
| D3 utterance_status，11-16历史 | 29 (60.4%) | 0.658 | 3 | 2 | 13 | 不作本轮速度比较 |

Laya两模板对24条完整表达的enqueue命中均为0。utterance_status虽然继续聆听召回15/16，但把20/24完整表达误判为继续聆听，不能视为可替换方案。两条件共108条（含各6条另计诊断）无执行错误；token、instruction、option预检无截断。病例此前已多次使用，属于冻结回归集而非新留出集。

不同GPU/CPU、不同时间段及磁盘/内存压力下的时延不可作同计算单元性能排名。数据：[逐条四分类](../measurements/decision-laya-four-2026-11-18.json)、[201条参考对齐](../measurements/decision-laya-parity-2026-11-18.json)、[加载失败](../measurements/decision-laya-load-failures-2026-11-18.json)。二分类、最终工程检查另见[二分类报告](Decision-Binary-Interrupt-Mac-Comparison.md#laya-multilingual-coreai-固定矩阵2026-11-18)。

本次工程收尾见[二分类报告Laya工程验证](Decision-Binary-Interrupt-Mac-Comparison.md#laya-工程验证)：5个iOS构建通过，完整检查有既有失败及中断阶段，未做Laya手机验收。


## 用户精简意图模板（2026-11-18）

按用户提出的结构，state改为“以下是当前正在进行的对话”+用户/助手原文，再给“以下是用户发送的最新消息”；问题和候选通过各模型原生协议传入，不添加长定义。没有当前对话时明确写“（无）”；二分类只使用当前轮h0，不放更早历史、busy或queue。英文本地化对应结构。三模型业务内容相同，原生token/特殊标记并不相同。

四分类问题为“请问用户的意图是什么？”，候选按用户顺序“打断／未说完／无意义消息／等待”；英文为“What is the user's intent?”与“Interrupt / Unfinished / Meaningless message / Wait”。二分类中文问题为“请问用户的意图是否表达打断？”，英文为“Does the user's intent express an interruption?”；分别测试noul和裸否/是（No/Yes）choice。D3 noul按固定官方formatter展开成No / false、Yes / true，再走既有原生code readout，原生chat/system包装未改。

仅实验，不修改App。四分类54例（48回归+6诊断），二分类单句196例和当前轮56例各跑两种type；每模型558次，三次预热/条件另计。所有输入在运行前冻结，不按结果调标签/阈值。四分类“等待”仅在评估映射原enqueue；旧case的同句分片维持原拼接，已有question_to_user原文作为assistant问题，不虚构对话。二分类依旧评估即时打断信号，延后/条件停止为false；新问题省略了“立即”，该语义边界可能影响结果，不事后改标签。旧实验是回归参照；结构、提示长度、语言和类别文字/顺序同时改变，不能分离各因素的因果贡献。

Laya沿用GPU debug-enabled路径，Vela3.1沿用CPU，D3为Swift自动计算路径。期间观察到构建产物被清理，空闲磁盘由不足1GiB升至约64GiB；D3入口必须重建。模型间不作同计算单元的公平速度排名，端到端耗时仅描述实测。模型制品及既有适配器不换版本，Vela SDK源码与上一轮已验证版本一致。

### 四分类结果

| 模型 | 正确/48 | macro-F1 | 误丢弃 | 误打断 | 未说完命中/16 | 等待命中/24 | P50/P95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Laya | 18 (37.5%) | 0.382 | 14 | 4 | 9 | 4 | 151 / 162 |
| Vela 3.1 | 8 (16.7%) | 0.204 | 31 | 4 | 1 | 3 | 137 / 186 |
| D3 Edge | 10 (20.8%) | 0.287 | 30 | 3 | 2 | 1 | 227 / 238 |

旧固定minimal / utterance_status模板的Laya成绩为6/48、17/48，Vela3.1为14/48、7/48；D3历史utterance_status为29/48。新模板对Laya宏F1有所提升，但正确数仅略高于其旧utterance_status；Vela3.1和D3仍有大量误丢弃，没有形成可直接替换的四分类方案。旧留出已反复观察，本轮称回归集。

| 模型 | 中文正确/24 | 英文正确/24 | 诊断正确/6 |
| --- | ---: | ---: | ---: |
| Laya | 7 | 11 | 1 |
| Vela 3.1 | 2 | 6 | 0 |
| D3 Edge | 5 | 5 | 0 |

证据：[新四分类完整输入](../measurements/decision-concise-intent-shared-four-input-2026-11-18.json)、[三模型汇总](../measurements/decision-concise-intent-summary-2026-11-18.json)。二分类和工程验证见[同轮二分类报告](Decision-Binary-Interrupt-Mac-Comparison.md#用户精简意图模板2026-11-18)。没有改App。


## Laya精简提示词补充定义（2026-11-18）

仅实验，App未修改。沿用上一轮的全部case、上下文、候选文字/顺序、标签和>0.5阈值，仅变更instructions。中英文提示词分别编写；单句无当前对话，current仅当前用户请求、assistant已输出内容及最新输入，没有更早历史、busy或queue。558条正式请求全部完成、零错误，输入预检均完整无截断；Laya仍用同一GPU debug-enabled制品和适配器。三次预热/条件不计入时延。旧版时延来自上一轮，非同时交错运行，不能将波动归因于提示词长度。

### 完整问题与定义

```text
请问用户的意图是什么？
打断：要求立即停止或改变当前正在进行的回复；仅追加问题、补充信息或要求稍后处理不算打断。
未说完：话语尚未完整，需要更多内容才能理解意图。
无意义消息：没有可理解的交流含义。
等待：有完整意义、可正常入队处理且不要求立即打断的消息，并非指用户说了“等一下”。
```

```text
What is the user's intent?
Interrupt: Ask to immediately stop or change the response currently in progress; merely adding a question, providing more information, or requesting something for later does not count.
Unfinished: The utterance is incomplete and needs more words before its intent can be understood.
Meaningless message: The message has no understandable communicative meaning.
Wait: A complete, meaningful message that can enter the normal queue without an immediate interruption; this does not mean the user said "wait a moment".
```

候选仍为打断/未说完/无意义消息/等待及对应英文，不把定义塞入候选标签。等待仅在评分时映射enqueue。

| 指标（48条回归例） | 旧版 | 补定义 |
| --- | ---: | ---: |
| 正确数 | 18.000 | 17.000 |
| macro-F1 | 0.382 | 0.355 |
| 误丢弃 | 14.000 | 6.000 |
| 误打断 | 4.000 | 4.000 |
| 未说完识别数/16 | 9.000 | 5.000 |
| P50 ms | 151.211 | 144.655 |
| P95 ms | 161.546 | 148.397 |

误丢弃由14降至6，但未说完识别从9/16降到5/16，正确总数18降到17；没有整体提升。6条诊断case另列于汇总，不能并入48条主评分。


原始输入、输出及逐例配对见[汇总](../measurements/decision-defined-intent-summary-2026-11-18.json)，输入及模型结果使用同目录decision-defined-intent前缀，未覆盖旧数据。脚本见[defined_intent_experiment.py](../../Tests/DecisionBenchmarks/defined_intent_experiment.py)。本轮仍为反复使用的回归案例，不是新holdout，未做真机验证，也未据结果调整阈值或覆盖模型输出。
