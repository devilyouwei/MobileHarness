# Writer 提示词双模型回归（2026-11-08）

最终自动矩阵两模型均为 **28/30**。可比基线为 Qwen 24/30、GPT 28/30（夹具修正单列）；本轮只优化 Writer 私有资源。两个运行时缺口仍失败，Qwen 另有一次自动断言未覆盖的日期补写。分数、事实忠实性、离线视觉与手机验收分开报告。

后续获授权的业务修复和新一轮模型结果另见 [Writer 执行内聚验证](Writer-Execution-Cohesion.md)；本报告保留修改前的失败、分数及范围，不反写为通过。

本报告仅评价 Writer 自有提示词，不评价 Assistant 的 task.start/task.delegate 路由。模型使用用户授权的 `.env.local` Provider URL/密钥，准确 ID 为 qwen3.8-max、gpt-6.1-sol。只运行这两种模型，thinking=minimum（沿生产 Writer 配置方向），输出 token 上限使用 Provider 默认值。单次样本结果不代表统计稳定性。

## 文件归属与复现

- 用例：[writer-workflows.json](../../Tests/AgentModelEvaluationTests/Scenarios/writer-workflows.json)，28 组、30 个独立子例；与 Assistant 的场景 JSON 同目录。
- 模型及预算：[writer-evaluation.json](../../Tests/AgentModelEvaluationTests/Scenarios/writer-evaluation.json)。
- 执行：[WriterModelEvaluationTests.swift](../../Tests/IntegrationTests/WriterModelEvaluationTests.swift)，沿用 Writer 原有真实模型执行入口，独立于 Assistant XML/Skill 替身评估器。
- 脚本：[evaluate-writer.py](../../scripts/evaluate-writer.py)；`python3 scripts/evaluate-writer.py --matrix --seconds 300 --output-prefix /tmp/writer-prompt-unique`。完整 Xcode 环境下构建后执行；子进程只接收对应 Provider 凭据，不输出凭据。
- 唯一生产行为调整：[Writer/Instructions.md](../../MobileHarness/Resources/Agents/Writer/Instructions.md)、[Writer/Prompts.json](../../MobileHarness/Resources/Agents/Writer/Prompts.json)。装配器仍按原入口加载，Assistant/BasicSkill/公共工具声明未因本轮实验修改。生产 Swift 未修改。
- Swift 变更事前在会话告知，限测试宿主、原职责断言和离线视觉工具。未创建源码目录。

## 证据范围

使用真实 Provider、Writer、Gateway、ArtifactService、SQLite、ArtifactPresentation、WindowState 与 macOS WebKit。每例独立数据库和文件。窗口动画完成回执由桌面测试宿主合成，不等于手机上窗口动画/触摸的实际验收。

矩阵未将 WKWebView 挂到原生 NSWindow，生产截图接口如实返回 unavailable；模型可用文本、DOM 和诊断，没有收到离线截图。`render-writer-review.swift` 单独挂载原生 WebKit，离线加载实际发布文件和关联资源供人工看图，不改变模型输入。Markdown 预览是当前产品支持的有限语法；存在 SVG 文件/引用不证明 Markdown 中的图片已展示。

证据 JSON 保存真实请求文本、工具参数/结果、生成文件、窗口事件和资源/二进制哈希，属于 Provider-neutral 轨迹，不声称完整 HTTP wire 捕获。完整 SQLite 与历史存储仍在各报告注明的本机临时输出；足以解释结论的请求和文件已持久化，不依赖临时目录继续存在。

## 校准与基线

[完整原始基线](../measurements/writer-prompt-2026-11-08-baseline.json)中 Qwen 22/30、GPT 26/30，阶段内 sourceUnchanged、binaryUnchanged 均为 true。

正式基线前：旧测试提交调用者 taskID 被当前 Writer 拒绝，校准最初没有真实模型请求；修正为 goal-only 请求。还修正 closing 过渡态误判及“下周启动试运行”被过严短语断言拒绝。校准失败没有被当作提示词收益。

正式基线后发现测试宿主未 bindCommunications，导致问题虽到达、续答却未入库接纳，取消也受影响。保持原提示词补接后，[两模型 B05/B06 复测](../measurements/writer-prompt-2026-11-08-baseline-binding.json)均正常完成追问/取消。B05 原字符串断言仍误判千位逗号金额；`12,000.00` 与 `12000` 等值，后续数值包含检查接受千位逗号，精确替换仍逐字节检查。原始报告不改写。比较时将这两个夹具修复单列，不把其改善归因于提示词。

## 基线问题与提示词对应调整

| 发现 | 归属、证据与调整 |
| --- | --- |
| Qwen C03、C07、B01 提前 finish | 文件已写但尚未 render，发布失败；相同失败调用被运行时缓存，后补 render 也未解除该失败屏障。把所有格式、单字替换的 render → finish 条件前置。没有教模型更换参数绕过失败屏障。 |
| Qwen P05 两个同名作品直接打开 | 明确多匹配先 ask，列表顺序不是选择依据。 |
| P04 查询旧作品后无法编辑目标 | open 只展示，工具无法重绑当前编辑工作区；请求未包含现有引用时原生接纳已经分配新任务。提示词要求先定位、核对绑定，禁止复制成新作品充数。目标修改仍不能靠提示词完成。 |
| B01 open 被禁止 | Qwen 的 open 发生在读取文档中的注入句之前；不是注入成功的证据。文档指令未导致 delete/remove。提示词明确已绑定编辑直接 read，不必 open。 |
| B02 说明不支持外部资源后 failed | 两模型没有读出界路径、下载或创建替代文件，说明正确；运行时把未建立作品也未做库操作的 finish 标为 writer.incomplete。继续保留端到端失败，不能通过提示词伪造成功。 |
| 报价单附加商业条款 | 原提示词下 Qwen B05 自行增加有效期 30 天。禁止虚构日期、参会人、金额、付款/有效期条件；不缺关键字段时不追问可选元数据。 |
| 提示词所有权 | Writer 不再介绍 Assistant 的职责，仅定义自身与宿主的 ask/finish 接口。跨格式内容规则留在 content.base，HTML 布局移入 content.web；Markdown、TXT、SVG 分别维护格式规则。 |

## 基线视觉复核

两个模型的 C04 流程图均显示开始、需求、开发、评审、发布、结束；通过分支指向发布，不通过回到开发。两份 C05 柱状图均为 10/25/15 万元，合计 50 万元，柱高比例正确、标签可读。Qwen 使用较多纵向留白，但未作为未请求的美化修改理由。

图像保存在 measurements 下 `writer-prompt-2026-11-08-baseline-{模型}-C04-flowchart.png` 与 `...-C05-data-chart.png`。这里只是四张离线桌面视口复核，不代表所有办公文档均经过视觉验收，也不等于模型已看图。

## 定向优化记录

首轮 [pilot1](../measurements/writer-prompt-2026-11-08-pilot1.json)针对八例，两模型各 6/8。Qwen 的纯文本、歧义选择、不可信文档编辑恢复正常；P04 仍错误新建，B02 在恢复时写了限制说明文件。第二轮将“恢复观察不能授权新建”和目标绑定核对前置，并明确省略空白商业条款。完整轨迹统计替代有界历史统计，修正长任务早期调用漏算；原报告保持原样。

## 完整对照结果

[最终完整结果](../measurements/writer-prompt-2026-11-08-full1.json)两模型均 28/30。sourceUnchanged、binaryUnchanged 均为 true；与基线相比，追踪范围中的生产文件只有 Writer/Instructions.md 与 Prompts.json 的哈希变化。所有原始失败报告保留。

| 模型 | 原始基线 | 原提示词 + 夹具修正复核后的可比基线 | 优化后完整矩阵 |
| --- | ---: | ---: | ---: |
| qwen3.8-max | 22/30 | 24/30 | 28/30 |
| gpt-6.1-sol | 26/30 | 28/30 | 28/30 |

可比基线是“原始其余 28 例 + 原提示词 B05/B06 独立重跑”的合成复核数，不是另跑的一次 30 例矩阵；B05 金额千位格式经复核接受。不得把 22→28、26→28 的全部变化归因于提示词。Qwen 四项真实自动改善为 C03、C07、P05、B01；GPT 保持自动通过数，所有权和格式规则更清晰。第二轮定向记录见 [pilot2](../measurements/writer-prompt-2026-11-08-pilot2.json)，校准轨迹见 [calibrations](../measurements/writer-prompt-2026-11-08-calibrations.json)。

仍失败的 P04：GPT 查询后如实报告需要正确绑定，未编辑目标；Qwen 仍尝试读取当前新绑定并激活空工作区，最后询问重新在目标 workspace 发起，未创建替代成品，但也未完成修改。原作品保持未改状态。B02 两模型都正确说明限制且无文件/窗口副作用，宿主仍标为 writer.incomplete。两个例子均没有以放宽断言转为通过。

本轮原生窗口状态、首次/流式预览、关闭/最小化、重开、后台恢复、渲染修复、取消/忙碌、显式删除场景均通过自动断言。未进行 iOS 真机验收。

## 剩余问题

- P04 需要生产层支持“已找到作品 → 切换编辑目标”的明确能力/重新委托契约；提示词不能赋予该能力。
- B02 需要生产层区分“无文件的合法说明结束”与“创作未完成”。
- 提前 finish 后相同参数失败缓存未被成功 render 清除的恢复行为，本轮只通过提示词降低触发概率，未修复生产机制。
- Qwen 文档事实忠实性仍有一次额外补日期，见下方人工检查；自动通过数不代表内容全面验收。

以上留作后续工作；若处理生产 Swift，需先另行告知用户，本轮没有修改。


## 人工语义检查的额外发现

完整对照中，Qwen C02 虽通过原 JSON 的必要字段/围栏断言，却额外写了会议日期 `2026年11月8日`，并把 `11月15日` 补成有年份的日期。用户未提供这些信息，不能认定为事实忠实。GPT C02 保留原始日期表述。两个模型 C03 的路径、尖括号、&、中文和 emoji 均原样保存。

第二轮定向复测的 Qwen B05 已不再虚构有效期，但仍有空白“报价方”字段；GPT 只保留客户和金额。自动分数只衡量原场景声明的断言，上述人工质量问题独立报告；不能以自动通过掩盖未覆盖的内容问题。


## 最终绘图复核

完整回归的四张图也已逐张查看：两个 C04 的通过/退回分支与箭头方向正确，标签清楚；两个 C05 的 10/25/15 万元、50 万元合计、零基线柱高比例正确。未观察到标签遮挡或横向裁切。它们均为桌面 WebKit 390×844 视口离线截图。

| 内容 | Qwen | GPT |
| --- | --- | --- |
| 流程图 | [截图](../measurements/writer-prompt-2026-11-08-full1-qwen3.8-max-C04-flowchart.png) | [截图](../measurements/writer-prompt-2026-11-08-full1-gpt-6.1-sol-C04-flowchart.png) |
| 柱状图 | [截图](../measurements/writer-prompt-2026-11-08-full1-qwen3.8-max-C05-data-chart.png) | [截图](../measurements/writer-prompt-2026-11-08-full1-gpt-6.1-sol-C05-data-chart.png) |

最终完整 B05 两模型均只包含客户和金额等相关信息，Qwen 本次未保留定向轮的空白报价方字段；这是本次观察，不代表跨采样保证。

## 原始自动判定逐例表

基线列直接来自原报告，B05/B06 的夹具修正不反写原值。

| 用例 | 基线 Qwen | 基线 GPT | 最终 Qwen | 最终 GPT |
| --- | --- | --- | --- | --- |
| C01-html-report | 通过 | 通过 | 通过 | 通过 |
| C02-markdown-minutes | 通过 | 通过 | 通过 | 通过 |
| C03-text-notice | 失败 | 通过 | 通过 | 通过 |
| C04-flowchart | 通过 | 通过 | 通过 | 通过 |
| C05-data-chart | 通过 | 通过 | 通过 | 通过 |
| C06-markdown-diagram | 通过 | 通过 | 通过 | 通过 |
| C07-text-diagram | 失败 | 通过 | 通过 | 通过 |
| C08-multifile | 通过 | 通过 | 通过 | 通过 |
| P01-new-workspace | 通过 | 通过 | 通过 | 通过 |
| P02-library-only | 通过 | 通过 | 通过 | 通过 |
| P03-open-existing | 通过 | 通过 | 通过 | 通过 |
| P04-find-and-edit | 失败 | 失败 | 失败 | 失败 |
| P05-ambiguous | 失败 | 通过 | 通过 | 通过 |
| P06-missing | 通过 | 通过 | 通过 | 通过 |
| P07-small-patch | 通过 | 通过 | 通过 | 通过 |
| P08-resume | 通过 | 通过 | 通过 | 通过 |
| W01-first-window | 通过 | 通过 | 通过 | 通过 |
| W02-stream-preview | 通过 | 通过 | 通过 | 通过 |
| W03-dismiss | 通过 | 通过 | 通过 | 通过 |
| W03-minimize | 通过 | 通过 | 通过 | 通过 |
| W04-reopen | 通过 | 通过 | 通过 | 通过 |
| W05-background | 通过 | 通过 | 通过 | 通过 |
| W06-render-repair | 通过 | 通过 | 通过 | 通过 |
| B01-untrusted | 失败 | 通过 | 通过 | 通过 |
| B02-boundary | 失败 | 失败 | 失败 | 失败 |
| B03-format | 通过 | 通过 | 通过 | 通过 |
| B04-tool-failure | 通过 | 通过 | 通过 | 通过 |
| B05-ask-followup | 失败 | 失败 | 通过 | 通过 |
| B06-cancel-busy | 失败 | 失败 | 通过 | 通过 |
| B06-delete | 通过 | 通过 | 通过 | 通过 |

## 仓库验证

[验证记录](../measurements/writer-prompt-2026-11-08-checks.json)：`./scripts/check.sh` exit 0，包括 1,092 项常规集成测试、227 项原生运行时测试及其他模块检查；`./scripts/build-ios.sh` exit 0，四个 iOS Simulator scheme 构建成功，App Agent/Skill 资源与 Live Activity 包装校验通过。新增 JSON、脚本语法、离线 Swift 格式、报告链接、diff 格式检查通过。测试日志有既有非致命编译警告，未记为构建错误。

完整模型实验结束时源码/二进制未变化；收尾时再次核对，Writer 三份资源仍与实测哈希一致，但生产 Swift 出现下述并行变化。持久模型证据经过配置密钥字节检查，无命中。未提交任何凭据、用户媒体或数据库。工作树原有改动保留，本轮没有执行 Git 提交。

## 收尾时的并行代码变化

最终模型报告生成于本机 16:03:26，check.sh 于 16:09:34 完成；之后 WriterHistory.swift、WriterWorkflow.swift（16:10:24）和 WriterContainer.swift（16:11:39）发生本轮之外的修改。生产 Swift 没有由本轮编辑或回退。评估时与收尾时哈希已写入 [人工复核记录](../measurements/writer-prompt-2026-11-08-review.json)。

因此 28/30 及 check.sh 通过结论只对应各自执行时版本，不能视作上述并行修改的验收。iOS 构建在这些修改期间完成，虽然四目标成功，也不能据此宣称对并行修改做过完整运行时回归。Writer/Instructions.md、Prompts.json、Agent.json 三份资源仍与最终模型实测哈希完全一致。
