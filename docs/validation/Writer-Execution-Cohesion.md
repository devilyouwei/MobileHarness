# Writer 请求与作品选择内聚验证（2026-11-08）

本轮在用户授权后修改 Writer 业务 Swift、私有提示和对应测试，处理[提示词实验](Writer-Prompt-Optimization.md)暴露的运行时缺口。没有新增目录、表或 Assistant 前台任务；保留工作区已有的其他改动。

## 实现与归属

- Writer 接纳目标后建立自己的临时请求记录，删除按 description 子串猜测已有作品的逻辑；入站 taskID/workspaceID 明确拒绝。
- 原生 select(taskID) 由 Writer 拥有：查询/澄清后在同一通信请求内选择已有作品。Storage 事务接续请求及消息并删除空临时任务；旧文件、旧历史、工具 ID 和通信 ID 保留。首次文件操作后禁止跨作品切换。未选择目标的读取不会创建空工作区。
- finish(summary,outcome=explanation) 明确完成无文件说明；已开始文件操作仍必须通过渲染和发布检查。
- render 成功后仅清除 renderRequired 的 finish 失败缓存；select 成功仅清除未选择工作区的读取失败缓存。实际校验与有限恢复次数保留。
- Writer 私有 Instructions 教学上述流程；公开介绍仍由 Writer/Agent.json 拥有。Assistant/BasicSkill 提示没有因本轮而修改。task.delegate 与 delegateID 保留为通信协议及关联键，不代表调用者分配 Writer 任务。仓库旧 delegatedTask/beginDelegation 等接口统一改为 task/beginRequest 等本侧术语，无双实现。

当前设计：[Writer](../../MobileHarness/Agents/Writer/README.md)、[WriterWorkspaces](../../MobileHarness/Storage/Database/WriterWorkspaces/README.md)、[WriterMessages](../../MobileHarness/Storage/Database/WriterMessages/README.md)。

## 确定性业务回归

WriterAgentTests 的七模式使用真实 Gateway、Artifacts、SQLite 与脚本模型，覆盖：查询选择后局部修改、追问回答后选择、无目标读取失败后选择恢复、无文件说明、提前 finish→render→相同 finish、编辑后拒绝 explanation、编辑后拒绝跨目标切换。身份注入在接纳前拒绝；重开数据库核对工具配对和请求/任务关联。

WorkspaceRepositoryTests 验证不存在目标、目标持有写租约及请求已取消时事务拒绝，关联和文件不变。相关原有十四模式一同复测。最后定向检查三项测试（其中两个参数化为七、十四模式）通过；模型与呈现替身不计为真实模型/原生 UI 验收。

## 真实模型实验

使用已授权 .env.local 中各 Provider 的 URL/key，仅 qwen3.8-max、gpt-6.1-sol，thinking=minimum，输出上限沿用 Provider 默认。仍使用原有 28 组/30 子例的 JSON 场景及断言，没有为通过而放宽 P04/B02。矩阵按请求关联读取选择后的实际 taskID，源哈希增加 WriterTasks/WriterMessages 实现。

[定向七例](../measurements/writer-cohesion-2026-11-08-pilot1.json)两模型均 7/7，sourceUnchanged、binaryUnchanged 均为 true。两模型 P04 均执行 projects→select→search→read→replace→render→finish，修改原作品且样式和其余字节不变；B02 显式 finish(outcome=explanation) 完成，没有文件或窗口副作用。其余含歧义追问、已知作品续作、不可信文档及补充输入。

该定向实验后补齐入站 workspaceID 解码拒绝及对应测试，再构建进行完整矩阵；提示词和选择业务流程未改变。完整结果见下方；仓库检查单独记录。

## 证据边界

真实 Provider、Writer/Gateway/Artifacts/SQLite、生产窗口状态及桌面 WebKit 实际执行。桌面宿主合成窗口动画回执；矩阵未挂载原生窗口时截图如实 unavailable。不是 iOS 真机或原生动画/触摸验收。自动断言的通过也不代表所有生成内容均经过语义和视觉验收；旧报告中的额外日期问题保留原结论。

## 完整矩阵结果

[完整原始结果](../measurements/writer-cohesion-2026-11-08-full1.json)两个模型均 30/30、进程 exit 0；sourceUnchanged、binaryUnchanged 均 true。模型/场景/断言与原提示词最终实验一致，本轮每例期限为 180 秒（评估配置默认 300 秒），请求上限 24，未放宽成功断言。

| 模型 | 上轮提示词优化 | 本轮执行内聚 |
| --- | ---: | ---: |
| qwen3.8-max | 28/30 | 30/30 |
| gpt-6.1-sol | 28/30 | 30/30 |

P04 两模型都在原作品内完成局部替换，没有副本；B02 两模型都以 explanation 成功结束，没有发布或打开空作品。首次工作区、作品库、歧义、续作、流式窗口、关闭/最小化、重开、后台、渲染修复、不可信文件、工具失败、补充、取消/忙碌、显式删除均通过原断言。提前 finish 的缓存恢复由确定性用例专门触发，不能声称本轮所有真实模型都触发了这个分支。

抽查本轮两份 C02 会议纪要，都保留“11月15日”且没有增加会议日期/年份；此前 Qwen 补写日期的历史问题不改写为不存在，也不推导统计保证。本轮未重新进行全部办公文档的视觉和语义验收。

## 仓库验证与归档

[检查证据](../measurements/writer-cohesion-2026-11-08-checks.json)保存命令、起止时间、退出码、日志哈希与改动前后文件指纹：

- `./scripts/check.sh` exit 0；模块边界、目录文档、Python 检查、Swift 格式、各模块测试与 plist 校验通过。常规集成阶段 1,094 项，原生运行时阶段 227 项。
- `./scripts/build-ios.sh` exit 0；MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四目标成功，App Skill 资源及 Live Activity 包装校验通过。
- 收尾时实验追踪的源码、Writer 资源与场景仍与完整 30 例矩阵的哈希一致。仓库已有并行改动保留，文件差异相对本轮开始快照记录，不把整个工作区差异归为本轮。
- 新增测量文件经过本地凭据精确值检查，无匹配；只保存合成场景文件与模型轨迹。链接及 diff 格式另行核对。

原设计与完成范围已归档到[Writer 请求与作品选择内聚](../completed/Writer-Execution-Cohesion.md)。本轮不构成真机验收，构建和自动测试不能替代物理设备或全部内容质量验收。
