# MobileHarness architecture

MobileHarness 以 iPhone 为宿主，将感知、Agent 决策和受控执行连接起来。本文件说明当前协作边界；完整技术流程见 [整体设计](../MobileHarness/README.md)，用户范围见 [Product scope](Product-Scope.md)，术语见 [Concepts](Concepts.md)。

## 主要数据流

```mermaid
flowchart LR
    Input[用户意图 / 原生感知事实] --> Host[AgentBindings 输入适配]
    Host --> In[InputGateway]
    In --> Agents[业务与感知 Agents]
    Agents --> Models[注入的 ModelKit 能力]
    Agents --> Out[OutputGateway]
    Out --> Functions[Actions 业务函数]
    Functions --> Effects[ActionBindings 绑定的 UI / 原生能力]
    Out -->|执行结果和声明的通信| In
    Agents --> Data[注入的 Storage 接口]
    Local[本地导航 / 草稿 / 选择] --> UI[UI 展示状态]
    Effects --> UI
```

图中是运行时流向，不是编译依赖；实际依赖以 [模块与 target 映射](../MobileHarness/README.md#target-map) 为准。

## 模块职责

| 拥有者 | 责任与边界 |
| --- | --- |
| [App](../MobileHarness/App/README.md) | 应用入口、创建、注册、组合、连接及应用级生命周期；通过模块公开接口启停，不承担业务流程或数据转换。 |
| [Agents](../MobileHarness/Agents/README.md) | 解释输入、拥有业务状态与策略，通过获准的函数表达行为；AgentBindings 负责请求/结果适配及角色运行接入。Assistant 是普通对话入口；Memory、Photographer、ApplicationControl 拥有各自确定性事务。 |
| [Gateway](../MobileHarness/Gateway/README.md) | 校验身份与权限、通信和执行准入，协调排序、结果、资源与取消；不选择业务策略。 |
| [Actions](../MobileHarness/Actions/README.md) | 定义协议中立的业务函数、参数、效果和完成/失败契约；ActionBindings 实现原生执行与直接 UI 绑定。 |
| [UI](../MobileHarness/UI/README.md) | 拥有独立展示值、页面导航和本地交互；通过注入接口提交业务操作。 |
| [ModelKit](../MobileHarness/ModelKit/README.md) | 提供独立推理 SDK、模型生命周期及制品管理，不拥有应用决策或设备效果。 |
| [PlatformKit](../MobileHarness/PlatformKit/README.md) | 提供原生音视频、连接、设备协议和真实反馈。 |
| [Storage](../MobileHarness/Storage/README.md) | 提供存储契约、领域记录、内存机制与具体后端；不决定模型或业务流程。 |

## 输入与决策

SpeechPerception 拥有聆听同意和输入准入策略，VisionPerception 提供共享视觉观测，SpeechSynthesis 独立准备语音数据。Assistant 结合自己的上下文、当前 Task 和已加载 Skill 的函数目录进行决策；业务角色不读取其他 Agent 的内部可写状态。

Skill 组织可复用流程及函数绑定，Task 组织持续目标与上下文。实际调用权限由当前作用域与冻结的请求目录验证。Task 是业务组织方式，不是已注册相机函数的额外调用前提。当前角色、固定事务及后台能力边界见 [Agents](../MobileHarness/Agents/README.md)。

本地跳转、展开、草稿和选择直接由 UI/宿主处理。用户提交业务意图交给实际拥有者；Agent 发起的界面控制通过获准的 Action、ActionBindings 和 UI 公开呈现接口执行。

## 执行与反馈

ActionCall 使用任务内 Channel 排序和 wait；原生 ToolCall 直接调用公共函数执行器，不进入 Channel/wait。两者复用协议中立的输入、函数预算、资源约束和结构化完成结果。协议适配细节以 [调用适配器](../MobileHarness/Gateway/Output/Protocols/README.md) 为准。

结果定向返回实际执行者，ReACT 根据真实结果推进；投递接纳、生成结束、函数结束、音频排空、渲染完成与物理到位分别表达。取消会加入所属工作的清理，不推断已经发生的设备效果已回滚。调用失败与结果派送失败分别保留。

## 数据与生命周期

App 选择存储后端和路径，消费者使用注入契约。SQLite 保存已提交的对话、消息、Task、媒体和设备记录；运行时状态与瞬时音频由各自内存所有者持有。完整消息在生产者的完成边界提交，流式片段不逐片落盘；重启恢复记录状态，不重放设备动作。具体一致性、分页、容量与恢复行为见 [Storage](../MobileHarness/Storage/README.md)。

Assistant 决定照片如何进入模型上下文，PlatformKit 提供通用图像处理；保留的原图与模型分析附件分别处理。媒体存在不代表已经导出到系统照片库，临时照片缓存也不等于计划中的用户相册。

长期任务属于根级服务与明确的业务所有者，页面关闭不承担全局停止。App 转交应用生命周期；模块处理具体权限、原生中断和停止清理；物理设备安全不依赖后台持续执行。模型和语音提供者由实际配置及已注册能力决定，本文件不固定某个历史默认。

## 状态与证据入口

当前未完成需求见 [requirements](requirements/README.md)，完整交付归档见 [completed](completed/README.md)，独立验收见 [Roadmap](Roadmap.md#acceptance-work)。历史架构叙述见 [旧说明记录](history/Documentation-History.md)，测试与设备观察见 [验证索引](validation/README.md)。这些历史资料不替代源码 README 的现行契约。

## Storage 生命周期边界收敛

✅ AppStorage 使用实例级 FactoryKit 注册 StorageContainer，组合 State、Cache、Database、Files；AppLifecycle 按 storage → agents → native 启停。数据库实现负责迁移、恢复、接纳和关闭；会话音频使用 Cache 子作用域，配置/照片/模型文件复用 Files。模型制品工作在 Files 释放前加入清理并解除旧绑定。见 [实施计划](requirements/technical/Storage-Containers-Plan.md)。

Storage 四类容器与通用 State 已实施，参见 [计划及验证范围](requirements/technical/Storage-Containers-Plan.md)；Skill useState 每轮公开状态上下文已接通，真实模型/设备验收独立记录。


✅ State 边界已修订：AgentContext 使用私有 actor 内存，公开寄存器只承载有限事实；以 [公开 State 计划](requirements/Resource-State-Plan.md) 为现行范围；历史记录保留此前实现与验收限制。

✅ 页面导航、原生执行中断、对话结束分离。设置页不关闭根服务；后台保留 Assistant 内存及当前目标/Skill，只取消并加入在途执行及安全停止设备；恢复等待新输入，显式结束会话才回收作用域。

✅ 提示词固定规则与本轮事实分离，State 后置且非 user 消息；缓存观察指标透传，不承诺缓存命中或价格，真实 provider 验收独立。


模型响应诊断沿已有错误链传递：ModelKit 在协议边界产生中立类型化原因 → Agent 归类并发布带诊断的终止控制 → Gateway 保留有界失败快照及输入/会话/轮次 → AgentBindings 映射短用户消息与详细日志 → UI 被动显示。错误不触发重试或已执行效果重放；原生调用仍须通过完整终态校验才发布。具体代码与容量见 [LLM](../MobileHarness/ModelKit/Language/LLM/README.md) 和 [Agent 输出](../MobileHarness/Agents/Support/Core/Output/README.md)。

## Skill call protocol migration

✅ Implemented: all bundled Skill functions use Action Call; historical/provider-native Tool infrastructure remains available for explicit non-Skill callers. Read-only queries use Query Channel and real value feedback before dependent decisions.
