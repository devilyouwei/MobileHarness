# Assistant 对话详情验证

2026-11-08。范围见[需求](../completed/Assistant-Conversation-Detail.md)。

## 行为与范围

Assistant 单轮详情使用 User Request → Assistant Response → Tasks → Skills → States → Function Catalog → Prompts → Generation Meta → 日志清空按钮的顺序。Tasks/Skills/States 是同级独立区块，颜色/图标分别区分。Writer 专属详情未调整。

States 只记录当轮实际采集的路径，保存在 assistant_messages.decision_json，不增加表或列。完整事实与图片仍属于可清理日志。旧记录缺少证据显示 Not recorded；明确空选择显示 None。清空日志后隐藏 Prompts/Meta/按钮，显示 Logs cleared；同时清除详情缓存中的日志内容，导出不会再携带旧请求或返回事件。

## 自动化证据

- 首轮专项通过：UI 清空副本/导出与 State 缺失/空列表两项；SQLite State 选择持久化及日志删除后保留通过，过滤器同时执行的既有 State 投影用例也通过。日志 /tmp/mobileharness-assistant-detail-focused.log。此轮先于无用 preview 接口删除，最终完整检查另记。
- 删除 HistoryExecutionPreview 后首次完整检查被工程分组引用检查拦下：清理文件引用时误删了 Memory 分组。已恢复完整分组并只移除已删文件引用，边界检查重新通过。日志 /tmp/mobileharness-assistant-detail-check.log、/tmp/mobileharness-assistant-detail-boundaries.log。不将该次失败记为测试通过。

## 验收边界

自动化数据回归与编译不代表 iPhone 原生列表视觉、图标颜色、交互及真实模型验收。本轮未安装真机、清空用户数据或执行真实云端调用。

## 完整检查结果

- ./scripts/check.sh 最终退出 0，日志 /tmp/mobileharness-assistant-detail-check2.log。1,084 项集成测试、199 项 UI 数据测试、175 项工作流测试和 227 项 LiveRuntimeTests 通过，其他测试 target、模块/工程引用检查、6 项 Python 测试、严格 Swift 格式与 plist 检查通过。Skill 变化后逐轮记录 State 路径的回归也通过。
- NativePresentationTests 完成两项相机呈现测试后启动 cameraNativeMetalDrawStopAndLayerHandoff，没有完整套件结束结果；不将脚本退出 0 等同于完整原生呈现验收。
- 详情页空列表布局收拢后单独严格格式校验通过；源码 README 和需求/验证文档的相对链接检查通过，git diff --check 通过。

- ./scripts/build-ios.sh 最终退出 0，MobileHarnessSimulator、ModelKitRuntime、ModelKitNemotron、ModelKitSilero 四个目标均 BUILD SUCCEEDED。日志 /tmp/mobileharness-assistant-detail-ios.log。构建覆盖最终详情页布局及 preview 接口删除；未安装到真机。
