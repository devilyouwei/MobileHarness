# Tests 源码语言归属

Tests 保持 Swift 工程测试及夹具/说明；8个Python工具回归、参考检查与夹具生成脚本迁至现有scripts，保留18项离线回归。同步Python根定位、夹具输出位置、check入口、Package排除清单和Xcode引用，更新所属README。验证Python回归、语法、路径和diff；Swift源码/target不变。

已完成8项迁移；18项Python离线回归、语法、shell语法、Package格式、文档链接和diff检查通过。Swift测试源码与target依赖未改动，本轮未重跑Swift全量测试与iOS构建；既有全量失败见Research-Engineering-Responsibilities验证记录。
