# D3 Edge Core AI 转换与全双工文本测试

日期：2026-11-10（Asia/Shanghai）。本记录是本机真实模型执行证据，不是 MobileHarness Provider 接入或 iPhone 验收。

## 范围与制品

- 上游：vllm-sr/d3-edge，固定 revision `bee5e872f75b9c5d1405767bf244a6948b95c0af`。
- 转换参考：maxffarrell/d3-edge-CoreAI，固定 revision `ffa8431fe8dd5209f3ec2c8bf59afc829ec96c31`；保留 Apache-2.0 许可及署名。
- 工作目录：`/Users/devil/Pro/d3-edge-coreai`，已获用户批准；原始权重、环境和缓存均留在仓库外。
- 实际制品：文本专用 `decision.aimodel`，约 945 MiB；BF16 文本骨干、FP32 255 项 readout，完整输入最多 512 token，batch=1。非因果 full attention 和因果 DeltaNet 均保留。没有训练或量化。
- 用户明确的业务：对语音识别文本作 interrupt / discard / enqueue 决策。视觉模型及媒体输入已从交付范围移除，运行时明确拒绝媒体。
- ModelKit Swift 接口与应用装配未改动；业务提示词、阈值、ASR、播报取消和队列控制未接入生产。

## 环境

Apple M5、16 GiB 内存、macOS 27.2、Xcode 27.0、Python 3.13.13；coreai-core 1.0.0b3、coreai-torch 0.4.3、PyTorch 2.14.0、Transformers 5.17.0。转换工具提示其验证范围为 PyTorch <=2.13；本次按实测版本保留警告，未将其描述为官方组合认证。

PyTorch 对照在 CPU 上运行，DeltaNet 使用原项目的 PyTorch 参考实现。Core AI 使用默认 specialization，未验证 CPU/GPU/ANE 实际分配。没有真机 iPhone、实时麦克风或原生播报闭环测试。

## 转换保真

| 对照集 | 选择一致 | 最大概率绝对差 |
| --- | --- | --- |
| 27 个通用文本 + 48 个原始长提示词业务样例 | 75/75 | 0.0188751 |
| 48 个中文简短提示词业务样例 | 48/48 | 0.0230880 |
| 48 个英文简短提示词业务样例 | 47/48 | 0.0135900 |

合计 171 次提示词/场景对照，复用了相同业务场景，不是 171 个独立样例。英文短提示词中 `duplex_idle_05` 发生接近平票的翻转：助手询问“是否删除草稿？”，用户回答“不要”，原模型选择 enqueue，Core AI 选择 discard。原概率约为 `[0.0685, 0.4646, 0.4669]`，转换后约为 `[0.0717, 0.4680, 0.4603]`，顺序为 interrupt/discard/enqueue。严格数值等价未通过，不能声称所有输入决策一致。

Swift 独立程序使用系统 Core AI 的 AIModel / InferenceFunction 加载同一无状态图成功；合成预分词样例与 Python Core AI 的最大概率差约 `5.96e-8`。初次 Swift 编译使用了错误的 Outputs 下标接口，改为公开 remove/ndArray 接口后编译与运行通过；不影响模型权重。

## 业务效果

48 个合成中文场景在测试前固定预期标签。输入包括助手播报状态、最近一句助手内容、最终语音转写及明确提供的来源标记。涵盖停止、取消、纠错、紧急切换、附和、否定、排队请求、空闲问答、简短回答、上下文对照以及已知回声/噪声。

| 提示词 | Core AI 正确 | 原模型正确 | 误打断 | 误丢弃有效输入 | 漏打断 |
| --- | --- | --- | --- | --- | --- |
| 中文长规则 + JSON 状态 | 24/48 | 24/48 | 0 | 16 | 9 |
| 中文短规则 + 自然文本状态 | 34/48 | 34/48 | 11 | 3 | 0 |
| 英文短规则 + 自然文本状态 | 35/48 | 36/48 | 1 | 4 | 6 |

误打断是对预期 discard/enqueue 输入输出 interrupt；误丢弃是对预期 interrupt/enqueue 输入输出 discard；漏打断是预期 interrupt 却选择其他类型。后两者可能重叠。

最佳 35/48（72.9%）仍不足以作为全双工对话的唯一控制依据。两个简短提示词是在看过首轮结果后开发，使用相同冻结标签做探索，不能当作独立保留集准确率。未选定生产默认提示词。回声和非语音来源由测试提供，不是模型从音频检测得到；未测试部分转写、端点检测或真实 ASR 错误分布。

## 运行和性能

- 纯制品离线加载/推理通过，不读取原模型权重。
- 原生 512-token 输入输出有限值；513-token 输入在推理前拒绝。超长文本不截断。
- 媒体、空候选、未知问题类型、非法评分等级和 busy 接纳均明确拒绝。多问题类型化结果通过；五次同输入重复概率一致。
- 首次加载含 specialization 58.81 秒，原始验证进程峰值 RSS 6.13 GiB（包含编译和 Python 依赖）。
- 缓存加载独立复测 2.20 秒；20 次端到端热调用中位数 55.5 ms、p95 57.6 ms；结束时 RSS 1.32 GiB，该进程峰值 2.08 GiB。
- 与 CPU 对照并行时，同一烟测中位数 115.4 ms、p95 405.6 ms，存在约 1.70 秒离群值。保留这份受负载影响的记录，不能承诺硬实时延迟。
- 以上端到端只包含文本 tokenization、Core AI 和结果整理，不包含 ASR、音频播放取消、排队执行或网络。

## 证据与发布

外部工作区 evidence 保存原始日志、JSON 对照、环境和发布回执；bundle 包含可复现脚本、冻结样例、失败样例、Swift fixture、许可与 SHA256SUMS。最终整理后的 75 个 fixture 均逐 token、逐标签与实际运行数据核对一致。

已公开发布到 [hugging-mac/d3-edge-CoreAI](https://huggingface.co/hugging-mac/d3-edge-CoreAI)，revision `0690c04ee1640c1c3fa11a882323751dda6d086a`。上传使用显式 41 文件清单，排除凭据、缓存、用户媒体、设备标识和原模型权重副本；仓库先私有暂存，41 个远端文件大小、可用 LFS hash 和下载的 SHA256SUMS 均验证通过后公开。发布回执为外部工作区 `evidence/publication.json`。

范围与实施计划已[归档](../completed/D3-Edge-CoreAI-Conversion.md)。发布完成不意味着全双工业务准确率或 iPhone 能力验收通过。

本应用仓库只增加文档：验证文档路径、链接与 diff 格式；没有运行应用 scripts/check.sh 或 build-ios.sh，不把模型和独立 Swift 检查称作应用构建通过。
