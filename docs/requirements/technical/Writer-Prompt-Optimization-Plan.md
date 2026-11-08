# Writer 双模型提示词优化

2026-11-08。用户确认复用 .env.local 的 Provider URL/密钥；仅 Qwen3.8 Max、GPT6.1 sol。Swift 改动已在会话中事先告知：只扩展 IntegrationTests/WriterModelEvaluationTests.swift 的评估代码，生产 Swift 不修改。

## 范围与所有权

- 场景 JSON：Tests/AgentModelEvaluationTests/Scenarios/writer-workflows.json；模型/实验配置：同目录 writer-evaluation.json。均在既有目录。
- 测试适配器读取 JSON，实际执行 Writer/Gateway/Artifacts/SQLite 与 ArtifactPresentation/WebPageContainer/WindowState；macOS 界面动画完成回执由测试宿主提供，不等于 iOS 真机界面验收。
- scripts/evaluate-writer.py 读取两个 Provider 各自配置，隔离环境和输出，校验准确模型名称；不打印凭据，不修改凭据。
- Writer/Instructions.md 与 Prompts.json 使用生产装配器加载；只在公开职责确有错误时修改 Writer/Agent.json。Assistant/BasicSkill/Core 保持不变。
- 保留现有六场景的历史执行入口，新的 JSON 矩阵使用独立 opt-in 路径，不将旧历史结果改写成新矩阵结果。
- 原始 JSON、文件/窗口事件、请求与源码哈希归 docs/measurements；分析归 docs/validation/Writer-Prompt-Optimization.md。完整临时数据库、文件及截图存独立 /tmp 输出，持久报告保存脱敏请求、关键文件和必要视觉证据，不能只留临时路径。

## 验收设计

28 组覆盖 HTML/Markdown/TXT 办公内容、图形和关联文件；新建、只查库、打开、查找修改、歧义/不存在、局部修改、恢复；首次窗口、流式预览、关闭/最小化、重开、后台、修复；不可信内容、路径边界、包装格式、工具失败、追问、取消/忙碌/删除子例。每例初始数据独立，避免依赖前例生成质量。查找修改例不能预先绑定目标任务；显式续作例可绑定已知任务。

JSON 定义目标、合成初始作品、宿主事件及断言。必要效果与禁止效果分开；内容检查不规定唯一工具调用序列。区分模型质量、工具/产品能力、评估器缺陷与网络失败。机器结构检查和视觉评审分开，不能由 DOM 节点数推断图形正确。

## 实验顺序

先无模型验证资源装配/JSON/本机 WebKit，再以原始提示词运行完整基线；观察失败后仅修改拥有者资源，定向复测，再同场景完整对照。每阶段固定源码/场景/Provider设置，阶段内不改提示词。记录资源和测试二进制哈希；资源重打包后核对 Bundle 字节。保持 Provider 默认输出上限。实验设单例请求/时长界限，超限取消并明确记录，不修改生产限额。

模型目录已确认 qwen3.8-max 与 gpt-6.1-sol。首次 OpenAI 目录读取网络失败，第二次成功；不将连接失败记作模型行为失败。

## 验证

新增评估代码执行格式检查、无模型 fixture 预检和仓库 check.sh；完整 Xcode 可用时执行 build-ios.sh。真实模型/桌面 WebKit/窗口状态回归与手机验收分别报告。无法靠提示词修复的生产缺陷保留，不自行修改生产 Swift。

## 视觉评审补充（编写工具前告知）

生产截图接口要求 WKWebView 已挂载原生窗口。矩阵宿主虽有真实 WindowState/WebKit，但没有原生视图挂载，因此返回 screenshot unavailable，不伪造模型已看图。增加 scripts/render-writer-review.swift，仅离线加载已生成的 HTML 与本地资源并输出图像；不改变矩阵发送给模型的内容，不把离线截图当作模型曾经接收的证据。该 Swift 评估工具已事先在会话告知，生产 Swift 仍不修改。

## 基线发现与首轮调整

- 追问评估遗漏 OutputGateway.bindCommunications；先保持原提示词，补接测试宿主存储，再单独重跑 B05。原超时记录保留，不算提示词收益。接线修改已提前告知。
- 控制提示明确所有格式先 render 后 finish，包括纯文本、Markdown 与单字替换。预览/read 不代替 render；无截图不可宣称视觉验收。
- 查作品使用 projects 实际结果，同名多匹配必须 ask；open 只显示作品、不改变当前编辑绑定。无法重绑的续作保持失败证据，不以新建替代原作品。
- 去除 Writer 中对 Assistant 职责的介绍，只保留自身 ask/finish 与宿主接口。WriterAgentTests 的旧字符串断言同步到自身职责边界，修改前会话告知。
- content.base 保留跨格式源文件规则，页面排版移至 content.web；文档/图形保持事实、数值、单位和拓扑，避免猜测日期、参会人或装饰功能。
- B02 正确说明限制、无文件副作用，但运行时结束 failed；保留端到端失败与行为合规两个判断，不放宽原断言。B01 的 open 发生在读取注入文本之前，不能据此认定提示注入成功。

复测接线后，B05 实际已收到提问并发送了回答，原问题更准确地说是续答缺少通信入库接线，导致 Writer 未接纳回答；B06 同受此接线影响。两者复测完成/取消正常。金额断言允许标准千位逗号（12,000.00 等值于 12000），不改变精确替换断言；原始失败保留，比较表单列复核。报价案例观察到未经用户授权的 30 天有效期，内容提示加入禁止虚构商业条款。

首轮定向复测两模型各 6/8。Qwen 在 P04 调用 projects 后仍误把新绑定当原作品并创建副本，在 B02 收到发布恢复观察后把限制说明写入新文件。第二轮在控制提示开头明确新建授权和失败恢复边界；可选字段也不得生成空表单占位。评估工具调用统计原从有界历史读取，会漏掉被截断的早期 projects；改从完整请求轨迹取实际调用，不改变文件效果断言。测试 Swift 调整已事前会话告知，原报告保留。

完整回归前只调整测试收尾：未配置回答的追问直接记录 waitingUser，再清理；不空等时长上限。非预期追问仍不通过，不把等待当完成。该测试 Swift 修改已告知。第二轮提示词冻结用于完整回归；P04/B02 的产品缺口不修改生产 Swift。

## 实验收尾

完整矩阵与两轮定向测试已执行，最终两模型各 28/30；可比基线 Qwen 24/30、GPT 28/30。测试夹具修复、原始分数、人工内容发现和视觉证据见 [验证报告](../../validation/Writer-Prompt-Optimization.md)。本轮资源所有权优化已落地；P04 重绑、B02 无文件完成及失败缓存恢复的生产缺口留作后续，未修改生产 Swift。Qwen 日期补写仍需后续质量回归，不能将自动分数等同内容全部通过。

收尾验证：check.sh 与 build-ios.sh 均 exit 0；详细测试计数、四个模拟器目标构建和 App 资源校验见验证报告。Writer 资源与最终模型实验哈希一致；收尾发现三份生产 Swift 的并行改动，版本边界见验证报告，不纳入本轮模型验收。原始失败及人工质量缺口不因构建成功而关闭。
