# Qwen 调用协议对照

## 结论

**Responses 返回格式没有“原生 Tool 与 XML 文本不能在同一响应共存”的硬性限制；但本次业务调用对照中，统一模型侧表达明显更稳定。**

两个模型都实际返回过同一 response.output 内的 `<closeCamera/>` 文本和合法 Provider_readSettings_1 原生调用。该补充探针将 XML 明确设为惰性文字，证明的是表示/接口能力，不是假装完成相机执行。生产框架的现有混合轮次测试也通过。另一方面，要求模型自己根据业务目录选择两种协议时，混合组明显较差；只加“每轮禁止混用”对 flash 仍不足。

本轮不修改生产注册、提示词、Agent 调度或设备执行。它不是将全部 Action 改为 Tool 的产品验收。

## 三个不同问题

1. **同一请求提供两类能力**：目前会同时提供 API-native query Tools 和 system 中的 XML effect catalog。这里有两个选择入口，即使某次只需一个 Action，flash 也可能发成 undeclared native。
2. **同一响应出现两种表示**：接口能够同时返回 message.output_text 和 function_call；XML 可以作为文本存在。不能把第1项的选择错误等同于格式硬性互斥。
3. **跨请求先后执行**：有结果依赖时，无论调用协议是否统一，都要等真实反馈后再决定下一步。本实验扫描→读取、读取→打开均要求跨请求；独立操作才允许同响应。

## 对照设计

仅使用 qwen3.8-flash 和 qwen3.8-max，保持0.7温度、reasoning.effort=none、enable_thinking=false、stream=true/store=false、strict=false、原生 tool_choice=auto；输出 token 上限不主动设置。使用之前授权的阿里 ENV，不访问 OpenAI。

用相同7项函数语义和参数约束：模型资源查询、Provider查询、蓝牙状态查询、历史查询、关闭摄像头、打开页面、蓝牙扫描。每条件独立会话、重复3次，协议组顺序按场景/重复轮转，避免固定先后。使用最小教学移除生产 Task/Skill/State 规则以隔离协议选择；不会将生产长提示词和这个短提示词的通过率直接比较。

| 组 | 模型侧表达 |
| --- | --- |
| xml-only | 所有函数以 XML 表达，包括查询；不发送 API tools。 |
| native-only | 所有函数通过 API 原生函数表达，包括原业务 Action。 |
| mixed | 查询仅原生 Tool，操作仅 XML；可共用响应。 |
| mixed-exclusive | 与 mixed 相同声明，但额外要求每个响应只用一种协议，另一种留到反馈后的请求。 |

这里的“全XML/全原生”只改变实验表达，内部查询/操作的语义标签仍保留。替身直接返回合成结果，没有通过生产 Agent/Gateway 执行这些重新分类的入口。

五项公平可比场景：关闭相机、打开历史页、查询模型、扫描成功后查询蓝牙、读取模型后打开设置。每组每模型5×3=15次。

另有第六项：明确要求同一响应查询模型并关闭相机，两步独立。该要求与 mixed-exclusive 直接矛盾，所以 exclusive 组不参与，不能将其缺席算通过或失败。

主实验共138个场景执行、170次实际请求。每trial最多6请求、每模型最多180请求；90秒HTTP读取超时并在接收行时检查90秒响应期限，单行64KiB、总流8MiB。只保留终态公开 output/usage，私有 reasoning 丢弃；没有自动重试。直接 HTTP 探针没有复用生产 SSE 解码器，不能以此宣称完整生产协议兼容。未遇到HTTP/传输失败。

## 公平场景结果

| 模型 | 全 XML | 全原生 Tool | 混合 | 混合、每响应只准一种 |
| --- | --- | --- | --- | --- |
| qwen3.8-flash | 15/15 | 15/15 | 4/15 | 5/15 |
| qwen3.8-max | 13/15 | 15/15 | 9/15 | 14/15 |

- flash 的混合失败主要是将 closeCamera/openPage/Bluetooth.control 作为未声明原生调用，或缩短 Provider_readSettings_1 的名称。exclusive 指令仍会出现相同误选，说明仅靠一句“不要混用”无法保证入口选择。
- max 的 mixed 失败主要为 Bluetooth.control/openPage 被发成原生函数；exclusive 组仅剩一次扫描参数键错误。
- max 的全XML两次失败分别是无效 XML `<alias key="scan" Bluetooth.control/>`，以及请求读 Provider 却调用资源查询。它们不是“XML协议不支持”的证据。
- 全原生两模型本次均15/15，只证明这组小型合成函数/短教学的表现；不能外推为 Task/Skill、Channel/wait、资源锁、取消、部分成功或真机已验收。

## 同一响应的独立双操作

| 模型 | 全XML，两调用同响应 | 全原生，两调用同响应 | mixed，两协议同响应 |
| --- | --- | --- | --- |
| qwen3.8-flash | 3/3 | 3/3 | 0/3 |
| qwen3.8-max | 3/3 | 3/3 | 0/3 |

flash mixed 主要发出未声明的 closeCamera/closeCamera/ 或错误原生查询名；max mixed 只完成了其中一种调用。主业务实验没有观测到合法双协议共同输出，不能凭这个有限负样本宣布接口禁止；因此补充下述表示能力探针。

## 补充：惰性标记文字 + 原生调用

对每模型重复3次，要求先输出指定普通文字标记，再在同一响应调用唯一声明的 Provider_readSettings_1。三种标记是 PROBE_OK、`<probe_marker/>`、`<closeCamera/>`；后两种都明确只是文字，不是函数/设备操作。合计18次额外实际请求，和主实验分开记录。

| 模型 | 普通文字＋native | 任意XML文字＋native | Action形状XML文字＋native |
| --- | --- | --- | --- |
| qwen3.8-flash | 2/3 | 3/3 | 3/3 |
| qwen3.8-max | 3/3 | 3/3 | 3/3 |

flash 唯一失败只输出 PROBE_OK，没有调用函数。XML标记两类均在两个模型3/3成功，没有被服务硬性排斥。两模型的 Action形状标记首轮实际公开响应都包含：

```text
output[0].type = message
output[0].content[0].text = "<closeCamera/>\n\n"
output[1].type = function_call
output[1].name = Provider_readSettings_1
output[1].arguments = "{}"
```

这可以否定“两个输出类型在接口上绝不能共存”，不能冒充云模型已经正确完成语义上的关闭相机。没有执行该标记对应的任何操作。

## 工程含义

可以优先考虑**统一模型侧调用表达**，内部继续区分有副作用的 Action、查询 Tool 以及各自的权限、Channel、等待、资源和完成契约。全原生表达值得进入完整生产工作流的下一阶段原型验证；本轮尚未做这项迁移。

另一种方向是真正分阶段暴露能力：某轮只提供一个入口类型。它不同于在同一个 mixed 请求里加“这次不要混用”的文字。本实验 exclusive 只测试后者，没有实现/验证新的规划器或动态入口选择。

总体判断是当前混合教学/接口组合下的模型选择稳定性，而非格式硬限制。诊断只能看到 Provider 的公开输出，无法区分模型内部采样选择和供应方后处理的全部责任。3次重复不足以形成通用可靠率结论，也不证明通过率只由协议这一变量决定；表示方式、schema暴露和教学长度随协议组必要变化。

## 验证与证据

- [完整测量与请求/公开响应](../measurements/qwen-protocol-comparison-2026-10-17.json)：包括主实验138个trial、170请求，18个标记探针、原始判定、函数/schema、输入、原生名、反馈配对、源hash和补充探针源码。主脚本运行期间 hash 不变；旧生产53场景报告没有重写。
- 新 Python 离线5项测试通过，覆盖声明分区、合法同响应混合、错误通道/名称/参数、依赖分轮及原始 call_id 配对。没有网络测试被加入常规 check。
- 现有生产框架 generationRoundActualOutputControlsContinuationForAllThreeRoutes 的6种 action/tool/mixed×value 情况，以及 generationRoundToolBypassesWaitButContinuationJoinsEveryAction 均通过；原生参数计时相关用例也通过。这些是生产 Agent/Gateway 加确定性模型/执行替身，支持框架混合能力，不是云业务混合成功。
- ./scripts/check.sh：边界/资源、6项既有Python、严格格式和编译通过；OpenAI42/UI67/AppWorkflow118通过。Integration909仍有8项失败/15个issues，全量不通过。这轮只增加Python实验/测试与文档，未修改生产Swift，未修复这些时序路径。
- ./scripts/build-ios.sh：首个Simulator scheme仍在外部CoreAIShared无法解析CoreAI处失败，后续scheme未执行。没有新的设备目标构建、安装、原生UI或物理设备验收。JSON/计数/源hash/链接、凭据和diff检查通过。

全量失败：atomicStableOffTargetEndsBeforeOverallDeadlineAndKeepsError；soundSourceNonSpeechBroadcastDoesNotRequireSubscribersOrOpenASR；soundSourceMonoIsUnavailableAndRejectedPublicationDoesNotStopRecognition；soundSourceOnlyDiagnosticCrossesGatewaysWithoutModelsOrPresentationGrants；soundSourceStopCancelsAndJoinsAnInFlightPublisher；soundSourceBroadcastCrossesGatewaysWithBoundIdentityAndCaptureDeadline；soundSourceReplyGateClearsDirectionAndResumeStartsANewWindow；soundSourceSlowSubscriberDoesNotBlockFollowingDirections。未用本轮模型实验掩盖这些失败。

主机临时证据：/tmp/qwen-protocol-20261017-run1-{model}.json、.summary.json、.launch.log；/tmp/qwen-protocol-20261017-canary.json/.log、/tmp/qwen-protocol-canary.py；/tmp/qwen-protocol-framework.log、/tmp/qwen-protocol-check.log、/tmp/qwen-protocol-ios.log。不是永久附件或完整HTTP wire捕获。没有OpenAI API调用、用户手机记录/媒体上传、生产协议迁移、commit或merge。
