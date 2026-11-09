# Writer 重复创建工作区与缺入口恢复

- 真机委托反复执行 create、read 缺失入口，再 create。Writer 按委托和规范化标题、入口路径保存分配记录。相同请求重试复用已分配的 ID，成功后的重复调用返回该工作区和下一步提示，使用既有恢复预算约束反复误调用。不同委托及不同创建目标仍可创建。
- ArtifactService 从真实草稿或发布文件检查入口是否存在，随工作区回执返回。Writer 把真实入口状态带入编辑控制请求。入口缺失的 read 保留失败，明确提示用 edit 创建入口。
- 同步 Writer 工具声明、Skill、Artifacts 与 Writer 技术说明。用真实 SQLite 和替身模型重放 create、read/list、重复 create、edit/render/finish，确认只分配和开一次新工作区。
- create 初始化时，在同一次草稿检查点创建缺失的零字节入口文件并保留已有内容。准备中页面仍使用独立占位。返回入口存在及空文件状态；编辑空入口使用宿主取得的零长度读取引用，已有内容继续要求显式读取引用。

实施日期为 2026-11-09。检查结果见[验证记录](../validation/Writer-Create-Loop.md)。
