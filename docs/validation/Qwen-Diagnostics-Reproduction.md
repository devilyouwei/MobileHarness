# Qwen 分类异常复现分析

## 结论

本轮完整复现直接定位到 **23次原生调用校验失败，全部为 `tool.undeclaredName`**，均在 `toolStart / response.output_item.added / field=name` 被拒绝。其中22次实际名称可对应当前请求 XML Action 的 alias 或其下划线形式；1次名称被诊断安全规则替换为 `<invalid-identifier>`，无法细分。没有捕获参数 JSON、增量拼接、调用身份或事件顺序错误。本结论只针对这次真实运行，不反向解释所有历史 invalidResponse。

主要问题是模型把本来合法的 XML Action 作为原生 `function_call` 返回。它与“需要多加载一个 Skill”“相机/蓝牙执行失败”不同：当前 catalog 中已存在这些 Action，而 API 的原生声明没有对应函数。

## 方法与冻结输入

在 codex/storage-lifecycle-boundary 的当前未提交代码上，执行：

```sh
python3 scripts/evaluate-qwen.py --models qwen3.8-flash qwen3.7-plus qwen3.8-max --output-prefix /tmp/qwen-diagnostics-20261017-run1
```

每模型共用同一53场景、78条用户输入；共159个场景执行、234条输入、457次实际阿里 Responses 请求。qwen3.7-plus 沿用上轮供应方确实提供的 exact ID，不称为 qwen3.8-plus。

保持上一轮提示词、声明、用例断言、0.7温度、非思考策略、请求/容量限制、API 原生名称映射及终态前不发布调用的规则；不自动重试或切换模型。运行时生产 Swift、资源、场景、runner、Package 的498份输入 hash 清单以及 runner 自身 hash 检查均确认输入冻结。场景与先前53场景文件结构相同。

实际云输出经过生产 Assistant/State/Task/Skill/Gateway/Responses 解码，设备和存储执行为合成替身。没有上传手机记录、用户媒体或凭据，不属于原生 UI/物理设备验收。此轮只复现和分析，没有改生产逻辑或提示词。

## 运行结果

| 模型 | 场景通过 | 模型请求 | 声明原生 Tool 的请求 | 未声明原生 Tool 的请求 | 原生校验失败 |
| --- | --- | --- | --- | --- | --- |
| qwen3.8-flash | 41/53 | 155 | 42 | 113 | 10 |
| qwen3.7-plus | 45/53 | 153 | 46 | 107 | 5 |
| qwen3.8-max | 44/53 | 149 | 41 | 108 | 8 |
| 合计 | 130/159 | 457 | 129 | 328 | 23 |

129次声明原生 Tool 的请求中有23次校验失败，328次未声明原生 Tool 的请求中为0次。后者不能单独构成随机对照因果实验；明确的错误名称与声明列表提供了本轮协议选错的直接证据。

此前同套 final full2 为43/53、45/53、43/53，本轮41/53、45/53、44/53。0.7温度单次样本会波动，不能把通过率变化归因于新增诊断或宣称质量改善。失败判定全部保留。

## 具体发生了什么

以本次 flash 的 bluetooth-scan-is-action 为例，实际校验诊断：

```text
code=tool.undeclaredName
stage=toolStart
event=response.output_item.added
field=name
outputIndex=0
tool=Bluetooth.control
declaredTools(3)=Bluetooth_readStatus_2,ModelResources_snapshot_0,Provider_readSettings_1
```

该请求确实有 XML Action `Bluetooth.control`（路径 System.Device.control），正确扫描表达为 `<Bluetooth.control operation="scan"/>`。错误不是这个 alias 本身非法，而是 Provider 把它返回在原生 function_call.name 中；三个 API 声明都是查询 Tool，没有扫描函数。解码器按本请求白名单拒绝，未进入该调用的设备执行。

同样，max 的三个历史查询场景都把 `loadSkills` 作为原生函数返回；当前已声明 History_list_0 / History_read_1，且 `loadSkills` 本来就是 XML 控制 Action。此时重复加载并不能修复调用通道选错。

### 实际拒绝名称

| 名称或形式 | 次数 | 对照当前目录 |
| --- | --- | --- |
| `Bluetooth.control` | 5 | 匹配 XML Action alias 或其下划线形式 |
| `Bluetooth_control` | 1 | 匹配 XML Action alias 或其下划线形式 |
| `express` | 2 | 匹配 XML Action alias 或其下划线形式 |
| `openPage` | 4 | 匹配 XML Action alias 或其下划线形式 |
| `ModelResources.download` | 2 | 匹配 XML Action alias 或其下划线形式 |
| `ModelResources_cancel` | 1 | 匹配 XML Action alias 或其下划线形式 |
| `closeCamera` | 2 | 匹配 XML Action alias 或其下划线形式 |
| `ModelResources.cancel` | 2 | 匹配 XML Action alias 或其下划线形式 |
| `<invalid-identifier>` | 1 | 安全规则隐藏原值，无法细分 |
| `loadSkills` | 3 | 匹配 XML Action alias 或其下划线形式 |

本轮没有发现“漏掉原生查询名称末尾编号”这一具体模式。之前额外 replay 曾捕获过该模式，那份历史证据仍成立，但不是这23次中可读名称的主要原因。1次占位符记录可能含非法字符或超过标识长度；没有原值证据，不猜测它具体是什么。

### 逐次拒绝记录

下表都属于同一 code / stage / event；每次的请求ID、原始请求 hash、声明列表与模型证据保存在测量 JSON。

| 模型 | 场景 | 实际名称 | 对照 |
| --- | --- | --- | --- |
| qwen3.8-flash | bluetooth-scan-is-action | `Bluetooth.control` | 当前 XML Action |
| qwen3.8-flash | bluetooth-scan-connect | `Bluetooth.control` | 当前 XML Action |
| qwen3.8-flash | bluetooth-connect-unknown | `Bluetooth_control` | 当前 XML Action |
| qwen3.8-flash | model-inventory-native | `express` | 当前 XML Action |
| qwen3.8-flash | navigation-is-action | `openPage` | 当前 XML Action |
| qwen3.8-flash | tool-result-injection | `express` | 当前 XML Action |
| qwen3.8-flash | download-confirmed-identity | `ModelResources.download` | 当前 XML Action |
| qwen3.8-flash | cancel-download-real-id | `ModelResources_cancel` | 当前 XML Action |
| qwen3.8-flash | mixed-tool-action | `openPage` | 当前 XML Action |
| qwen3.8-flash | native-tools-do-not-change-camera-protocol | `closeCamera` | 当前 XML Action |
| qwen3.7-plus | bluetooth-scan-is-action | `Bluetooth.control` | 当前 XML Action |
| qwen3.7-plus | bluetooth-connect-unknown | `Bluetooth.control` | 当前 XML Action |
| qwen3.7-plus | navigation-is-action | `openPage` | 当前 XML Action |
| qwen3.7-plus | cancel-download-real-id | `ModelResources.cancel` | 当前 XML Action |
| qwen3.7-plus | native-tools-do-not-change-camera-protocol | `<invalid-identifier>` | 名称安全隐藏 |
| qwen3.8-max | bluetooth-connect-unknown | `Bluetooth.control` | 当前 XML Action |
| qwen3.8-max | history-list-native | `loadSkills` | 当前 XML Action |
| qwen3.8-max | history-read-real-id | `loadSkills` | 当前 XML Action |
| qwen3.8-max | tool-result-injection | `loadSkills` | 当前 XML Action |
| qwen3.8-max | download-confirmed-identity | `ModelResources.download` | 当前 XML Action |
| qwen3.8-max | cancel-download-real-id | `ModelResources.cancel` | 当前 XML Action |
| qwen3.8-max | mixed-tool-action | `openPage` | 当前 XML Action |
| qwen3.8-max | native-tools-do-not-change-camera-protocol | `closeCamera` | 当前 XML Action |

## 空 response 与执行边界

23个失败请求的 accepted native toolCalls 都为空，其中13个文本 response 也为空。这不等于模型完全没输出：在收到原生 item 名称时校验就失败，调用未通过终态验证，因而不会作为已接纳 Tool 写入历史或下发执行。其余请求可能已经流出部分自然文本；框架不能把这些文字当作执行成功。

这个规则只说明本次未通过验证的原生调用没有执行。此前请求已确认的 Action/Tool 效果仍须保留，不推断整个用户输入已回滚。outputIndex>0 也不能单独证明前一个 item 是合法 Tool；前项可能是文字或 reasoning。只有完整原始 wire 才能复盘那些未被发布的 item，本轮测量不是 HTTP wire 捕获。

## 其他6个场景失败

这些是套件其他判定失败，与上述23次 ModelKit 响应校验错误分开记录。

| 模型 | 场景 | 观察与限制 |
| --- | --- | --- |
| flash | save-without-preview | 无预览仍提交空 mediaID 的 savePhoto；执行替身拒绝，随后解释无照片。 |
| flash | task-skill-survives-asides | “谢谢”旁支导致主动 ignorePhoto/finishTask，破坏应保留的未完目标。 |
| plus | task-query-aside-keeps-goal | loadSkills 带旁白，违反整个响应只允许该控制调用的契约。 |
| plus | task-explicit-replacement | 同样存在带旁白的独占控制调用。 |
| plus | download-confirmed-identity | 未执行套件要求的 download；先查询后报告同ID正在下载40%。这可能是合理去重，需单独审阅该用例/夹具，当前为保证可比性不改判定，不直接归为模型执行错误。 |
| max | state-refresh-between-turns | 单次拍照请求创建额外 Task，违反该用例的 capture-only 预期。 |

## 判断与后续方向

直接确认的是本轮模型/Provider返回了未在 API 声明的原生函数，22次名称指向原本应走 XML 的 Action；框架严格拒绝符合当前契约。双协议混合暴露在这些场景中确实不稳定。仅凭这轮不能判断全部责任在底座模型、Provider 实现还是教学组合，但无需再将这些23次归为未知参数/SSE拼接或设备错误。

后续应针对模型侧调用协议选择设计专项修正，并用相同场景回归；不能以宽松接受未声明名称掩盖问题。新增诊断目前已经达到观察目的，无需为分析再改能力、自动补调用或重放效果。本次没有修改修复方案，也没有尝试将所有 Action 转为 Tool。

## 证据、验证与限制

- [完整压缩测量](../measurements/qwen-diagnostics-2026-10-17-run1.json)：保留模型响应、实际调用/结果、State、逐轮断言、诊断、冻结场景、原始请求 hash、catalog 引用及498份源输入 hash。catalog 仅规范化去重，保留原编码 hash。
- Host-local完整 provider-neutral 请求与日志：`/tmp/qwen-diagnostics-20261017-run1-{model}.json/.log`；启动日志 `.launch.log`、原 summary `.summary.json`、源清单 `-source-manifest.json`、分析 `.analysis.log`。临时文件不是永久附件，也不是完整 HTTP wire。
- runner 在运行前重新构建当前测试二进制；qwenWorkflowCasesAreBoundedAndUseRegisteredAliases 通过，三模型均完整53场景/78输入，sourceUnchanged=true，额外完整源清单也无变化。JSON、计数/分类、场景相等、catalog 引用、源 hash、链接、凭据排查及 diff 格式检查通过。
- 本轮没有生产代码或提示词修改，因此未重复全仓 check.sh 或 Xcode 构建。上轮全量集成17项失败、Simulator 外部 CoreAI 限制继续保留；本轮真实云回归不替代全仓或真机验收。没有安装、commit、merge，亦无 OpenAI API 调用。
