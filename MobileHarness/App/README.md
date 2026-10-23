# App — 应用入口与组合根

✅ App 注册并持有唯一 ModelContainer，注入四子能力并通过现有生命周期图管理启动、失活、恢复和停止；业务不查询注册容器。

✅ 快速 inactive → active 也保留一次必须执行的非前台清理，已启动服务全部完成暂停后再恢复前台接纳；页面覆盖不发送 Scene 生命周期。

## 职责与边界

App 只负责入口、创建、注册、组合、连接及应用级生命周期。业务流程、数据转换、领域状态、用户错误文案、页面实现和功能工作者由所属模块拥有；App 可组合这些已有页面；注入闭包只连接公开接口。

## 直接上下游

```mermaid
flowchart TB
 OS[iOS / Scene / 系统回调] --> App
 Configuration[资源位置和模块声明] --> App
 App -.->|创建、注入、启停| Agents
 App -.->|创建与注册| Actions
 App -.->|服务图管理| AppLifecycle
 App -.->|后端与原生实例| Foundations[UI / PlatformKit / Storage]
 UI -->|注入的业务请求接口| Agents
 Agents --> Gateway
 Gateway --> Agents
 Agents -->|函数请求| Gateway
 Gateway --> Actions
 Actions -->|公开呈现及能力接口| Foundations
```

App creates and connects unique roots and manages lifecycle. Agents and Actions each own their complete implementation target; there is no outer binding target. Runtime UI/media/fact input goes directly to the responsible Agent, while business execution retains Gateway and Actions.

## 内部结构与数据流

```mermaid
flowchart TB
 Entry[MobileHarnessApp] --> Composition[AppComposition]
 Composition --> Factories[ServiceFactories]
 Composition --> Registration[ModuleRegistration]
 Composition --> Connections[connect: 公开端口接线]
 Factories --> Services[Services: 实例与根作用域]
 Registration --> Lifecycle[ApplicationLifecycle]
 Entry -->|系统生命周期| Lifecycle
 Services --> Lifecycle
 Lifecycle -->|启停、失效及完成| Ports[模块公开生命周期接口]
```

- MobileHarnessApp 挂载 UI.ApplicationRootView，转交 Scene 活动状态；导航、设置/历史目的地及诊断页面由 UI 实现。
- [Composition](Composition/README.md) 创建实例并安装静态服务图；重试先加入旧图停止，再创建新作用域。消费者不查询 App 容器。
- [Lifecycle](Lifecycle/README.md) 管理通用顺序、启动回滚、前台状态与停止加入，并转交 OS URL-session 回调。

## 接口与失败

根图为 diagnostics → storage / platform / ui → agents → native。具体服务内部的 Agent 注册、配置事务、采集/播放、相机处置、蓝牙恢复和展示由模块实现。App 只调用公开方法，错误原样交给 UI 请求适配器的启动失败端口。

AppLifecycle 验证有限静态依赖图，保留原始启动错误及全部服务清理错误。后台先同步失效，再等待异步暂停/清理；取消和物理停止分别确认。停止失败阻止新图替换。模块根任务独立于页面；物理安全不依赖后台任务额度。

✅ 前台启动：初始 inactive 只等待 active；启动中失活引起的取消在成功回滚后由下一次 active 重建作用域。业务与清理错误不被隐藏。

## 当前实现

✅ 代码已迁移至上述边界，静态边界、专项回归及未签名 iOS 设备目标编译通过。❌ 全量回归和 Simulator 构建仍有单独记录的失败/限制，不作为通过。实现与验收记录见 [实施计划](../../docs/requirements/technical/App-Host-Boundaries-Plan.md) 和 [验证记录](../../docs/validation/Validation-History.md)。

## Storage 生命周期收敛

✅ ServiceFactories 只调用 ApplicationContainer 创建未启动的 StorageContainer，注入延迟领域仓库接口。ModuleRegistration 注册 diagnostics → storage / platform / ui → agents → native，绑定 start/stop；不再创建数据库目录、执行恢复或注册空停止。重试等待旧 Storage 关闭成功，业务终态写入先于存储停止。Scene 非活跃不关闭存储。

## 待实现

- 多窗口独立运行命名空间、非合作原生 handler 的强制中断，以及独立的真实模型/原生 UI/物理设备验收。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

AppStorage 目标只编译 Composition/ApplicationContainer.swift，使用 FactoryKit 实例内缓存；业务目标不导入 IoC。Services 持有注册容器、StorageContainer、PlatformContainer 和 UIContainer，连接所需子接口。模型后台事件只转交 ArtifactServices；存储停止前先加入其制品清理。

## 公开 State 边界

✅ App 只创建并注入 Storage 根及子能力、调度生命周期。公开 State 声明、事实转换与会话投影由业务模块/集成拥有者安装；App 不维护 Camera/Robot/Task 业务字段。

[公开 State 契约](../Storage/State/README.md)


## UI 容器与相机能力注入

✅ App 注册 UI 根及相机子能力，提供唯一 CameraCoordinator 工厂，注入相机与 UI 呈现接口及延迟 Agent 接入回调。App 不转换帧或 Pose；生命周期图为 storage/platform/ui → agents → native。


## UI 全量容器化

✅ 应用级 UI 状态由八个子容器统一创建，消费者注入所需 Presenting 接口并提交 UI 自有值，不直接写字段。App 注册并管理同一 UI 根；原业务身份/版本校验、原生完成和基础库依赖边界保持。当前跨模块链路见总体设计；设备和性能验收单独记录。

✅ 已实现：App新增首页模型准备的宿主生命周期编排例外，通过公开状态／warmup／load接口组合当前能力；不推理业务请求、不下载制品或转换Signal。

✅ Xcode 源码导航恢复 ModelKit Management 组，移除已删除 CurrentChatCapability 的组引用；编译源码仍由 SwiftPM 目标拥有。


## Direct container contract

App creates shared foundational roots and injects public role/execution capabilities. It performs no external Signal encoding or per-frame forwarding. Current cross-module ownership is defined by the [overall design](../README.md).

✅ App 注入实际 UI 子容器；UI 业务事件订阅、处理和回执由 Agent 生命周期拥有。装配层保留页面交互能力构造及提交端口，不订阅、解释或向执行会话转交 UI 输入。

✅ App 组合已有 UI 页面并实现 UI 自有根／会话展示协议，不创建业务订阅或转换业务结果；角色策略与执行属于 Agents／Actions。
