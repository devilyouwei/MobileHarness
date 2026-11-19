# Research 与工程贡献边界

在根 README 增加 experiments、Tests、Models 的职责表和贡献入口；CONTRIBUTING 明确按任务保存黑盒评估、按模块验证软件契约、按模型共享制品。区分提示词/模型效果评估与确定性提示词构造/解析测试，规定 researcher 的数据集/对照/结果记录和 engineer 的回归/失败检查入口。仅修改文档，验证链接和 diff，无须构建。

已完成：根 README 提供职责表，CONTRIBUTING 提供执行规则；新增路径与贡献锚点核对通过，git diff --check 通过。仅文档修改，不运行构建。全量 README 链接扫描发现既有 MobileHarness/Resources/Models/README.md 缺失，本次未修改该引用。
