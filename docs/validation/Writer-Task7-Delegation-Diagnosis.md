# task_7 委托分组异常调查（2026-11-08）

## 结论

读取已连接 iPhone 的 App SQLite 主库与 WAL，生成本机离线副本；导出前后主库与 WAL 的大小、修改时间一致，离线完整性检查为 ok。task_7 共 30 条记录，只关联两个真实 task.request：A 在 18:44:02 发起重新绘制，22 条记录；B 在 19:15:05 发起继续任务并打开窗口，8 条记录。29 条为模型调用，1 条为补充输入。按当前显示规则复现出 10 个“委托”段，截图中的委托 6/7/8/9 与离线计算吻合。

## 三个问题及证据

1. **选择已有作品后排序值回落。** B 的 projects/select 两条记录（567/569）迁移到 task_7 后为 position 1302/1313；select 成功后新记录 572 却是 position 25，后续为 35、45、55、65、93。因此 19:15 的记录插入 18:45 的历史中。position 35 同时对应 509/573，45 对应 511/574。
2. **补充输入被归入当前委托。** 503 是 18:45:00 的补充输入，数据库 request_message_id 属于 A，没有 producerMetadata。预览查询只取 producerMetadata 的 delegateID，WriterContainer 缺失时回退到 task 当前 delegateID（B），将旧输入错误归类。
3. **界面把相邻 ID 切换当成新委托。** WriterTaskDetail 每遇到 delegateID 改变就加一，而非按真实请求身份分组/编号。数据交错和错误回退把 2 次请求放大为 10 段。

代码链路：WriterTasks/SQLiteWriterTasks.selectWorkspace 将源消息 position 加上目标末尾偏移；WriterHistoryStore.synchronizeCurrentLocked 只替换 current，没有采用已加载 revision 或历史最大顺序，commit 又只使用旧 value.revision+1；后续 begin 使用 value.revision+1 生成 historyOrder。初次 load 会读取 saved.revision，但选择/切换路径缺少相同的顺序保证。

## 修复归属与约束

- Storage/WriterMessages：切换与选择后保持持久化顺序单调，不能让变更 revision 与消息排序号混用造成回退；新号必须大于已有最大 position，包括窗口外记录。补充输入/模型调用的委托身份从本行 request_message_id 投影。
- Writer：展示适配使用该条记录的真实委托身份，不把任务当前请求当作旧行兜底。
- UI/Settings：委托编号按稳定请求身份计算，不按交错次数制造新委托。无需调整 Assistant/Writer 提示词。
- 既有坏数据：只修后续分配无法修复当前 task_7。需要受控修复重复/倒退 position，并保证分页游标、来源跳转、消息主键、调用关联和业务内容保留；本次没有写回手机。
- 回归应覆盖旧任务大顺序值、临时新任务选择旧作品、选择后继续写入、补充输入无元数据、交错同一委托、同 position 跨分页边界和已有数据修复幂等性。此前分页修复针对末页猜测与返回重载，未覆盖此次持久化顺序损坏。

## 证据与范围

[脱敏诊断摘要](../measurements/writer-task7-2026-11-08-diagnosis.json)包含逐行时间/顺序、A/B 归属、显示分组、文件与源码哈希。原始用户数据库只保留在 /tmp/task7-device.sqlite、对应 WAL 和 /tmp/task7-snapshot.sqlite，不进入仓库。只读检查未重启、安装或修改手机数据库；此轮没有改 Swift、提示词或工具配置，也未运行构建。离线分组复现不是原生点击验收。
