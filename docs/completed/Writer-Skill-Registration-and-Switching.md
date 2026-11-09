# Writer Skill 统一注册与工作区切换

- 作品库 Skill 通过现有 useActions 声明完整目录，包括 Writer 本地的 enter/create/ask/finish；共享目录解析同样的工具声明，Writer 按真实地址选择本地处理或 Gateway。编辑 Skill 依赖作品库 Skill，进入后同时注入两者的工具和教学。
- 模型可在编辑阶段查询、展示、切换或显式结束。enter/create 单独成轮，切换前加入预览及编辑会话清理，已有检查点作为草稿保留。模型选择目标；SQLite 用预期的旧绑定校验替换，只影响切换后的消息。目标准备失败时恢复上一编辑会话。finish 发布当前工作区，切换本身不发布旧草稿。
- 修改 Writer、Skill 注册与 Storage Writer 绑定接口，沿用当前身份格式、目录和 Gateway 能力边界。当前编辑目标只能由编辑工具修改，其删除请求显式拒绝。验证两阶段目录、实际切换、历史归属、失败恢复与结束。

实施日期为 2026-11-09。检查结果见[验证记录](../validation/Writer-Skill-Registration-and-Switching.md)。
