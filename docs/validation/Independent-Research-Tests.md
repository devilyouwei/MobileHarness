# Tests / experiments 独立验证

2026-11-19。

## 边界

- Tests 不再读取 Assistant/Writer 实验矩阵；单次通信 smoke 使用自身内嵌输入。删除两个仅验证研究数据的 Swift 测试及未使用的矩阵读取/报告类型。
- Python 研究回归全部归 experiments：根13项、Assistant 7项、Writer 1项，分别独立执行通过。工程脚本自身8项回归独立通过。
- scripts/models 的 Laya/Vela 工程参考检查不再导入研究加载器；工程侧保留独立适配器和制品清单。删除从研究结果生成工程夹具的旧脚本，冻结工程夹具独立维护。
- benchmark 不再导入下载器；工程边界扫描不再扫描实验目录。Models 仅共享下载制品，不承载共同业务库。
- 静态检查：Tests Swift 与 scripts/models、scripts/checks Python 无 experiments 引用；研究 Python 无 Tests 文件访问、工程代码或 scripts 库导入。历史数据内的来源路径不是活动依赖，保持原样。

## 执行

首轮check因移除旧矩阵类型时误删WriterPromptSeed而编译失败，已恢复工程侧类型。完整重跑 `./scripts/check.sh` 退出0：2084项Swift Testing、8项工程Python检查及格式/边界/plist检查通过。`./scripts/build-ios.sh`退出0，五个scheme全部构建成功。未调用真实模型或下载新制品。

本地日志：首次失败 `/tmp/mh-independent-check.log`，修正后完整检查 `/tmp/mh-independent-check-retry.log`，构建 `/tmp/mh-independent-ios.log`。研究侧21项回归单独执行通过；213份历史实验数据哈希不变。
