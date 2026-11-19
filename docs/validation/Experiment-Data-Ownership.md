# 实验数据职责整理验证

2026-11-19。

- 166份原始 JSON/CSV 从 docs 迁入所属任务 Results：Decision 123份、Assistant 21份、Writer 22份。迁移前后 SHA-256 全部一致，历史来源路径、源码哈希、失败和测量值不改写。
- docs 已无 JSON/CSV/JSONL 或 Python/Swift/Shell 脚本；保留报告、设计源、许可证和文档图片。报告引用的截图为文档附件，不是评估输入。
- 迁移数据的 Markdown 链接全部解析到存在的文件；活动 Python/Swift/Shell 不再引用 docs 数据路径。Xcode 导航同步，原编译成员和 target 边界保留。
- Decision 历史 readout 使用冻结报告作为回放输入，校验固定输入哈希及运行结束时的完整性；旧 sourceHashes 仍在原始报告内，仅说明历史版本，当前 runner 哈希记录到新输出。
- Writer README 去除无关工程测试说明；根贡献规则、experiments、任务及数据目录文档明确输入/输出/报告分工。本次不改为纯 Python。
- Python 语法检查通过。首轮工程检查发现迁移路径造成 Swift 超长行，已格式化后重跑。

`./scripts/check.sh` 返回0：18项 Python 工具测试、边界/严格格式检查、全部 Swift target 与五项项目/plist 检查通过。普通 IntegrationTests 1197项、AppWorkflowTests 198项、串行 LiveRuntimeTests 231项通过。日志 `/tmp/mh-experiment-ownership-check.log`。

`./scripts/build-ios.sh` 返回0，五个 Simulator scheme 构建成功，资源检查通过。日志 `/tmp/mh-experiment-ownership-ios.log`。最终迁移哈希、数据链接、docs 文件类型及 diff 格式检查通过。

未开启真实模型、历史 readout 的原生推理或设备实验；本轮验证不代表模型效果或真机验收。
