# ADR0189: Shared Agent source hierarchy

Status: implemented; repository checks and unsigned iOS device build passed. Simulator build remains externally blocked by CoreAI.

The user requested consolidating public framework/contracts/adapters under Support while preserving a business-independent Core. Physical source hierarchy and compilation ownership remain separate.

- Support/Core: existing independent AgentCore framework, Foundation-only; generic lifecycle, Signal, queues, capability/communication contracts, parsing and output.
- Support/Communication: immutable business Signal values/catalog and bundled AgentConfigurations loading; no transport workers or business decisions.
- Support/Chat: reusable Chat worker/driver/context builders and authorized model communication adaptation; policies and capabilities injected by roles.
- Support/Context: atomic structured context repository and Storage evidence adaptation; role schemas and retention decisions remain role-owned.
- Existing role directories: business states, preprocessors, builders, permissions, algorithms and workflows.

Move source directories/files without changing declarations, public names, dependencies, permissions, schemas, limits or runtime behavior. AgentCore compiles Support/Core; Agents excludes that subtree and includes the other shared components. Update Package.swift, Xcode source/navigator references, current technical documentation and static boundary paths. Preserve historical ADR/evidence descriptions separately; repair their live links when files move.

Validation: source byte equivalence and single-definition checks, no stale registered source paths, README/link coverage, module boundary validation, scripts/check.sh and scripts/build-ios.sh. Record external simulator limitations and unsigned device build separately. No runtime mirror tests are required for a source-only relocation. Real-model/native-UI/device acceptance is unaffected.
