# Repository Instructions

These instructions apply to all work in this repository.

## 1. Read and Maintain Documentation

Read the relevant documentation before designing or implementing a change. Documentation has three distinct responsibilities:

| Location | Responsibility |
| --- | --- |
| `docs/` | Requirements, plans, decisions, change history, and validation evidence. Follow `docs/README.md` for classification and placement. |
| `MobileHarness/README.md` | Overall technical design: core modules, the complete framework, cross-module flows, data flow, and key architectural designs. |
| Code-directory `README.md` files | Detailed technical design and implementation for the owning directory, with increasing detail at deeper levels. |

- Keep documentation under `MobileHarness/` aligned with the latest code. Technical documentation under MobileHarness/, including module and nested directory documents, describes implemented designs only and uses no implementation status markers. Keep proposed designs, plans and outstanding work in docs/; remove superseded descriptions from the current design contract.
- Each first-level module and each directory with a distinct technical design owns a `README.md`. A simple leaf directory may be described in its immediate parent README, with a relative link to the directory and its purpose, current interfaces and implementation constraints.
- Each first-level module README must describe responsibilities and boundaries, direct upstream/downstream relationships and interfaces, internal submodule designs and relationships, data flow, and key technical decisions. Include a diagram of its direct upstream and downstream interfaces and a separate diagram of its internal flow. Describe external relationships one level deep only.
- Nested READMEs must focus on their own directory: interfaces, algorithms, state, lifecycle, failure handling, and constraints as applicable. Link to other documentation instead of duplicating it.
- Update the overall design when a change affects module boundaries or cross-module flows. Update the relevant `docs/` documents when requirements, plans, decisions, or validation records change.
- Keep historical evidence distinct from current implementation claims. Preserve `docs/Technical_Design.docx` as the original design source.

## 2. Keep Modules Independent and Responsibilities Clear

- First-level directories under `MobileHarness/` represent the application's core modules. Keep them highly decoupled, with explicit ownership and clear responsibilities.
- ModelKit, PlatformKit, UI, and Storage are foundational capability modules. They must not depend on other project modules or own upper-layer business logic or application orchestration.
- Use explicit module interfaces. Do not introduce circular dependencies, duplicate ownership, or reach into another module's implementation details.
- Consult the architecture and dependency sections in `MobileHarness/README.md` and the owning module README for dependency and flow design before choosing where code belongs.
- Treat existing dependencies that conflict with these principles as outstanding migration work, not as precedent for new dependencies.

### Source Organization

- 根目录放模块入口和整体契约；Shared／Support 放可复用机制；具体能力跟随所属目录。
- Keep module roots and module-wide contracts (such as structured failures and state snapshots) discoverable together. Shared/Support owns reusable mechanisms; capability-specific interfaces, child containers, state and rendering stay with their capability owner.
- Decide placement by responsibility, not merely by `public` visibility, reuse count, or a fixed number of root files. Keep closely related small declarations together rather than introducing a file for every type.
- Preserve existing compiled-target and dependency boundaries. A documented shared-contract target may own module-wide contracts in Support/Contracts; application composition may keep its root in Composition. Do not relocate these solely for visual symmetry.
- A UI Root directory owns root-page composition and navigation; it is distinct from the UI module's root API directory.

## 3. Obtain Approval Before Adding Directories or Modules

- Obtain explicit user approval before creating any new directory, including a new first-level module under `MobileHarness/`.
- Prefer an existing module or directory whenever its responsibilities cover the change. Do not add a module merely to accommodate a new feature.
- Before requesting approval, explain the proposed purpose and ownership, why existing directories cannot accommodate it, and its relationships with existing modules.

## 4. Update Documentation Before Code

- For every feature or fix, document intended changes in the relevant docs/ requirements or plans before editing code. Describe affected files, responsibilities, behavior, interfaces and flows. Keep MobileHarness/ technical READMEs limited to implemented designs.
- For changes spanning directories, plan changes to each owning design document and cross-module boundaries in docs/. After implementation, update each affected README and the overall design.
- Track pending implementation in docs/ only. After implementation, reconcile technical documentation with the actual result without status markers.
- If the design changes during implementation, revise the documentation before continuing code changes.

## 5. Reconcile Documentation and Remove Obsolete Code

Before completing a code change:

- Verify that affected documentation accurately describes the latest design, actual implementation; track remaining work in docs/.
- Remove replaced code, redundant or duplicate implementations, and stale references within the scope of the change.
- Do not leave old and new implementations side by side without a documented migration need. Describe the actual transitional behavior and its reason in the owning README; track remaining cleanup in docs/.

## 6. Validate Changes and Report Evidence

- Run checks appropriate to the change. For code changes, run `./scripts/check.sh` and, when full Xcode is available, `./scripts/build-ios.sh`. For documentation-only changes, verify accuracy, referenced paths, and diff formatting; builds are not required.
- Add or update tests when behavior changes or a regression needs coverage. Test observable behavior and failure cases rather than duplicating implementation details.
- Report what was verified, what failed, and what could not run. Do not describe unavailable checks as passing.
- Distinguish build and automated-test results from real model, native UI, and physical-device acceptance. Label demo and stub behavior explicitly.

## 7. Make Runtime and Failure Contracts Explicit

- Define ownership, isolation, cancellation, cleanup, and completion semantics for asynchronous work. Long-lived work must have an owner independent of UI page lifetime.
- Give every queue an explicit bound and overflow policy. Surface rejected or failed device actions; never silently discard them.
- Propagate configuration and execution failures explicitly. Do not hide them with forced operations, fabricated success, or undocumented fallbacks.
- Use public platform APIs and validate required capabilities and permissions. Physical-device safety must not depend on iOS background execution.

## 8. Protect Repository Integrity

- Keep changes focused on the requested task. Preserve unrelated working-tree changes and include only intended files in a commit.
- Do not commit secrets, local signing settings, model weights, or user media.
- Add third-party dependencies only for a concrete integration need; document their purpose and owning module.

## 9. Agent Validation Workflow and Directory Ownership

Before changing or running experiments, read [experiments/AGENTS.md](experiments/AGENTS.md) and the owning task README. That file defines experiment execution, data ownership and report placement. Raw outputs belong in `experiments/<Task>/results/`; authored experiment reports belong in `docs/validation/` and link to those outputs.

- `scripts/` 是供开发 agent 使用的批处理与自动化入口：选择模块/任务，调用 Tests 或 experiments 的执行入口，传递配置、限制并发/超时、收集退出状态。批处理代码放这里；断言、评分、提示词和业务夹具放所属目录。不得把 scripts 做成双方共用的业务库。
- `Tests/` 使用 Swift 验证 App 模块功能、接口及跨模块链路。允许单模型、个位数请求验证通信与业务通顺；不运行模型效果矩阵。
- `experiments/<任务>/` 使用 Python 直接运行模型 case、提示词对照、准确率与性能实验；自有脚本、配置、Datasets 和 Results。运行器自身的离线回归也由这里维护。
- Tests 与 experiments 不互相导入，不读取对方代码、配置、数据或结果，不通过 scripts 间接共享这些内容。允许各自重复实现；双方可独立运行。
- `Models/<模型名>/` 是双方唯一共享的制品位置：从 Hugging Face 或其他明确 URL 下载，固定版本、校验大小/哈希，复用已有有效制品，避免重复下载。这里不放项目共享业务库、评估集或运行结果。
- `docs/` 保存人工撰写或汇总的方法、结论、计划、验证报告及文档附件；原始实验数据归 experiments。`MobileHarness/` 拥有 App 生产实现。
- 执行前先读 `scripts/README.md` 和目标目录 README，优先使用现有脚本入口；缺少批处理入口时，可直接调用所属目录入口，新增批处理仅做编排，不复制验证逻辑。不要假设存在统一实验命令。
- 工程检查使用 `./scripts/check.sh`，构建使用 `./scripts/build-ios.sh`；模型实验显式选择任务、模型/版本、case、请求预算和输出路径。默认工程检查不触发真实模型矩阵；凭据不写入脚本或结果。
- 工程测试、构建、研究工具回归、真实模型实验分别记录成功/失败/未执行。批处理保留子任务失败状态，不以其他任务通过掩盖失败；计时敏感工程测试与重模型实验串行运行。

### Validation scope

- `Tests/`: Swift only. Own App unit tests, business logic, module contracts and cross-module flows, including App model management, deployment and inference integration. A few model requests may verify communication and flow correctness; prompt quality, case matrices and model comparisons belong in experiments.
- `experiments/`: Python only. Evaluate model cases, prompts, accuracy and inference performance. Local experiments use Apple Core AI / Core ML artifacts through Python interfaces, without launching Swift, App code or Tests. Explicit cloud and Apple system-model backends also run directly from Python. Keep task inputs in Datasets and raw outputs in Results.
- `docs/`: Authored or summarized documentation and reports, including agent-written documents. No executable tests, experiment runners, datasets, runtime configurations, raw responses or machine-generated metrics. Engineering fixtures belong in Tests; experimental data belongs in experiments.
