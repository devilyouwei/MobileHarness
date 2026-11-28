# Repository Instructions

These instructions apply to all work in this repository.

- Before writing or modifying code, establish what each candidate directory owns and which development rules apply there. To do this, read the relevant technical READMEs and check each directory from the repository root through the candidate directory for an `AGENTS.md`. Read every applicable guide. For changes spanning directories, do this for each affected path.
- If the target directory has no `AGENTS.md` of its own, follow the inherited rules and use neighboring files in that directory as a guide to its coding style and responsibilities.

## 1. Read and Maintain Documentation

Read the relevant documentation before designing or implementing a change. Before editing a document, read its outline and the surrounding sections. Place the update in the section that owns the topic and follow the document's structure, terminology and style.

Write documentation in English. When editing a document, translate existing non-English prose into English. Preserve original wording where it matters for accuracy, such as a localized UI string, a verbatim quotation or an original source artifact.

| Location | Responsibility |
| --- | --- |
| `docs/` | Requirements, proposed technical designs, implementation plans, decision records, change history, validation results and supporting materials. Follow `docs/README.md` for classification and placement. |
| `MobileHarness/README.md` | The architecture as implemented, including module boundaries, dependencies, cross-module interfaces, control flow and data flow. |
| `MobileHarness/<Module>/AGENTS.md` | Development rules for the entire first-level directory, including ownership by subdirectory, dependency boundaries, constraints, pitfalls, templates and working examples. |
| Code-directory `README.md` files | The implementation within the owning module or directory, including concrete interfaces, responsibilities, data flow, state and algorithms. |

- Link each module README to its development guide. Keep technical READMEs aligned with the current code. Replace superseded descriptions in place and omit implementation status markers.
- Each first-level module and each directory with a distinct technical design owns a `README.md`. A simple leaf directory may be described in its immediate parent README, with a relative link to the directory and its purpose, current interfaces and implementation constraints.
- Each first-level module README must describe responsibilities and boundaries, direct upstream/downstream relationships and interfaces, internal submodule designs and relationships, data flow, and key technical decisions. Include a diagram of its direct upstream and downstream interfaces and a separate diagram of its internal flow. Describe external relationships one level deep only.
- Nested READMEs must focus on their own directory: interfaces, algorithms, state, lifecycle, failure handling, and constraints as applicable. Link to other documentation instead of duplicating it.
- Preserve `docs/Technical_Design.docx` as the original design source.

## 2. Keep Modules Independent and Responsibilities Clear

- First-level directories under `MobileHarness/` own the application's core modules and App-level packaged resources. Keep them highly decoupled, with explicit ownership and clear responsibilities.
- ModelKit, PlatformKit, UI, and Storage are foundational capability modules. They must not depend on other project modules or own upper-layer business logic or application orchestration.
- Use explicit module interfaces. Do not introduce circular dependencies, duplicate ownership, or reach into another module's implementation details.
- Consult the architecture and dependency sections in `MobileHarness/README.md`, the owning module's `AGENTS.md` and its README before choosing where code belongs.
- Treat existing dependencies that conflict with these principles as outstanding migration work, not as precedent for new dependencies.

### Source Organization

- Once the directory's responsibility and development rules are clear, write or modify code there only if the change belongs to that directory, following its rules. If the change belongs elsewhere, find the appropriate existing directory and check its rules first. If ownership is still unclear, ask the developer before writing code. Follow §3 when proposing a new directory for authored files.
- Keep module entry points and module-wide contracts together at the module root. Shared or Support owns reusable mechanisms. Place capability-specific interfaces, child containers, state and rendering with their capability owner.
- Decide placement by responsibility, not merely by `public` visibility, reuse count, or a fixed number of root files. Keep closely related small declarations together rather than introducing a file for every type.
- Preserve existing compiled-target and dependency boundaries. A documented shared-contract target may own module-wide contracts in Support/Contracts; application composition may keep its root in Composition. Do not relocate these solely for visual symmetry.

## 3. Obtain Approval Before Adding Directories or Modules

- Obtain explicit user approval before adding a directory to organize authored files, including source modules, tests, scripts, documentation and experiment tasks.
- Builds, downloads and existing tasks may create directories for their artifacts, caches, downloaded models and per-run results without separate directory approval. For example, adding a new experiment task directory requires approval. Running that task may create its results directory automatically.
- Prefer an existing module or directory whenever its responsibilities cover the change. Do not add a module merely to accommodate a new feature.
- Before requesting approval, explain the proposed purpose and ownership, why existing directories cannot accommodate it, and its relationships with existing modules.

## 4. Update Documentation Before Code

- Before coding a feature or fix, record its intended behavior, affected files, responsibilities, interfaces and flows in the relevant `docs/` requirement or plan. Identify the owning READMEs and any cross-module design that will need updating.
- If the design changes during implementation, revise the plan before continuing.

## 5. Reconcile Documentation and Remove Obsolete Code

- After changing code, check each affected code directory for a `README.md`. Where one exists, update the relevant sections to describe the implementation as it now works. If a parent README documents a leaf directory, update that description there.
- Update `MobileHarness/README.md` when module boundaries or cross-module flows change. Keep requirements, pending work, change history and validation results in `docs/`, including after delivery.
- Remove superseded code, duplicates and stale references within the scope of the change. If a migration requires both implementations, explain the current behavior and its reason in the owning README and track remaining cleanup in `docs/`.

## 6. Validate Changes and Report Evidence

- Run checks appropriate to the change. For code changes, run `./scripts/check.sh` and, when full Xcode is available, `./scripts/build-ios.sh`. For documentation-only changes, verify accuracy, referenced paths, and diff formatting; builds are not required.
- Add or update tests when behavior changes or a regression needs coverage. Test observable behavior and failure cases rather than duplicating implementation details.
- Report pass, fail or not run separately for engineering tests, builds, research-tool regressions and real-model experiments. Preserve individual subtask failures in batch results. Run timing-sensitive tests separately from heavy model experiments. Default engineering checks exclude real-model matrices.
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

| Owner | Scope |
| --- | --- |
| [Tests](Tests/README.md) | Swift tests for App behavior, contracts, cross-module flows and model integration. A single model and fewer than ten requests may verify communication and flow. Engineering fixtures belong with their tests. |
| [experiments](experiments/AGENTS.md) | Python model evaluations, prompt comparisons, accuracy and performance measurements, with task-owned datasets, scoring and runner regressions. Read the experiment guide and task README before changing or running an experiment. |
| [scripts](scripts/README.md) | Batch orchestration, including configuration, concurrency, timeouts and exit status. Read the script guide and target README before running a task. Prefer an existing entry point or invoke the owning task directly. |
| [Models](Models/README.md) | The only shared artifact location for tests and experiments. Pin the source and version, verify size and hash, and reuse valid artifacts. |

- Keep tests and experiments independently runnable. Neither may import or read the other's code, configuration, datasets or results, directly or through scripts. Each may implement its own helpers.
- Write raw experiment outputs to `experiments/<Task>/results/`. Put authored reports in `docs/validation/` and link to the raw outputs. Keep executable code, datasets, runtime configurations and machine-generated metrics with their respective owners.
