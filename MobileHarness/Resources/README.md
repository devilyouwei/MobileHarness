# Resources — Assets and Model Metadata

## Summary

Metadata-only production resources, privacy declarations, app icons and reproducible model source catalogs.

## Ownership and boundaries

Packaging module with no Swift implementation. App/build tools consume metadata; ModelKit owns runtime acquisition/loading. Downloaded weights, vendor-package contents and user media are excluded from source-controlled design docs.

## External relationships and data flow

Arrows show build-time asset/metadata movement; runtime acquisition is owned outside this directory.

```mermaid
flowchart LR
 Resources -->|assets, privacy and catalog| Build[Build staging]
 Build --> Bundle[App bundle]
 Resources -->|catalog metadata| App
 Resources -->|production and test declarations| Scripts[Developer provisioning]
 Notices[docs license notices] --> Build
```

## Internal structure

```mermaid
flowchart TB
 Variants[AppIconVariants] --> Assets[Assets.xcassets]
 Assets --> Icon[AppIcon.appiconset]
 Models --> Catalog[Production model catalog]
 Models --> Profile[Separate Gemma macOS declaration]
 Privacy[PrivacyInfo.xcprivacy] --> Package[Resource staging]
 Assets --> Package
 Catalog --> Package
```

## Packaging contract

The bundle contains source declarations/license notices, not model weights. Catalog declarations identify acquirable artifacts; installed receipts record actual sandbox installation. Neither proves capability readiness or selects an active provider. App injects paths; ModelKit Defaults combines installation state, compatibility and preferences.

Pure Agent/Skill assets live here as Agents/, Skills/ and Catalog.json. Agents owns their schema and runtime policy; Resources owns source asset organization. The Agents package target compiles only Agents sources and copy these explicit resources without adding a new module. Runtime lookup must locate Catalog.json with Bundle APIs rather than append Resources to resourceURL. Build staging uses [license notices](../../docs/licenses/README.md). `PrivacyInfo.xcprivacy` and the asset catalog supply platform declarations. Original icon artwork is retained separately from the selected build icon.

Pinned schema-v2 catalog, metadata/notices staging, privacy declaration and app-icon artwork.

Runtime/server/device acceptance belongs in [validation history](../../docs/validation/Validation-History.md).

Agents packages Agents/, Skills/ and Catalog.json from this shared source root; Models and app assets remain independently packaged. AgentCore separately packages its generic Function Token prompt resource. The final app resource verifier checks exact source bytes and missing/stale files for both bundles.

## Related design

[Parent design](../README.md) · [AppIconVariants](AppIconVariants/README.md) · [Assets.xcassets](Assets.xcassets/README.md) · [Models](Models/README.md)

## 职责与组织

纯随 App 打包的配置与文本，由 Catalog.json 显式索引。Agents 保存 v8 身份、角色自有公开 description、私有角色指令、通信契约、baseSkills、backgroundTasks 支持声明；Skills 保存 v3 配置、revision、流程说明和函数引用。Task 目标仅作为运行时数据。

这里不包含 Swift、脚本、函数实现、凭据或用户媒体。Actions 独立提供实现，FunctionContracts 提供中立元数据。Catalog 是唯一资源索引。

## 加载与验证

AgentConfigurations 限定相对路径、单资源 64 KiB、catalog 32 Agents/64 Skills。Skill 依赖最多 8 层、同时加载最多 16；同函数重复且绑定相同可合并，未知函数、冲突、重复别名、Action/Tool 重叠整体拒绝。参数与文档不能由 Skill 重写。每个请求保存当时目录，不使用当前配置解释历史请求。

## 生命周期

Agent 配置声明基础交互与机械臂 Skill，任务和交互链按需要加载辅助 Skill；只有一个前台任务，不支持挂起恢复。等待用户保留任务；结束经过执行屏障后回默认。重启中断，不重放。

## 泛化 Task 与独立 Skill

Agent resources declare baseSkills and backgroundTasks; production backgroundTasks are empty until an executor implements and declares a business contract. Skill assets retain reusable instruction/function bindings. Task goals are runtime data, never bundled mode definitions.

资源叶目录说明收拢到 [Agents](Agents/README.md) 与 [Skills](Skills/README.md)，不再为每个 Agent/Skill 放置开发 README；Skill 注册与运行时教学保留在各自目录。

## Skill 函数目录

Agent.json 声明基础 Skill，不直接声明函数或函数权限上限。模型函数由已加载 Skill 组合，校验 canonical 元数据、重复/冲突、容量、通信授权、真实执行身份和 Task 范围。Gateway 使用调用所属轮次快照；固定调用使用 Agent 固定目录。Agents 检查所有 Skill 目录的真实实现覆盖；后台 Skill 还须匹配目标支持的业务契约。历史目录快照不可变。

RobotInteraction instructions teach Channel/wait ordering and explicit resource conflicts; the arm writer group remains authoritative.

## Agent → Skill → Function registration

Agent.json references baseSkills; Skill.json alone registers model Actions/Tools. BasicSkill owns Task/Skill orchestration and automatic State selection; ExpressionInteraction owns expression Actions. Role instructions retain identity/responsibility/style. Business roles reuse existing Skills; internal trusted bindings remain separate. Historical snapshots are preserved.

```mermaid
flowchart LR
 A[Agent.json: identity and baseSkills] --> S[Skill.json: Action / Tool bindings]
 S --> L[Skill loader: dependency / conflict validation]
 M[Action-owned function metadata] --> L
 C[Skill Instructions: procedures and examples] --> P[Request context builder]
 R[Agent Instructions: role and style] --> P
 L --> F[Immutable request catalog]
 F --> P
 F --> G[Gateway: scope and protocol validation]
 G --> E[Actions / communication runtime]
 E --> O[Results to actual owner]
 O --> P
```

Actions 为可信业务调用和模型调用提供统一实现与元数据。Skill 仅暴露实际流程需要的函数：ExpressionInteraction 提供表情，ApplicationControl 提供导航/状态/资源/Bluetooth，RobotInteraction 提供机械臂操作。BasicSkill 提供 Task/Skill 控制与自动 State 选择。具体清单和当前教学契约见 [Skills](Skills/README.md)。

## 待实现

- Separate icon appearance variants.

- 远程下载、热更新与任务栈不在首版范围内。

## 公开 State 边界

✅ Skill 资源采用 schema v3/useActions/useStates/useInstructions；教学使用 CURRENT STATE 公开事实，不依赖 activeTaskID、Skill 持有关系等私有字段。资源打包仍保留原目录和历史证据。

[容器上下文契约](../Agents/Support/Context/README.md)

✅ 精简 BasicSkill/Photography 和交叉规则，递增变更 Skill revision；保留别名、能力、错误与业务完成契约，Robot 常驻列表不变。

✅ 依据真实 Qwen 调用回归重写 Core/Skill 教学边界。内置 Skill 所有函数使用 Function Token XML Actions，包括 Query Channel 的只读查询；通用原生 Tool 基础能力保留。明确设备阻断、照片终态、先执行后确认以及跨请求控制边界，递增变更 Skill revision。Skill 声明与执行协议投影保持一致，业务实现与底层原生传输能力独立。

真实云回归使用固定合成场景，修订收益、回退和未解决的原生协议错误见[提示词优化验证](../../docs/validation/Qwen-Prompt-Optimization.md)；不等于真机执行验收。

✅ Implemented: bundled Skill registrations become Action-only; ApplicationControl/HistoryQuery revisions and BasicSkill instructions change together. Native Tool base schemas and Agent internal grants remain intact.

Assistant 的技术诊断输入声明属于 Agents 资源契约；container.failure 是被动框架 observation，不新增模型函数或 Skill 暴露。

## ApplicationControl 异常展示

✅ ApplicationControl 配置声明 container.failure/runtime.failure 的 runtime 来源订阅；Assistant 保留被动容器诊断。内部呈现函数由代码授权，不加入模型 Skill 或改变资源 schema 版本。

BasicSkill selects eight passive native platform.* State sources alongside UI navigation. Source schemas and native lifetime remain owned by [PlatformKit](../PlatformKit/README.md#native-state-port); [Skill declarations](Skills/README.md#basic-native-state-selection) select reads without starting hardware or granting execution authority.

Assistant 身份只介绍自身。BasicSkill 拥有 start/delegate 平级选择的通用教学；各 Agent.json.description 维护各自用途，加载器按真实适配与实例通信权限生成公开目录。Catalog 不包含 writing；作品查找、打开与创作由 Writer 原生工具拥有。详见 [Skill 契约](Skills/README.md) 与 [角色配置](Agents/README.md)。
