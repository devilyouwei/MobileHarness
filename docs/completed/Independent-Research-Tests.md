# Tests 与 experiments 独立边界

两者仅按路径/版本/校验和约定读取根 Models 的下载制品，不互相导入源码、读取数据/配置或复用辅助库。允许各自实现相似逻辑。Models 只接收 Hugging Face 或其他 URL 下载的模型制品，不成为共享业务代码目录。

删除 Swift 中读取实验矩阵的检查和加载器；工程 smoke 保持内嵌独立 case。研究运行器的 Python 回归移入各任务或 experiments 根，独立运行。scripts/models 的工程参考检查使用自身适配器/清单，删除由实验结果生成工程夹具的旧工具，既有冻结工程夹具独立保留。实验 benchmark 移除对仓库下载库的导入，制品统一通过显式下载工具准备到 Models。

同步 CONTRIBUTING、双方 README、Models 和脚本清单；修正残留旧耦合说明。验证双方无活动交叉依赖、研究 Python 回归、完整 check.sh 与 iOS 构建，不改历史证据中的来源记录。使用既有目录，不新建目录。

已完成；执行结果和首次编译失败修正见[验证记录](../validation/Independent-Research-Tests.md)。
