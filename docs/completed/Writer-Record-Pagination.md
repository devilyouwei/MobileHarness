# Writer 记录分页与返回保留

2026-11-08，用户反馈任务执行轮次加载到底后仍显示加载更多，进入请求详情返回会丢失已加载页。

## 原因与设计（修改前）

WriterContainer 用 rows.count == 20 猜测下一页，恰好整页时误报；末页定时刷新又会返回同样游标。WriterRecordsView 和 WriterTaskDetail 的 .task 每次出现都重置第一页。

- Writer 自有记录控制器用 21 条前瞻返回最多 20 条及准确 next；Storage 只开放既有有界 limit，不引入 UI 分页策略。请求页/任务页统一末页语义；WriterTasks 本身已支持 limit=21。
- UI 自有 WriterTaskPage DTO 携带 nextID；WriterRecordsControlling.tasks 返回完整分页结果，不让 UI 按数组长度猜测。
- Writer 页面自有分页值保存已加载行、下一游标、首次成功标志；导航返回复用它，只有显式下拉刷新替换成功快照。失败/取消保留行和游标；异步返回取消后不发布。
- 自动刷新更新已有摘要/末尾记录，不重置已加载页。末尾补读继续使用精确下一游标；出现新记录可追加、去重、保留此前已加载记录。请求页刷新与翻页共用已有单读取槽，不增加排队。
- 修改 UI/Settings/WriterRecordsView、Agents/Writer/WriterContainer、Storage/Database/WriterMessages/WriterHistoryStore，以及现有 UI/Integration 测试和各 owner README；总体设计补充跨模块分页游标与页面状态归属。无新目录/数据库 schema；其他工作区修改保留。
- 回归覆盖 0/19/20/21/40 条末页、详情返回保留、重复尾页刷新、新增记录、失败/取消保留与重试；执行 check.sh、build-ios.sh。自动化/原生交互验收分别记录。

## 实施与验证

上述分页契约、页面状态保留及回归已实现。完整检查与四个 iOS 目标构建通过，详见[验证记录](../validation/Writer-Record-Pagination.md)。原生返回手势和实际滚动位置是独立复验项，本轮未安装真机。
