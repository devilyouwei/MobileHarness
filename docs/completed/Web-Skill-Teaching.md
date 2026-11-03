# Web Skill 教学优化

2026-11-03。按用户要求，参考Photography、HistoryQuery、ApplicationControl与BasicSkill的现行教学，优化web-browsing/web-drawing。

## 实施前范围

- 保留两个Skill的ID、依赖、Action绑定、Channel及useStates；不改状态注册、missing处理、Action实现或模型配置。
- Instructions.md按用途、当前事实、流程/真实反馈、Task/窗口收尾、异常与独立响应示例组织。通用加载与Task控制规则继续由BasicSkill拥有，避免把一次浏览/创建强制变成持续Task。
- 浏览教学明确browse自动打开窗口且已经返回截图、inspect与snapshot按证据缺口选择、长网页逐屏观察、无自动点击/输入能力、只读未知状态不等于必须先查询或不能打开。
- 绘图教学明确文字任务包含结果目标和保留项；创建省略projectID，修改复用真实ID；不把windowID/mediaID/revision当项目ID，不在主上下文生成代码；成功后的具体修正与失败重试分开。保留作品窗口作为成果，关闭不等于删除。
- 示例使用实际XML别名与参数，依赖反馈分到下一请求，假设ID明确标注；递增revision至2并优化发现描述。
- 同步Resources/Skills/README.md；Tests/IntegrationTests/PromptTemplateTests.swift通过生产解析器验证新示例及已加载Web提示预算，不以关键词匹配当模型行为验证。

## 验证

定向运行示例解析、Skill目录/状态加载与提示预算回归；执行完整check.sh、build-ios.sh并核对打包资源。此轮不调用真实模型；不将静态教学和协议验证等同真实模型遵循度。修改保留工作区无关窗口/相机改动。

## 完成记录

两个Skill已按本计划完成revision2教学、发现描述、文档及示例解析/预算回归。定向测试、完整check.sh、四项iOS构建与打包资源校验通过，详见[验证记录](../validation/Web-Skill-Teaching.md)。未改状态失败契约，未重新安装真机或宣称真实模型遵循度验收。
