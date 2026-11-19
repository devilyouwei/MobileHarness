# 纯 Python 实验验证

2026-11-19。

## 实现与范围

- experiments 不再有 Swift/Shell 源码或 SwiftPM 清单。根 Package 排除整个目录，移除仅用于实验的 AgentModelEvaluationTests target；Xcode仅展示Python、数据、配置和文档。
- Assistant：直接模型调用、独立提示词、合成动作反馈与评分；Writer：Python合成工作区工具、内容/命令评分及可选浏览器评审；Decision：Python choice/noul/多问题/生成模型输入；Vision：Core ML Python图片推理。
- Core AI解码使用逐token调用和每请求独立状态，可配置静态输入（Gemma PLE）；Apple系统模型使用官方Python SDK，云端使用显式配置的HTTP接口。不编译或启动App。
- 原Swift实验里被工程测试依赖的单流程机制移入Tests/Agents/Assistant/AssistantCommunicationFixture.swift与Tests/Agents/Writer/WriterCommunicationFixture.swift，删除多case真实模型入口。原Decision评估器的纯解析/指标回归改由Python工具测试负责。
- 新Assistant/Writer提示/合成协议独立于App；旧Swift/App的运行时间、成功率和原生UI证据不能当作新Python路径的测量。窗口/取消反馈为合成状态；Chromium评审不是App WebKit验收。
- 213份冻结Datasets/Results JSON/CSV逐文件SHA-256保持不变；变更的是运行器和任务配置。历史证据中的旧路径、哈希和失败保留。

## 已执行检查

- 新主要入口help不加载模型，通过；Python语法、纯Python目录边界、活动链接与diff格式检查通过。
- 最终Python离线回归29项通过，涵盖case读取、严格标签、评分、合成工作区路径/替换、标准答案不进入请求、原始错误回答保留、探针分母、超时与结果不覆盖。
- `./scripts/check.sh`退出0：Swift Testing各目标合计2086项通过（含IntegrationTests 1184、AppWorkflowTests 198、串行LiveRuntimeTests 231），Python回归29项及格式/资源/工程配置检查通过。
- `./scripts/build-ios.sh`退出0：MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero、ModelKitAppleLLM五个scheme全部构建成功。最后的tokenizer兼容修正仅影响Python；随后重跑29项Python检查及真实D3 case通过。

## 原生依赖验证范围

已有Python环境包含Core AI、Core ML、NumPy、Transformers与Hugging Mac SDK。缺少Apple Foundation Models Python SDK和Playwright，且Models下没有Gemma制品：对应真实推理/浏览器路径未实测，不能标记通过。无云端凭据读取或收费请求。D3、Vela 3、Vela 3.1、Laya各一个布尔case完成推理且标签匹配；limit=1、warmup=0，使用已有制品，无下载。这只是运行路径验证，不是准确率/性能评估。Vision尚未执行真实Core ML图片case。

接口核对：[Core AI Python](https://apple.github.io/coreai-torch/main/coreai-core/)、[Core ML预测](https://apple.github.io/coremltools/docs-guides/source/model-prediction.html)、[Apple Foundation Models Python](https://apple.github.io/python-apple-fm-sdk/basic_usage.html)。本地Core AI运行时接口及已发布制品Python适配器亦用于核对调用契约。

## 本地原始结果

输入为 `experiments/decision/datasets/binary-native-cases.json` 的首个case；Python为本地hugging-mac虚拟环境，设置USE_OS_COREAI=1、OMP_NUM_THREADS=1、MKL_NUM_THREADS=1，运行evaluate_decision.py --model <模型> --limit 1 --warmup 0。

- [D3初次失败](../../experiments/decision/results/decision-python-smoke-2026-11-19.json)：Transformers 5模板默认返回BatchEncoding，旧代码按token列表处理导致TypeError。
- [D3修正后](../../experiments/decision/results/decision-python-smoke-2026-11-19.json)、[Vela 3](../../experiments/decision/results/decision-python-smoke-2026-11-19.json)、[Vela 3.1](../../experiments/decision/results/decision-python-smoke-2026-11-19.json)、[Laya](../../experiments/decision/results/decision-python-smoke-2026-11-19.json)：各1/1通过、0运行错误。D3和通用Core AI入口改为先渲染模板，再encode为token列表。

完整检查日志位于本机 `/tmp/mh-python-experiments-check.log`，iOS构建日志位于 `/tmp/mh-python-experiments-ios.log`；它们是临时本地证据，不作为仓库数据源。
