# Web Skill 上下文接入修复

日期：2026-11-03。来源：用户真机打开B站，在loadSkills后连续出现agent.context.snapshot / missing。

## 原因与实施前设计

WebBrowsing/WebDrawing声明ui.web，UIContainer也已提供reader，但AssistantStateBindings没有注册该路径。下一次按Skill采集上下文时AgentStateContext抛出missing，浏览Action尚未接纳。既有状态覆盖测试使用硬编码旧Skill列表，未覆盖新增Web技能。

- Agents/Assistant/AssistantStateBindings.swift：显式注册ui.web，仅选择content/url业务事实；保持Runtime不向Assistant披露，不忽略未知路径错误。
- UI/Components/Web/WebPageContainer.swift：被动投影empty/local/remote内容类型和远程URL，本地文件路径不披露；读取不创建WebKit或触发导航，原生就绪/加载指标继续属于Runtime。
- Tests/IntegrationTests/ContainerContextTests.swift：从打包Catalog动态枚举全部Skill；逐项loadSkills后通过真实UIContainer/PlatformContainer和AssistantStateBindings读取有效useStates，验证加载与释放，修复前应复现missing。
- Tests/UITests/WebPageTests.swift：真实本地页面加载后验证content=local、url未知，关闭后为空；不把本地路径带入状态。
- 同步Assistant、UI/Web、Context与测试README。无模块依赖或跨层职责变化。

## 验证与交付

复现回归→修复→定向测试→完整check.sh→build-ios.sh→真机签名构建、原位安装与启动。记录真实LLM和B站内容交互仍需实际验收；不将替身模型或安装成功等同完整业务成功。

## 交付记录

已完成修复、3项定向回归、完整check.sh、四项iOS构建，以及真机2026110305原位安装和启动。实际B站页面及真实模型交互仍需用户重试确认，未冒充验收。详见[验证记录](../validation/Web-Skill-State-Fix.md)。
