# Application Composition

✅ 组合根移除准备手动取消接线；准备复查未就绪通过同根异常通道上报原始验证错误，ModelKit 已报告的加载／查询错误继续走既有通道，不重复生成 Toast。

✅ ApplicationContainer 缓存 ModelContainer 并返回同根 language／speech／vision／artifacts。模型服务依赖 storage／diagnostics；Agents 依赖 model，消费者停止后再关闭模型和存储。

## 职责与接口

只创建、持有和连接模块实例，安装模块公开声明及生命周期描述。不接收业务请求、不转换业务数据，也不决定模型/相机/语音/设备业务规则。

## 组件与关系

| 文件 | 职责 |
| --- | --- |
| ApplicationContainer.swift | AppStorage 内的 Storage/Platform/UI/Model 根、子能力及容器故障通道注册 |
| AppComposition.swift | 持有当前 Services 和生命周期图，连接 UI bootstrap/retry/failure 端口；显式重试替换整个根作用域 |
| ServiceFactories.swift | 选择 Storage 运行工厂和数据库位置，获取原生能力、创建照片工厂、模型制品服务及 Agent 集成入口；注入延迟领域仓库接口 |
| ModuleRegistration.swift | 注册 diagnostics → storage → model；platform / ui / model → agents → native 的静态依赖与公开启停/失效接口 |

配置中的资源路径属于组合输入。照片容量/FIFO、Provider 事务、模型选择、页面控制、意图编码和结果转换属于模块；App 不在绑定闭包中复制这些逻辑。

## 生命周期与失败

✅ 只有 Scene active 开启服务接纳；inactive/background 仍立即失效。初始作用域在 inactive 仅等待 active，不将正常等待当作启动失败。系统在启动中离开 active 后，清理成功的 suspended 图在下一次 active 由组合根停止并重建；一个替换任务合并重复事件；结束时按最新前台状态检查是否仍需恢复，不积累重建队列，不重放业务操作。启动错误和清理错误仍通过现有错误端口显示，手动重试规则保留。


StorageContainer 在自己的后台启动任务中完成后端打开、迁移和恢复，成功后才发布仓库；App 通过 start 等待结果并按依赖顺序开放业务接纳。模块内部服务工厂返回明确端口；不存在全局 App 查找。

一个替换任务，没有重试队列；重复重试合并。旧图停止完成后才创建新实例和 scopeID。清理失败保留旧图和错误，不启动替代原生所有者。持久化设置/记录和媒体由仓库保留，不重放操作。

[App](../README.md) · [生命周期](../Lifecycle/README.md) · [Agent 集成](../../Agents/Support/README.md) · [Action 集成](../../Actions/Support/README.md)

✅ Services 持有 storage: StorageContainer；工厂持有独立 ApplicationContainer 并选择根 URL，注入领域仓库提供器。注册实际 storage.start/stop 与 diagnostics → storage → model；platform / ui / model → agents → native 依赖；不调用 SQLiteRepositories、FileManager 或恢复。

## 待实现

- 多窗口实例隔离；强制中断非合作依赖仍不可用。

## Storage 依赖

✅ 存储访问使用独立的 State、Cache、Database 和 Files 接口；App 注册根实例，消费者通过构造器获得所需能力。存储容器不接管本目录的业务验证、执行和完成语义。

AppStorage 目标只编译 Composition/ApplicationContainer.swift，使用 FactoryKit 实例内缓存；业务目标不导入 IoC。Services 持有注册容器、StorageContainer、PlatformContainer、UIContainer 和 ModelContainer，连接所需子接口。模型后台事件只转交 model.artifacts；模型根停止加入制品后再停止存储。


## UI 容器与相机能力注入

✅ ApplicationContainer 缓存 UI 根及相机子能力，AppStorage 显式依赖 UI。Services 持有 UIContainer；ServiceFactories 定义唯一 Coordinator 工厂，AgentApplication 只在原有惰性时机调用它。ModuleRegistration 注册 ui 生命周期，Agents 依赖 storage/platform/ui/model。


## UI 全量容器化

✅ ApplicationContainer 缓存唯一 UIContainer，并将八个子能力注册为根属性的别名，不单独缓存备用实例。ServiceFactories 显式传入设置初值，再注入界面状态和所需呈现能力；不在 App 创建状态或逐帧转发。生命周期继续使用 diagnostics → storage/platform/ui → agents → native，业务消费者先停再停 UI，重试创建新根。

✅ AgentApplication 注入同根相机呈现端口供点击请求忙碌/提示投影，仍共用页面 CameraState，不创建备用根。

✅ 后台 URLSession 可以在前台生命周期启动前准备同根制品；组合根记录该作用域已被使用，重建时在生命周期停止后显式加入幂等 model.stop/storage.stop，避免未加入 started 列表的后台所有者泄漏。后台准备不启动相机、音频、UI 或推理。

✅ 已实现：Services持有唯一ForegroundPreparation协调器；App在生命周期前台屏障完成后、首页可见时激活。绑定导航／配置应用／交互结束的刷新回调；切页或失活立即取消接纳，根替换先加入协调器再停止模型。步骤串行、重复请求合并，准备检查已就绪状态；云端不发探测生成请求，相机开启时才准备视觉。

✅ 已实现：四根注入同一原生错误签名；App 仅标识模型生命周期拒绝为不广播的控制结果，Gateway保留原始 Error。


✅ ApplicationContainer.failureDetails只投影四种模块自有Failure的稳定code及isCancellation，交给同根Gateway报告通道；模型生命周期拒绝保留不广播，真实清理失败例外。ModuleRegistration在保留结构化诊断后，将无清理失败的取消转换为通用宿主CancellationError以保持生命周期语义，不决定业务展示。


✅ 准备状态投影同时更新UI交互门并向Agents报告loading／idle事实，App不直接设置表情；已有会话延后冷准备，终态／失活立即清理展示。

✅ 已实现：模型准备事实仅在 preparing 投影 loading，checking 投影 idle，返回首页仅检查已加载能力时不触发加载表情。

✅ 已实现：首页步骤从 ModelKit 接收实际权重加载开始／结束，不再把调用 prepare 本身当作加载；检查、已就绪、无需挂载不投影 loading。


## Direct container contract

App creates shared foundational roots and injects public role/execution capabilities. It performs no external Signal encoding or per-frame forwarding. Current cross-module ownership is defined by the [overall design](../../README.md).

✅ App 注入实际 UI 子容器；UI 业务事件订阅、处理和回执由 Agent 生命周期拥有。装配层保留页面交互能力构造及提交端口，不订阅、解释或向执行会话转交 UI 输入。

## 语音执行归属收敛

✅ 已实现：唯一根及能力装配保持；语音执行在 Actions 创建和持有，感知角色仍接收同根只读原生端口；生命周期停机先取消加入执行和角色，再释放基础根。

✅ ApplicationPresentation 实现根 UI 协议，内部 SessionPresentation 实现会话展示协议，组合历史／诊断页面并连接导航回调；语音能力由 Agents 注入，App 不持有感知任务。会话展示对象按语音会话实例复用，只组合已有状态、请求端口和页面，不订阅或转发输入。


## Actions 接入契约

Actions 按业务能力组织源码，保持原编译目标。生产调用显式连接独立相机、语音、UI 呈现和 Task 端点；不通过无关能力的类型转换探测。验证和导航按实际源码所有权维护，业务授权与生命周期继续由原拥有者负责。

## Agents 角色与共享机制

具体角色装配归 Agents 根级，Support 保留通用机制；角色私有载荷和会话控制由角色解释，通过注入的解码／Context 钩子接入共享准入。输入身份、Task scope、取消加入和真实结果保持独立，源码和验证按其实际所有者维护。
