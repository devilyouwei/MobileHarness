# 产品需求

本目录只收录尚未实现的用户场景、功能和页面需求。以架构机制为主的需求归 [技术需求](../technical/README.md)，难以拆分的交叉需求归 [requirements 根目录](../README.md#技术与产品交叉需求)。

| 需求 | 文档与范围 |
| --- | --- |
| 用户相册 | [相册需求](User-Album-Memory-Plan.md#1-用户相册)：在“用户”板块提供独立页面，展示摄影产生的图片、视频及来源；[扩展范围](User-Album-Memory-Plan.md#3-扩展范围摄影组件影像理解与自然语言检索)含 Skill／LLM 摄影、首页组件窗口方向、影像分析与自然语言检索。 |
| 用户记忆 | [记忆需求](User-Album-Memory-Plan.md#2-用户记忆)：同板块独立页面，按时间周期性增量整理摘要、关键词、embedding 和原始对话索引。 |

两项与“Agent 记录”并列，技术约束随产品需求一起保留，不改变其产品分类。现有 JPEG 或历史记录基础不代表上述页面与完整能力已经实现。

部分完成时保留整份需求并更新状态；原范围全部完成后整份迁入 completed，更新当前设计和验证记录。分类及维护规则见 [需求总索引](../README.md)。

## 新增交互需求

[Assistant 聊天首页与眼睛形态](Assistant-Chat-and-Face.md)涵盖双方对话记录、键盘输入以及同一会话中的聊天与 Face 切换。

[预置基础小工具](Built-in-Utilities.md)涵盖记事本、闹钟和时钟窗口。页面导航与 AI 主动交互统一遵循[用户导航与 AI 交互边界](../Manual-Navigation-and-Agent-Interaction.md)。

[录制 Assistant 的名字作为唤醒词](Assistant-Name-Wake.md)涵盖在语音设置中录制名字、本地保存 Zipformer 特征模板，以及在 `quiet` 下匹配录音特征并进入全双工。

[Assistant 播报的两级声学抑制](Assistant-Speech-Energy-Suppression.md)涵盖起声确认后按外部语音能量降低播报音量、暂停及续播。

[闹钟与倒计时](Alarms-and-Timers.md)涵盖通过 Assistant 设置、查询和取消闹钟或倒计时，以及由 iOS 到期提醒。

[多云端模型、HTML 呈现与持续语音感知](Model-Web-Speech-Plan.md)：三项独立需求分别跟踪；WebKit浏览/截图和独立模型绘图功能已实现，实施与验证见[交付归档](../../completed/WebKit-Actions-Plan.md)，模型配置与持续语音验收保留原范围。
