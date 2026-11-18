# ModelKit 制品所有权

目标：ModelKit 独立拥有模型声明、磁盘布局、安装库存、下载/取消/删除、断点恢复与原生后台交接，不再通过 Actions/Storage 提供存储空间。业务的默认模型、选择、调用参数和偏好持久化仍留在外部。

实施范围：
- 将 Resources/Models/model-catalog.json 放到现有 ModelKit/Support/Management，作为 Runtime 包资源；同步构建脚本、测试和引用。不创建源码目录。
- Management 实现受路径约束的磁盘制品存储，拥有 application support 下 MobileHarness/Models 的 installed/staging/index，兼容原安装收据；原 Actions 适配器删除。
- ModelContainer 默认组合内置 catalog、文件存储和 Hub 下载器；App 不注入 FilesContainer，不计算模型安装路径。保留显式资源/协议注入供独立测试。
- 移除 Storage.Files.models；下载源、语音等业务偏好转入 settings。偏好搬迁必须避免静默重置旧设置。
- 后台事件交接收敛到 ModelKit；App 仅转交 OS 事件。保持容量上限与完成语义。
- URL 支持校验后的单文件 urlFile 与 ZIP（urlArchive），制品声明可通过 ModelKit 的目录接口添加或更新；更新必须先移除已安装版本，不能覆盖在用模型。URL ZIP 与 Hugging Face 采用系统后台传输；URL 下载补齐与确切 URL 绑定的持久化 resume data，失败/取消清理可观察，恢复校验与原安装发布围栏一致。
- 更新 ModelKit、Management、Actions/System/ModelResources、Storage/Files、App/Composition、App/Lifecycle、Resources 及总体技术设计。更新边界检查验证无外部模型存储耦合。

验证：文件存储的持久化、越界/符号链接、错误收据、安装发布/移除；下载恢复契约；运行 scripts/check.sh 和可用时 scripts/build-ios.sh。原生后台唤醒与真机网络续传需单列验收，不以替身测试代替。

进度：代码迁移与 D3 Lite 移除已实现，模型专项 76 项通过、6 项条件跳过，另有 UI 选择回归通过。完整检查未全绿的证据与独立真机验收缺口见 [验证记录](../../validation/ModelKit-Artifact-Ownership.md)。

## D3 Lite 移除

按追加要求，移除 d3-lite 的 ModelKit 注册、准备路由、生产制品声明、下载脚本入口、UI 选择和用途映射、Provider 保存校验及 Agent 执行路由。Edge 共用实现保留。旧偏好保留原值但不作为有效选择，执行明确失败；用户选择受支持模型后方可保存，不静默切换模型。回归测试验证拒绝已移除 ID，即使有旧安装亦不重新启用。历史测量证据保留，但可执行基准入口不再提供 Lite。

实现约束：随包默认制品声明只随 SDK 版本更新；新增自定义声明可持久化修改和删除，不能覆盖已安装/在传输的制品。业务偏好旧路径由 App 启动时一次迁移到 Settings。

恢复兼容：移除目录声明后，旧下载记录不得阻塞其他模型启动。ModelKit 恢复时取消并加入不再支持的原生传输、清理对应 staging、持久化剩余记录，并通过模块失败报告通道明确报告移除的任务；不自动切换业务选择、不删除已安装的旧权重。

## 启动依赖图同步

按当前 ModuleRegistration 更新总体设计的 Dependencies and startup 图：四个基础根分别依赖 diagnostics，移除 Storage → ModelKit；executionBindings 等待四个基础根。说明 ApplicationLifecycle 仍按注册顺序选择已就绪节点并串行启动，图区分就绪依赖与当前执行顺序。本次仅修改文档，验证图中全部边与注册代码一致。

## 配置目录独立管理

用户已批准新增 ModelKit/Support/Config。将单个 model-catalog.json 与 ModelArtifactCatalog、制品声明类型及解析校验迁入该目录；Management 保留下载、存储、状态和生命周期契约。保持 ModelKitRuntime 编译目标与公开 API 不变，将目标源码根扩大到 Support 并显式列出源码/资源。同步 Package.swift、Xcode 导航、构建输入、下载脚本、边界检查及 ModelKit/Support/Management 设计说明，新增 Config README。随包清单继续单文件管理，持久化自定义模型仍由存储负责；业务选择、默认模型和推理参数保持外部所有权。运行完整检查、iOS 构建与现有清单解析回归，记录实际结果。

迁移检查同时清理已删除 Resources/Models 的 Package exclude 与 Xcode 空分组/失效 README 引用，避免资源解析警告。

配置目录迁移已实现；单文件内容与解析逻辑保持不变，五个 iOS scheme 构建通过。完整检查中的 Swift 测试被磁盘空间不足阻断，见验证记录的配置目录迁移章节。
