# Delivery roadmap

路线图只导航当前未完成需求与独立验收事项。已交付能力见 [Product scope](Product-Scope.md)，技术行为见 [整体设计](../MobileHarness/README.md)，完成的原需求见 [completed](completed/README.md)。

## Future implementation directions

| 分类 | 当前范围与正文来源 |
| --- | --- |
| [技术需求](requirements/technical/README.md) | 四项架构改进中，公开 State 基础与首批 useState 已实现；更多事实、统一错误处理和 App 端到端验收仍待完成；存储接口子项已完成，整份需求保持开放。 |
| [产品需求](requirements/product/README.md) | “用户”板块的独立相册和日记式记忆。 |
| [交叉需求](requirements/README.md#技术与产品交叉需求) | 公开 State 的后续治理/验收、摄影构图与运镜。 |
| [待细化方向](requirements/README.md#其他待细化方向) | 更多模型能力、原生事件交互、快慢认知和多窗口等；细化前先核对当前实现。 |

需求范围与验收标准只在需求正文维护，本页不重复副本，也不从早期“待做”记录推断今天仍然缺失。原范围全部完成才整份归档；后续独立修复和扩展另行跟踪。

## Acceptance work

| 验收领域 | 仍需按实际版本记录的证据 |
| --- | --- |
| 连续语音 | 中文/英文识别与合成、首次音频、播放衔接、打断/重启、路由变化、内存与热状态；流程见 [Voice](validation/Voice.md)。 |
| 提供者与模型 | 真实配置、模型资源版本、下载/切换、错误恢复与本地/云端结果；入口见 [验证索引](validation/README.md)。 |
| 原生界面与生命周期 | 当前设置/历史展示、导航、可访问性、页面离开、前后台与迟到回调；编译或静态预览不能代替原生交互。 |
| 机器人与连接 | 目标硬件/负载下的 BLE 通信、真实动作/反馈、断连、接管与停止；单包云台跟踪与首次肩/肘水平准备仍需 motor 4、水平位真实到位、2.2 速度比例、真实视觉与持续运行验收（[ADR0215](adr/0215-nexarm-aim-one-shot.md)、[ADR0216](adr/0216-nexarm-tracking-level-rest.md)）；已有 [USB/BLE 实测](validation/NexArm_Physical_Acceptance.md) 和 [原始数据](measurements/README.md) 不泛化到其他环境。 |
| 流式执行与清理 | 在实际模型输出、播放和设备效果下检查等待、部分失败、取消及晚到结果。 |

各次通过、失败和未执行范围以 [验证记录](validation/Validation-History.md) 为准；上表是验收维度，不表示所有版本均未测试，也不抹去已有的有限验收。

## Historical roadmap

早期实施阶段、旧默认、当时的待办和构建结果保留在 [Milestone history](history/Milestone-History.md)，不再混入当前交付清单。本文不设交付日期或物理安全认证结论。
