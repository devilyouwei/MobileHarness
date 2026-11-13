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
