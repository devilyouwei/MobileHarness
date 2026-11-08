# 按意图发现 Skill，避免把未加载误判为不支持

2026-11-08。用户反馈：要求“浏览 b 站”时，Assistant 未加载浏览 Skill，直接回答没有能力。

## 范围与设计

用户进一步明确：BasicSkill 只教通用能力发现，不放浏览 B 站等业务例子。本次修订移除 BasicSkill 的浏览、摄影、历史查询具体示例及网站专用措辞，以“当前能力不足→查阅 AVAILABLE SKILLS→按描述选择并加载→成功后执行”为明确规则。只有目录无相关能力且无可委托 owner 时，才可说明未提供该能力；加载/执行失败描述具体阻塞，不混同为能力不存在。已有 Task/Skill 与委托边界保持。WebBrowsing 公开描述也去掉站点名示例。

原网站示例测试改为动态枚举所有非基础 Skill，检查默认可发现、加载后获得私有教学/函数、旧目录不变；Task 初始 Skill 回归改用测试侧数据，不依赖 BasicSkill 业务示例。业务情境只留在专项 Skill 和评估数据中。同步当前 README 并保留上一轮验证的历史边界。

模型复验采用已有跨能力冷启动场景（相机、机械臂、网页）及已加载/无需执行边界，验证通用规则而非只看站点案例；仍区分真实模型决策与合成执行反馈。

首轮通用教学真实 Qwen 回归通过 5/7：相机请求主动加载但夹带解释文本，机械臂请求用已有表情替代了所需动作。继续只修订通用规则：选择函数必须匹配用户要求的实际效果，不得用语义不匹配的已加载动作替代；加载轮只输出一个控制 Action，不带解释。递增 BasicSkill revision，不增加业务示例或业务关键词分支，复验失败及代表性通过场景。

已确认默认请求包含 AVAILABLE SKILLS，web-browsing 已注册；详细浏览教学仅在加载后可见。修复常驻的发现教学，不预加载全部 Skill，不增加关键词路由或绕过冻结目录。

- `Resources/Skills/BasicSkill/Instructions.md`：先按用户目标和公开 description 判断能力归属；区分已加载、可加载及未提供能力。缺少当前 Action 不等于不支持；有匹配 Skill 时先加载再读取其私有教学。单次工作使用 loadSkills，新持续目标保持 task.start(skills)，同行拥有的目标仍直接委托。事实已足够时直接回答，失败后不重载循环，不虚构能力。
- `Resources/Skills/BasicSkill/Skill.json`：递增 revision。加载前教学只描述通用流程，不硬编码业务 Skill ID。
- `Resources/Skills/WebBrowsing/Skill.json`：公开 description 写清网站名/URL 的访问意图及实际操作边界，递增 revision；保持所有函数绑定和依赖。
- `Tests/IntegrationTests/PromptTemplateTests.swift`：从默认请求验证发现信息，解析测试侧加载调用并提交真实 Skill 状态，检查下一请求的函数/私有教学，以及旧目录不被扩大；覆盖全部非基础 Skill。
- `Tests/AgentModelEvaluationTests/Scenarios/qwen-workflows.json`：新增未预载浏览、已预载不重载、普通知识问答及不支持操作边界的合成模型场景。断言不进入模型输入。
- `Tests/IntegrationTests/QwenWorkflowEvaluationTests.swift`：为 Web.browse 提供明确标注的合成网页文本回执及失败，成功时同步合成 ui.web content/url，覆盖加载→访问→反馈，不请求真实网站、不伪造截图或媒体编号。
- 更新 `Resources/Skills/README.md`、相关测试 README；模块边界、跨模块流程和运行时实现不变，无需新目录。

## 验证计划

运行定向测试、`./scripts/check.sh` 和完整 Xcode 可用时的 `./scripts/build-ios.sh`。使用已有 Qwen 评估入口做有界真实模型回归，仅使用其已有本地配置；不输出凭据。保留失败，区分真实模型决策与合成网页反馈。真实 B 站/WebKit/手机验收独立记录，不能由合成反馈替代。

## 进度

后续 BasicSkill revision 50 按概念/控制效果重组教学，完整检查和构建通过；实模中的点头能力选择失败仍保留，详见[控制教学计划](BasicSkill-Control-Teaching.md)及其验证报告。

通用教学、公开描述、全部非基础 Skill 回归与模型场景已实现；BasicSkill 无业务示例/业务 Skill ID。六项定向测试通过。全仓检查仍有六个存储相关失败，原生阶段因共享构建锁未执行；revision 48 的四目标构建通过。revision 49 实模复验相机与网页加载通过，但机械臂请求仍被替换为表情；泛化问题未全部解决，保持本需求未归档。两轮模型证据及验证范围见[验证记录](../../validation/Skill-Discovery-Before-Denial.md)。
