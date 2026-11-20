# Database tests

## 基础相册实施契约

覆盖旧库丢弃／相册收录／保护保留／分页／删除清理／导入字节与权限失败，区别自动化与真机验收。

Photography完成示例使用明确的“App相册”文案；保持与BasicSkill各自的独立成功示例解析和不结束无关Task的断言。

## 文件归属

- [AlbumTests.swift](AlbumTests.swift)
- [DatabaseTableRecordTests.swift](DatabaseTableRecordTests.swift)
- [SQLiteDialogLifecycleTests.swift](SQLiteDialogLifecycleTests.swift)
- [SQLiteRecordSupport.swift](SQLiteRecordSupport.swift)
- [SQLiteRecordTests.swift](SQLiteRecordTests.swift)
- [StorageRepositoryContractTests.swift](StorageRepositoryContractTests.swift)
- [StorageSchemaTests.swift](StorageSchemaTests.swift)
- [WorkspaceRepositoryTests.swift](WorkspaceRepositoryTests.swift)

DatabaseTableRecordTests 验证 published_at 与消费确认独立、先补读消费不改变源端发布队列，以及 schema 20261119 到 20261120 的非破坏迁移。
