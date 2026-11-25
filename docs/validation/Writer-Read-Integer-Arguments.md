# Writer 文件读取参数兼容验证

## 真机故障证据

2026-11-24 使用 Xcode 从已连接的 iPhone 只读复制 SQLite 主库和 WAL。离线副本通过 `PRAGMA integrity_check`。工作区第 9–11、15–17 条消息均为 HTTP 200，调用在 Responses 的 `response.output_item.done` 阶段被判为 `writer.model.tool.invalidArguments`。第 15 和 17 条输出 JSON 整数 `limit`，第 16 条输出 JSON 整数 `offset` 和 `limit`。工具执行记录为空，两个编辑委托均失败。`fox.html` 的索引最后写入于 00:39:06，早于拒绝记录。原始数据库仅用于离线排查。

## 工程验证

- SwiftPM 原生构建通过。三项 Swift 专项测试通过，覆盖 Writer 从实际工作区工具目录启用的范围、Responses SSE 中的整数转换、原样字符串、类型与溢出拒绝、增量及终态参数一致性。日志 `/tmp/mobileharness-writer-read-integer-native-tests.log`。

- `./scripts/check.sh` 在边界检查退出。AgentContainer State Value codec 与 Xcode 本地化资源分组的诊断与修复前 `/tmp/mobileharness-wake-literal-check.log` 一致。脚本未执行后续阶段。日志 `/tmp/mobileharness-writer-read-integer-check.log`。
- 独立执行的 8 个 Python 工程回归、plist 检查、改动的 Swift 文件格式检查及 `git diff --check` 通过。全仓 Swift 格式检查报告 Assistant 的 `PromptTemplateTests.swift` 有 3 处行长违规。
- `./scripts/build-ios.sh` 在首个 Simulator scheme 编译 `ListeningHalo.metal` 时失败。Xcode 报告缺少 Metal Toolchain，也发出 CoreSimulator 版本过旧的警告。其余 scheme 未执行。日志 `/tmp/mobileharness-writer-read-integer-ios.log`。

修复版没有安装到 iPhone，也没有执行真实模型或原生界面验收。
