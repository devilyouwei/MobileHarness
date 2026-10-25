# Gateway container validation

Date: 2026-10-25 (Asia/Shanghai).

## Change and evidence boundary

App owns one GatewayContainer per registration scope. Agents supplies neutral execution configuration and borrows capabilities; it no longer constructs or closes Gateway core facilities. Actions remains an extensible business library. The existing sound-direction diagnostic borrows a root-owned observation session with its own identity registry and empty execution catalogs; only one such session is admitted at a time.

Current architecture and API contracts belong to the [overall design](../../MobileHarness/README.md), [Gateway](../../MobileHarness/Gateway/README.md) and [App composition](../../MobileHarness/App/Composition/README.md). This report records validation evidence, not another implementation contract.

## Automated coverage

[GatewayContainerTests](../../Tests/IntegrationTests/GatewayContainerTests.swift) exercises:

- Scoped identity, inert construction, once-only configuration, invalid configuration and terminal closure.
- Cached-port admission fencing, terminal controls while suspended and isolation between role registrations.
- Joined scheduled/direct cancellation and native stop cleanup using explicit gates rather than timing assumptions.
- Retained cleanup errors, cancellation-only startup failure and rejection of old-root references after replacement.
- App lifecycle readiness, inverse shutdown with retained execution bindings and rollback after Agent startup failure.
- Bounded observation-session acquisition, diagnostic identity isolation, independent release and root-owned final cleanup.

The sound-source diagnostic regression in [SoundSourceTests](../../Tests/IntegrationTests/SoundSourceTests.swift) now uses the root-owned observation path. It supplies synthetic PCM and providers that must not run ASR/VAD; this is not real model or microphone acceptance.

Boundary checks reject Gateway facility construction inside Agents and require the App lifecycle graph and AppStorage target dependency to include Gateway. Existing authorization, resource, Channel/wait, execution-report and role-input regressions remain part of the full check.

## Execution results

| Check | Result |
| --- | --- |
| Gateway-focused regressions | Passed; the final full check includes the added scheduling, direct-call, observation-session and host rollback cases. |
| `./scripts/check.sh` | Passed on final source: architecture/source boundaries, six Python download tests, strict Swift formatting lint, both Swift test phases and property-list checks. IntegrationTests reported 846 ordinary tests and 221 native/realtime tests; other package suites also passed. |
| `./scripts/build-ios.sh` | Passed on final source: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero; packaged Agent/Skill resources verified. |
| Documentation | Overall README English Parts I–II, changed-document linked paths, Mermaid line-style indices and diff whitespace verified. Current ownership and startup/cleanup descriptions reconciled. |

The selected full Xcode toolchain is used by both repository scripts. An initial exploratory AppStorage build under CommandLineTools could not find the Metal compiler; it is not counted as a passing build. Subsequent scripted builds use full Xcode.

## Acceptance limits

No real LLM request, downloaded model execution, physical camera/microphone session, manual app interaction or physical robot acceptance was performed for this change. Native/realtime automated tests and simulator compilation are separate evidence categories; synthetic serial/device and model fixtures do not establish physical safety or on-device behavior. Non-cooperative dependency shutdown still waits for actual completion and has no forced-stop guarantee.
