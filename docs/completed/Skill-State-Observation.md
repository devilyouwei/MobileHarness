# Skill 驱动 State 观察

用户要求移除Assistant重复路径/字段清单。实施前设计：Container的business为公开观察契约；App统一readState按精确路径读取；Assistant适配器仅编码business（保留嵌套结构），Skill.useStates独占范围选择。不遍历children，不披露runtime/health/metadata。本地文件/凭据由生产者公开契约保护。

AgentStateContext增加统一按名resolver，生产装配只安装一次，不逐路径登记。显式source接口继续供独立宿主注入类型擦除数据，非第二份生产清单。来源读取/解码/缺失错误按项返回availability=unknown、value=null及有界diagnostic（路径和固定原因，不泄露异常原文）；取消、closed、容量和代际失效仍终止请求。无状态缓存、重试或隐式设备启动。

更新Assistant/Context/整体设计与Skill说明；回归新增任意路径无需注册、完整business嵌套、缺失与有效来源混合、错误诊断、空集合不读取，以及既有取消/容量/生命周期。执行check.sh与build-ios.sh，独立记录真实模型/设备未验收。

## 完成记录

统一读取、Business投影、单项失败诊断与测试/文档已完成。完整检查、12项专项回归、四项iOS构建通过，见[验证记录](../validation/Skill-State-Observation.md)。真实模型/物理设备交互不在本轮通过证据内。
