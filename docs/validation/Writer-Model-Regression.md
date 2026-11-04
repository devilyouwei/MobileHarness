# Writer 本机真实模型多流程回归

日期：2026-11-04。目的：区分模型/Provider、内容协议、文件事务、渲染和 Writer 循环造成的停滞。测试工具和用例见 [IntegrationTests](../../Tests/IntegrationTests/WriterModelEvaluationTests.swift)、[runner](../../scripts/evaluate-writer.py)；计划见 [Writer plan](../requirements/Writer-Agent-Plan.md)。

## 方法与证据范围

真实 Provider 使用被忽略的 `.env.local` 阿里兼容端点，`qwen3.8-max`、`deepseek-v4.1-flash`，Writer thinking enabled，maximumOutputTokens=nil。Provider `/models` 确认实际 DeepSeek ID 含 `-v`；用户口述的 `deepseek4.1-flash` 不在列表，其 Responses 首请求返回 server_error。此次未读取或使用 OPENAI_API_KEY。

生产 WriterAgent、Gateway direct、ArtifactService、DiskFileStore、FileDocumentStore 和 SQLite 均实际执行。请求者是接纳消息的测试 Agent，无 Assistant 模型/语音。渲染端口使用本机 macOS WebKit 加载独立文件快照，捕获 JS/resource 错误、DOM 和按钮点击。Markdown 在测试渲染器中转义显示；不代表生产 Markdown 样式、截图语义、原生 iOS 窗口、PDF/ZIP、语音或真机验收。

六个串行任务流程：diagram、multifile、partial-resume、file-operations、markdown、javascript-repair。两个模型使用独立进程/Storage 根。新任务目录隔离；续作保持 task/dialog/project，run 更新；无关 CSS/JS 按字节比较，最终 SQLite 重开核对历史/工具配对。每请求记录开始、首事件、增量字节、结束、工具参数、用量/错误；每 case 即时保存结果。

为控制付费实验，测试每 case 最多36个实际请求、默认等待600秒，超时显式取消并标为 evaluationTimeout；生产无该总轮数/期限，未增加输出 token 限制。每个 Provider 请求的暂时错误仍使用生产最多3次恢复。

## 首轮调查

- 旧 task_5 已证实的流解析限额是应用问题，见 [设备证据](Writer-Agent.md)；本轮使用移除该限制后的代码，不重跑或清空设备历史。
- `deepseek4.1-flash` 错误模型 ID：四个可独立启动的 case 均首个控制请求 server_error，分别三次尝试后失败；依赖作品的两个续作用例无法执行。这不证明 DeepSeek 生成能力有问题。
- 正确 ID 下，DeepSeek 出现 HTML 外层 Markdown 围栏。旧 Writer 原样接收包装，后续模型不断清理围栏/修格式；简单流程图达到实验请求上限才结束。
- DeepSeek 将 start/end 填成 CSS 选择器。参数原本只有 string 类型和一段总说明，缺少逐参数解释。
- file-operations 实际已完成 move/remove/render，却在 finish 中额外传 verification；执行前 CapabilityRegistry 抛 invalidParameters，Writer 报未知 runtime 异常并结束。这是可修正模型参数未被 Writer 正确归类，不是文件容量问题。
- Qwen 简单流程图约68秒完成，多文件约79秒完成；续作对换行/排版多次重写明显拉长流程。原测试的标题短语存在语言歧义，复测明确用引号指定精确标题，不将这项断言直接作为模型错误。
- 首轮测试渲染器使用同一 URL 写回资源，JS 错误修复后存在旧资源缓存干扰。复测改用独立快照路径，并以实际 broken→fixed JS 和点击行为做无模型预检，区分评估适配器问题与生产错误。

## 对应修复

Writer 域增加跨 delta 原始代码前缀检查：代码格式的外层围栏在提交前失败，abort加入后新stream有限重试，附格式修正提示；不剥离/猜测源码，MD/TXT围栏保留，错误码writer.content.markdownWrapper。逐参数说明/命令枚举明确引用范围和数字偏移；执行前invalidParameters转成带executed=false的可修正工具错误。控制/内容指令强调最小满足目标、范围边界/换行和完成条件，避免无请求的打磨。后续根据复测证据补入确定性replace，见下节。共同框架/Gateway/模型默认上限不变。

定向替身回归已覆盖格式检查、恢复成功/耗尽、参数错误纠正与完整配对；真实WebKit预检已验证脚本更新后无旧异常且点击0→1。实际数字和全套检查在最终结果更新。

## 复测

最终完整矩阵见下节；首轮/第二轮失败与主动中止记录保留，不能用最终通过改写历史失败。

### 第二轮诊断与确定性补丁

前缀/参数/完成提示修复后，DeepSeek完整六例中4例通过：diagram32s、multifile26s、markdown10s、javascript-repair18s。partial-resume仍245s失败，30次请求中多次试图修缩进，最后纯空格内容响应三次truncated；file-operations因前置任务未完成明确标记依赖缺失。Qwen已通过diagram49s、multifile144s、partial-resume170s，局部修改仍有不必要的片段重写。

诊断阶段在确认问题后主动停止尚未完成的Qwen进程，退出-15、complete=false；首轮和第二轮均不是最终全通过验收。第二轮DeepSeek已经自然结束。中途继续修复源码，前两次runner的sourceUnchanged=false被保留，不能称为同一未变源码快照的最终比较。

据此新增新鲜读取范围内唯一literal replace，用于短编辑，避免把改几个字/路径/缩进交给独立内容生成请求。原有流式大段创作继续保留。修复后按相同六个任务流程重新执行，结果以最终矩阵为准。

最终矩阵准备阶段遇到check.sh持有SwiftPM测试锁，未启动Provider请求。Runner增加显式test-binary入口，并通过同一测试helper运行真实WebKit预检，避免为预检和路径查询再次等待SwiftPM锁。最终使用已构建的当前IntegrationTests二进制，记录其SHA-256；准备阶段不计入模型耗时。

## 最终完整矩阵（源码与二进制未变）

`/tmp/writer-real-20261104-e.summary.json`：sourceUnchanged=true、binaryUnchanged=true；两进程exitCode=0、complete=true，各6/6通过。已保存到文档目录的[机器结果](Writer-Model-Regression.json)包含源码/二进制哈希、逐例结果、SQLite绑定和证据文件哈希；[逐请求轨迹](Writer-Model-Regression-Requests.json)包含阶段、首事件/完成时间、字节、native参数与实际用量。凭据不进入这些文件。

| 流程 | Qwen3.8-max：秒／请求数 | DeepSeek-v4.1-flash：秒／请求数 | 结果 |
| --- | ---: | ---: | --- |
| 简单SVG/HTML流程图 | 78／6 | 42／8 | 均通过 |
| HTML/CSS/JS多文件计数器 | 69／9 | 43／10 | 均通过，WebKit点击0→1 |
| 续作局部修改标题 | 30／7 | 11／7 | 均通过，独立内容请求0次，CSS/JS字节不变 |
| search／move／replace／新增读取删除 | 52／13 | 15／10 | 均通过，路径引用及最终文件集正确 |
| Markdown报告 | 75／6 | 13／5 | 均通过，源码及代码围栏保留 |
| JS报错→读取→修复→重新render | 53／9 | 14／9 | 均通过，先捕获错误再验证点击0→1 |
| 完整运行 | 356.5／50 | 137.8／49 | 12/12 |

Qwen首事件等待中位约3.97s、最长47.23s；DeepSeek约1.61s、最长20.52s。最终99次真实请求无请求失败，全部maximumOutputTokens为provider default。Qwen中Markdown内容请求约49s，说明简单任务也会有明显模型响应等待；不能把这类等待与文件工具卡死混为一谈。本样本不支持对所有任务或所有Provider做性能保证。

两个数据库重开与integrity_check均通过。各有四个独立Writer对话/项目（新任务task_1、task_2、task_5、task_6）；task_2的run为task_2/task_3/task_4，始终绑定dialog_2和同一项目。只存在writer范围的对话，未伪造Assistant历史。完整原始SQLite、history JSON、workspace索引/作品和渲染快照保留在机器结果中列出的两个/tmp根；文档保留其SHA-256，不提交这些临时数据库。

复现：

```sh
python3 scripts/evaluate-writer.py --output-prefix /tmp/writer-regression-new
```

本次使用已构建的IntegrationTests，通过`--skip-build --test-binary /Users/devil/Pro/MobileHarness/.build/out/Products/Debug/IntegrationTests.xctest/Contents/MacOS/IntegrationTests`运行同一入口；完整命令无密钥参数。

该矩阵证明上述有限样本下生产Writer循环、文件工具、续作与本机WebKit可完成；不覆盖iOS真机对话、截图视觉质量、流式预览动画或后台系统调度。未安装本次修复到真机，未清空手机SQLite，未替换任何设置中的模型。

模型请求流在途时间合计：Qwen353.919s（六例总356.023s），DeepSeek135.197s（总137.282s），其余宿主流程分别约2.10s/2.09s。该指标包含Provider/网络/流消费，不能等同纯模型推理时间；本样本未观察到独立文件/渲染工具长期卡死。此前多次局部片段请求放大了这些等待，确定性replace减少了这类请求。

## 自动化与构建记录

- `/tmp/writer-regression-focused.log`、`/tmp/writer-eval-final-build.log`：围栏跨delta/Unicode/Markdown保留、恢复成功与三次耗尽、非提交断言通过。
- `/tmp/writer-exact-patch-tests2.log`：范围/唯一匹配/过期与跨文件引用/删除/失败原子性通过；十种生产Writer/Gateway替身场景通过，包含参数修正、精确补丁、开始失败、取消、等待输入及通知拒收。
- `/tmp/writer-render-preflight2.log`及最终runner预检：真实macOS WebKit broken→fixed本地脚本重载、错误清除、点击0→1通过，未使用模型。
- 首次全量`/tmp/writer-multicase-check.log`：WriterIsland重试用例按墙钟推定调用数，在并发负载下失败；改用首调用显式挂起/释放门，精确验证一个在途+最新内容/新run围栏/stop，不修改生产重试频率。定向回归通过。
- 第二次`/tmp/writer-multicase-check-final.log`：Writer相关回归通过，但既有residentNativeStateObservationDuringSeedingWinsOverTheBaseline在并发负载下超过三秒等待，invalidSnapshot。未改其生产逻辑或放宽断言；隔离重跑`/tmp/writer-native-seeding-recheck.log`约0.008s通过。
- 最终完整`./scripts/check.sh`，`/tmp/writer-multicase-check-recheck.log`：exit0，1008 IntegrationTests、174 AppWorkflowTests、225 LiveRuntimeTests及其余测试/边界/格式/六项Python/Plist检查全部通过。前次失败证据保留；单次重跑通过不保证消除所有宿主时序波动。

- `./scripts/build-ios.sh`，`/tmp/writer-multicase-ios.log`：exit0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero四目标BUILD SUCCEEDED；主应用30项Agent/Skill资源及Live Activity嵌入校验通过。此为模拟器目标构建，未执行真机安装或真机交互。
- `git diff --check`、Python脚本语法检查、报告/轨迹JSON解析通过；验证文档及机器结果扫描未包含.env.local中已配置的API key。机器报告的源码哈希再次核对一致，临时原始证据保留以便复查。
