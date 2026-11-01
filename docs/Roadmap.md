# Delivery roadmap

路线图只导航当前未完成需求与独立验收事项。已交付能力见 [Product scope](Product-Scope.md)，技术行为见 [整体设计](../MobileHarness/README.md)，完成的原需求见 [completed](completed/README.md)。

## Future implementation directions

| 分类 | 当前范围与正文来源 |
| --- | --- |
| [技术需求](requirements/technical/README.md) | 四项架构改进中，公开 State 基础与首批 useState 已实现；更多事实、统一错误处理和 App 端到端验收仍待完成；存储接口子项已完成，整份需求保持开放。 |
| [产品需求](requirements/product/README.md) | “用户”板块的独立相册和日记式记忆，以及多云端模型管理、WebKit HTML 呈现和持续聆听/打断判断。 |
| [交叉需求](requirements/README.md#技术与产品交叉需求) | 公开 State 的后续治理/验收、摄影构图与运镜、[Face 窗口与 App 内灵动岛](requirements/Face-Window-Island-Plan.md)（窗口/拍照、双用途共享采集及镜头准入已实现并通过自动化和构建、已安装真机；倒计时/闪光灯/变焦、有声录像及相册处置已实现并安装2026110110，真机验收待完成；独立App内灵动岛、更多页面窗口化及完整实测待续）。 |
| [待细化方向](requirements/README.md#其他待细化方向) | 更多模型能力、原生事件交互、快慢认知和多窗口等；细化前先核对当前实现。 |

需求范围与验收标准只在需求正文维护，本页不重复副本，也不从早期“待做”记录推断今天仍然缺失。原范围全部完成才整份归档；后续独立修复和扩展另行跟踪。

## Acceptance work

| 验收领域 | 仍需按实际版本记录的证据 |
| --- | --- |
| 连续语音 | 中文/英文识别与合成、首次音频、播放衔接、打断/重启、路由变化、内存与热状态；流程见 [Voice](validation/Voice.md)；BasicSkill 退出意图命中、麦克风实际关闭及长按恢复另按 [聆听 Actions](validation/Listening-Actions.md) 实测。 |
| 提供者与模型 | 真实配置、模型资源版本、下载/切换、错误恢复与本地/云端结果；入口见 [验证索引](validation/README.md)。 |
| 原生界面与生命周期 | 当前设置/历史展示、导航、可访问性、页面离开、前后台与迟到回调；编译或静态预览不能代替原生交互。 |
| 机器人与连接 | 目标硬件/负载下的 BLE 通信、真实动作/反馈、断连、接管与停止；单包云台跟踪与首次肩/肘水平准备仍需 motor 4、水平位真实到位、2.2 速度比例、真实视觉与持续运行验收（[ADR0215](adr/0215-nexarm-aim-one-shot.md)、[ADR0216](adr/0216-nexarm-tracking-level-rest.md)）；已有 [USB/BLE 实测](validation/NexArm_Physical_Acceptance.md) 和 [原始数据](measurements/README.md) 不泛化到其他环境。 |
| 流式执行与清理 | 在实际模型输出、播放和设备效果下检查等待、部分失败、取消及晚到结果。 |

各次通过、失败和未执行范围以 [验证记录](validation/Validation-History.md) 为准；上表是验收维度，不表示所有版本均未测试，也不抹去已有的有限验收。

## Historical roadmap

早期实施阶段、旧默认、当时的待办和构建结果保留在 [Milestone history](history/Milestone-History.md)，不再混入当前交付清单。本文不设交付日期或物理安全认证结论。

完整待办统一见 [需求汇总](requirements/README.md#全部待办汇总2026-10-24)。


## 2026-10-25 需求核查与分支实施计划

本次核对 requirements、当前源码 README 与 Provider 验证记录；未重新运行代码、模型或设备测试。已有架构迁移不重复开发。旧计划的全量失败/CoreAI 阻断属于对应版本证据，不能直接认定当前仍失败；近期 Provider 四目标构建通过也不能抹去旧失败或代替全业务验收。

### 功能缺口

| 功能 | 当前结论 | 待交付 |
| --- | --- | --- |
| 多 Provider | ✅ 列表、名称、modal 增删改选、持久化、钥匙串、HTTP/IP、空 URL 默认已实现；已有 Ollama Responses 真实协议验证 | ❌ 原生操作及重启、错误 Key/断网、真实在途切换、多个服务端到端验收；URL 唯一，同服务多独立模型配置仍需核对产品语义 |
| HTML 富内容 | ❌ 待实现 | UI 中立 WebKit 组件、受控脚本/网络、更新关闭与错误恢复，Actions/Gateway 业务接入 |
| 持续语音打断 | ✅ 常驻策略、VAD/ASR、半双工；❌ barge-in | 回复期间判断、回声/噪声抑制、取消并等待清理、句首保留及新轮交接 |
| 用户相册 | App 相册支持照片/视频收录、分页、回放、导出和删除；录像链路已实现 | 原生录制/收音、回放/导出及保留删除行为的真机独立验收 |
| 用户记忆 | ✅ 历史事务和标题；❌ 日记式记忆 | 增量摘要/关键词、embedding、版本和来源索引、周期补做与页面；活跃历史事务恢复也需独立细化 |
| 智能摄影 | ✅ 姿态观测、相机操作、NexArm 瞄准 | ❌ 意图到构图策略、主体跟随、运镜、完成判断和失联/接管/停止验收 |

### 技术缺口

| 类别 | 剩余范围 |
| --- | --- |
| State | 更多事实、Trigger、完整写入源治理；camera/robot/task 与 useState 已完成，不重做 |
| 错误体验 | 全局稳定分类、用户文案与诊断分层、脱敏/限长、取消和部分失败、Toast 代际与合并 |
| 模型能力 | 生产 embedding、judgment、通用视频会话、跨模型公平/热调度尚未实现；按具体功能需求接入，避免提前通用化 |
| 原生可靠性 | 预览黑屏待复现定位；Metal 持续挂载/重启、采集暂停、语音开启延迟、BLE 重连与停止等需按当前版本验收 |
| 集成质量 | App/Storage/PlatformKit/Agent 容器代码迁移已实施；全量失败重跑定位、当前 Simulator 依赖核对、模型/UI/物理验收与性能采样未全部关闭 |
| 待定义方向 | Agent-driven 剩余接入、原生 Tool 事件、快慢认知/算力路由、活动监督、多窗口；尚不能当成可直接实施的明确 feature |

### 逐分支交付顺序

以下为建议执行顺序，不自动创建分支或承诺日期。每支从最新合并基线开始，保持可独立评审；大项各子支分别合并。沿用现有目录；确需新目录时先说明归属、替代方案和关系并取得用户明确批准。

| 顺序 / 分支 | 范围及完成门槛 | 依赖 |
| --- | --- | --- |
| 0 `codex/current-baseline` | 固定当前版本，重跑检查与四目标构建；核对旧失败、Provider 状态、预览黑屏复现；产出当前缺陷及设备验收基线。确认黑屏后独立 `codex/camera-preview-fix` 修复 | 无 |
| 1 `codex/provider-acceptance` | 关闭多配置语义差异、原生表单与真实请求失败/切换验收，更新需求状态；服务配置需使用已授权凭据 | 0 |
| 2 `codex/error-presentation` | 统一错误展示契约和关键语音/相机/设备/模型路径，覆盖取消、部分失败、敏感信息和迟到错误 | 0 |
| 3 `codex/speech-barge-in` | 在已有语音角色扩展；设计时先确定误触发/漏检与停止延迟门槛；真机声学验收通过才声明可用 | 2 |
| 4 `codex/html-presentation` | 中立组件加业务调用全链路，验证脚本权限、超限、渲染退出、连续更新与关闭清理 | 2；可与语音独立推进 |
| 5a `codex/photo-album` | 作品长期保留、来源和图片页面；明确这是相册部分交付，不提前归档含视频原需求 | 0、2 |
| 5b `codex/video-capture` | 原生录制到存储/缩略图/播放/来源、失败与收尾；补齐相册原需求 | 5a |
| 6a `codex/memory-embeddings` | 真实 embedding 类型化能力、存储/来源/版本契约与迁移；模型不支持明确失败 | 1、2 |
| 6b `codex/diary-memory` | 有界增量整理、恢复补做、删除失效、时间线与来源跳转，验证真实摘要和检索质量 | 6a |
| 7a `codex/photography-composition` | 单主体静态构图和拍照闭环，目标/反馈/未知分离、丢失停止、手动接管 | 相机基线、5a、目标设备停止验收 |
| 7b `codex/photography-follow` | 移动跟随与运镜，先定义运动/新鲜度/完成门槛，实测失联及物理停止 | 7a |
| 8 `codex/state-triggers` | 从已交付场景选择事实与触发，明确唯一写入源、触发授权、去重/限频/容量和重启行为 | 实际场景需求；不是前述功能的统一阻塞项 |

每个代码分支：先更新拥有目录 README（跨模块先更新总体设计），实现并清除替代路径，执行 check.sh 和可用的 build-ios.sh；报告实际通过、失败与未执行项。行为变化增加有意义的回归测试。真实模型、原生 UI、物理动作和功耗/内存/热状态独立记录，不能用构建代替。必要验收未完成时保留需求开放。每个阶段收尾再决定下一支，不创建后台自动任务或自动合并。

- Container reflexivity: implementation and acceptance are tracked in [the technical requirement](requirements/technical/Container-Reflexivity.md); [validation evidence](validation/Container-Reflexivity.md) separates automated/build results from native/model/device acceptance.
