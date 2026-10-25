# Actions container validation

Date: 2026-10-25. Scope: App-owned Actions/Gateway/Agents roots, canonical function registration, neutral execution/communication and validation ownership. Current contracts are in the [overall design](../../MobileHarness/README.md), [Actions](../../MobileHarness/Actions/README.md), [Gateway](../../MobileHarness/Gateway/README.md) and [Agents](../../MobileHarness/Agents/README.md). Decision: [ADR 0219](../adr/0219-actions-container-and-neutral-gateway.md).

## Method and environment

Swift 6.4 from full Xcode 27 on macOS, with the repository's existing resolved dependencies. No new compilation target, directory or third-party dependency was added to implement the runtime change. Existing CallRuntime/ExecutionRuntime targets compile explicit Actions/Support source lists. Generated build directories are tooling outputs.

Automated acceptance uses `./scripts/check.sh` (architecture/source ownership, six Python download tests, strict Swift formatting, ordinary suites, a separate native/runtime phase and project/plist validation) and `./scripts/build-ios.sh` (MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero). App packaging also verifies 25 Agent/Skill assets and compiled function declarations.

## Behavioral coverage

- One cached Actions root per App scope; inert construction, configuration guards and startup/rollback/reverse cleanup ordering.
- Canonical Action/Tool implementation and immutable metadata; duplicate/missing definitions and invalid input/resource/budget/output failures.
- Pure generated input preparation before effects; cross-root/stale/repeated credentials; bounded retained preparation and explicit discard.
- Neutral endpoint/incarnation/envelope/scope rejection, preparation capacity reservation, in-progress preparation stop and joined native execution.
- Channel/wait ordering, conflicts/takeover, cancellation, partial reports, delivery retry without re-execution and preserved independent cleanup failure.
- UI facade shutdown, cancelled settings discovery join, role-owned authorization/communication, history/Task, voice, camera/album, diagnostics and synthetic robot-resource regressions.

Direct library tests intentionally invoke pure support mechanisms. Production Gateway has no registry/raw-handler path; scenario compatibility constructors live only in test fixtures and use an actual ActionsContainer.

## Iteration evidence

The first complete run passed architecture/Python/format/build checks and the separate 221-test native/runtime phase, but its ordinary 862-test suite reported 30 issues. These exposed old role-permission expectations at business endpoints, omitted test-side decoder injection, unknown-function reply delivery, input preflight changes and direct failure receipts. Failures were retained and corrected rather than hidden by a compatibility execution path.

The affected 23 integration cases passed on focused rerun. A later complete run's 863 ordinary cases reported four assertions in the album-navigation case: session validation had been removed together with role checks. Current code restores the business session check; the role-permission assertion now belongs to the Agent boundary. Cancellation-focused runs passed, including independent failed-cleanup reports during cancellation.

## Final verification

- PASS: `./scripts/check.sh`, exit 0. Architecture/import/source ownership checks, six Python tests and strict Swift formatting pass. The ordinary integration phase passes 864 tests in three suites; the separate LiveRuntimeTests phase passes 221 tests. All other package test targets and final project/privacy/entitlements validation also pass.
- PASS: `./scripts/build-ios.sh`, exit 0, with four `BUILD SUCCEEDED` results: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero. Final App resource verification passes for 25 packaged assets and compiled function declarations.
- PASS: `git diff --check`; current affected technical README path audit (60 documents, no missing local targets). The overall technical design is English and retains 22 Mermaid diagrams with explicit ownership groups and request/result/lifecycle conventions.
- A superseded full run reported one newly added mixed-cancellation assertion; its redundant final Agent-adapter cancellation check was corrected. That run was stopped during its separate native phase after the known failure. The focused four-case regression then passed, including preserved direct-call cleanup evidence. The final complete runs above use the corrected source.

Host-local final logs: `/tmp/mh-actions-complete-check.log` and `/tmp/mh-actions-complete-ios.log`. Focused evidence: `/tmp/mh-actions-final-regressions.log`. Earlier failure logs remain `/tmp/mh-actions-check.log`, `/tmp/mh-actions-check-final.log` and `/tmp/mh-actions-acceptance.log`. These are local run artifacts; this report retains the outcomes independently.

## Evidence limits

Synthetic functions, model substitutes, simulated hardware and macOS native presentation/capture tests do not establish real model quality, iOS native UI acceptance, physical servo arrival or hardware emergency-stop safety. No new real-model inference experiment, iOS device session or physical arm acceptance was performed for this migration. Simulator builds explicitly use the repository's supported simulator backend configuration.

## Subsequent documentation audit — 2026-10-25

The overall-design audit found an execution-policy compatibility gap not established by the passing checks above: catalog descriptors retain executionPolicy, but production adapters currently send ActionCall to ChannelScheduler and ToolCall to DirectExecutionDispatcher without selecting the entry point from that field. Historical test/build results remain unchanged; they must not be interpreted as proving protocol-independent routing. Current technical documentation now states the observed behavior. Corrective work and acceptance criteria are tracked in [container follow-ups](../requirements/technical/Container-Architecture-Followups.md#execution-policy-routing-identified-by-the-overall-readme-audit).
