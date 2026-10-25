# Agent container validation

Date: 2026-10-24. Branch: codex/agent-container. Full Xcode toolchain selected using DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.

## Current evidence summary

The latest implementation checks passed: check.sh main integration phase 827 tests, serialized LiveRuntimeTests 221 tests, all four simulator schemes and signed device build 2026102402. Reinstallation, launch and independent installed-app inventory confirmed 0.1.0/build 2026102402. The 13 Agent lifecycle tests include the initial inactive startup regressions. The user confirmed normal first entry on physical-device build 2026102402, without the previous application preparation failure. The iOS-only identity test and broader business acceptance remain unconfirmed. Earlier counts and launch failures below describe earlier runs, not the latest state.

## Automated coverage

AgentContainerTests exercises the actual shared lifecycle implementation with controlled startup/transition/cleanup callbacks: inert construction, isolated scopes, concurrent start/stop coalescing, mandatory suspension, late resume fencing, caller cancellation, startup cancellation joined by stop, partial startup/cleanup failure evidence and terminal rejection. Failure tests preserve original NSError identity and cancellation/cleanup classification.

AgentSpecialistTests verifies Assistant scene transitions only affect Assistant and that a separately started Photographer still executes camera requests. Existing suites cover role UI receipts, speech/vision pipelines, authorization, result completion and native ownership.

An iOS-only case checks real ApplicationContainer root caching, all seven child identities and independent roots without starting capture or loading models. It requires an iOS test host; macOS tests do not execute it, and the App/library build schemes do not compile that test target. This case remains unexecuted.

## Runs

- Initial lifecycle run: 8 tests passed. Two transition-race/failure cases were added afterwards; all 10 lifecycle tests passed in the final full-check main phase.
- Initial full check: one failure in agentProtocolFailureProjectsShortToastFullDetailAndCorrelation (2-second wait for diagnostic presentation); the other 823 tests in that phase passed. The later 221-test LiveRuntimeTests phase passed.
- Isolated diagnostic recheck: passed, 0.014 seconds. The initial timing failure occurred while an iOS build ran concurrently; load sensitivity is an inference, not a confirmed cause.
- Intermediate iOS builds exposed availability annotations at the iOS 26 package / iOS 27 application boundary and an actor-isolation diagnostic in speech output. These were fixed. The final build-ios.sh completed with exit code 0: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero all reported BUILD SUCCEEDED; packaged Agent resources were verified.

## Acceptance limits

No dedicated real-model, native page interaction, microphone/camera hardware, Bluetooth/NexArm physical action or performance acceptance was performed for this change. Device installation evidence is recorded below. Build success and injected lifecycle tests do not establish that acceptance.

Remaining native acceptance: text and voice conversation; listening interruption/restart and synthesis playback; Provider/resource settings; history reads/mutations; camera/pose/tracking; foreground transitions and startup failure/retry without duplicate capture/device owners.

## Pre-startup-fix check status

The final check.sh main phase passed all 824 tests, including the earlier diagnostic timing failure. All 10 new lifecycle tests passed. The final sequential LiveRuntimeTests phase passed all 221 tests in 207.132 seconds. check.sh completed with exit code 0, including architecture boundaries, formatting, all configured test products and project/plist checks. Markdown local links in changed documents and git diff --check pass.

## Physical-device installation (2026-10-24)

- Current codex/agent-container working tree, based on HEAD 78ae4d05, built successfully with the MobileHarness Debug device scheme, existing local signing and build/DeviceDerivedData. CURRENT_PROJECT_VERSION=2026102401 was a command-only override; repository/local signing configuration was not changed.
- Signed package metadata: dev.mobileharness.app, version 0.1.0, build 2026102401. Strict/deep codesign verification and all 25 packaged Agent/Skill assets plus the Core protocol passed.
- CoreDevice confirmed installation on the paired iPhone 17 Pro running iOS 27.0.1. Pre-install inventory showed build 1. Post-install inventory with --include-all-apps --bundle-id dev.mobileharness.app independently confirmed build 2026102401. No uninstall, data-container reset or model removal was performed.
- An initial app-inventory connection reset recovered after a device-details query. The first launch failed with an unavailable remoteService connection; retry explicitly failed because the device was locked (FBSOpenApplicationErrorDomain 7 / Locked). Installation is confirmed; launch and native interaction acceptance are not claimed. Unlock and manually open Mobile Harness to continue testing.
- Local evidence: /tmp/mobileharness-agent-device-build.log, /tmp/mobileharness-agent-device-install.json, /tmp/mobileharness-agent-device-verified.json, /tmp/mobileharness-agent-device-launch-retry.json. These are installation/build evidence, not physical business-effect acceptance.

## Initial inactive startup regression (2026-10-24)

User-observed build 2026102401 opened with ApplicationLifecycleFailure(service: agents, primary: CancellationError, cleanup: []), and manual reload recovered. Investigation found that AppComposition initially calls ApplicationLifecycle.setForeground(false), which invalidates every service before startup. AgentContainerLifecycle incorrectly fenced and retained inactive state on that cold-root notification; its first foreground start then cancelled after doing startup work. Reload created a fresh scope while already active.

The fix ignores invalidation only before any Agent start request. It leaves startup-in-flight invalidation, cancellation, joined rollback, terminal stop and running suspension unchanged. It does not suppress service failures or add automatic retries.

Two regression cases failed before the fix; the composed real ApplicationLifecycle/AgentContainerLifecycle case reproduced the exact user-visible failure, including empty cleanup. After the fix, all 13 Agent lifecycle tests and 22 ApplicationLifecycle-related tests passed. A third new case verifies that invalidation during startup still cancels and joins cleanup. Evidence: /tmp/mobileharness-agent-initial-start-red.log and /tmp/mobileharness-agent-initial-start-green.log. Final check.sh passed with exit code 0: the main integration phase passed all 827 tests and the sequential LiveRuntimeTests phase passed all 221 tests (206.865 seconds), alongside the other configured test products and project/plist checks. All four build-ios.sh schemes passed; signed physical-device Debug build 2026102402 also passed. Strict/deep signature and 25 Agent/Skill resource checks passed.

The fixed package (0.1.0/build 2026102402) was installed over the existing App on the same paired iPhone 17 Pro without uninstalling or resetting its data/model storage. CoreDevice installation succeeded (/tmp/mobileharness-agent-start-fix-install.json). Automatic launch was denied because the device was locked (/tmp/mobileharness-agent-start-fix-launch.json). Follow-up app inventory failed because the local-network tunnel disconnected; an attempted device-details reconnect timed out. Installation of the verified signed package is confirmed, while independent post-install inventory and native cold-start UI acceptance remain unconfirmed. The user has been asked to unlock and test the first entry. Additional evidence: /tmp/mobileharness-agent-start-fix-check.log, /tmp/mobileharness-agent-start-fix-ios.log and /tmp/mobileharness-agent-start-fix-device-build.log.

On the user's subsequent installation request, the same verified build 2026102402 was installed again without uninstall/reset. CoreDevice confirmed launch successfully, and the filtered installed-app inventory independently confirmed version 0.1.0/build 2026102402. This supersedes the earlier locked-device launch limitation for installation/launch evidence; native startup UI and business acceptance still require observation. Evidence: /tmp/mobileharness-agent-start-fix-reinstall.json, /tmp/mobileharness-agent-start-fix-reinstall-launch.json and /tmp/mobileharness-agent-start-fix-reinstall-verified.json.

<a id="documentation-audit"></a>

## Documentation audit (2026-10-24)

Reviewed the root, seven role containers, shared lifecycle/Failure, App registry, presentation and ManagedService dependencies against their current source and Package.swift. Consolidated code-directory READMEs into current ownership/contracts and test coverage; obsolete targets, source owners, simulator-failure claims and dated migration summaries are removed from current contracts. Historical excerpts and cleanup decisions are in [history](../history/Code-README-History.md#2026-10-24agents-容器化相关-readme-清理), while previous build/device results above remain historical evidence.

This pass changes Markdown only. Local Markdown paths/anchors, Agents directory README coverage, incoming links to edited README sections and git diff --check are verified. Source/script/project-content hashes are unchanged during the audit. No builds, automated behavior tests, model calls, device installation or native acceptance were rerun for this documentation-only change. The earlier execution evidence retains its stated scope.

## User-confirmed first entry (2026-10-24)

用户针对修正版 build 2026102402 解锁后直接打开 Mobile Harness 的首次进入检查，反馈：“首次进入正常”。据此记录该次真机首次进入未再出现“应用准备失败”，无需点击重新加载。证据来源为用户真机观察；不扩展为多次冷启动、前后台压力、语音／相机／设备业务或性能验收。

<a id="agentcore-warning-cleanup"></a>

## AgentCore warning cleanup (2026-10-24)

Recompiled AgentCore with -Xswiftc -no-warnings-as-errors to reproduce UnnecessaryEffectMarker at AgentContext.swift:25 and CapabilityRegistry.swift:75. Both applied try to the nonthrowing optional-ID/UUID expression. Removed only those two markers; explicit IDs, UUID defaults, validations and throwing API signatures are unchanged. The subsequent AgentCore build passed and emitted no warnings for the two changed files. Logs: /tmp/mobileharness-agentcore-warning-reproduce.log and /tmp/mobileharness-agentcore-warning-after.log.

A diagnostic -warnings-as-errors build before the fix failed first on an existing unnecessary try in CommunicationAction.swift. The normal full AgentCore rebuild also exposed existing warnings in SignalProcessing.swift (unnecessary try) and AgentConfiguration.swift (ambiguous trailing closure). Those three files are outside this two-file fix; no whole-target warning-free result is claimed.

Post-fix ./scripts/check.sh completed with exit code 0: 827 main integration tests and 221 serialized LiveRuntimeTests (206.223 seconds) passed, along with the other configured test products, boundary checks, formatting and project/plist checks. The three existing AgentCore warnings listed above and an incremental SwiftPM UI-bundle “missing creator for mutated node” warning remained; neither changed file emitted its prior warning. Evidence: /tmp/mobileharness-agent-container-final-check.log.

Post-fix ./scripts/build-ios.sh completed with exit code 0: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero all reported BUILD SUCCEEDED, and bundled Agent resources were verified. The app build retained the toolchain's “Metadata extraction skipped, no AppIntents.framework dependency found” warning. Evidence: /tmp/mobileharness-agent-container-final-ios.log. Markdown local paths/anchors and git diff --check passed. This warning-only follow-up did not rerun device installation or physical acceptance; the user's first-entry confirmation above remains the device evidence.

## Main-branch physical-device installation (2026-10-24)

Built main at commit 86aed2f6 with the signed MobileHarness Debug device scheme and CURRENT_PROJECT_VERSION=2026102403 as a command-only override. Build, strict/deep signature verification and all 25 Agent/Skill assets plus Core protocol checks passed. No source or local signing configuration changed.

Installed version 0.1.0/build 2026102403 over the existing App on the paired iPhone 17 Pro without uninstalling or resetting data/model storage. Initial post-install launch and inventory queries failed with CoreDeviceError 4000 (device disconnected immediately after connecting). A device-details reconnect succeeded; sequential inventory then independently confirmed the installed build, and launch retry succeeded. Native UI/business acceptance for this build was not observed.

Evidence: /tmp/mobileharness-main-device-2026102403-build.log, /tmp/mobileharness-main-device-2026102403-install.json, /tmp/mobileharness-main-device-2026102403-reconnect.json, /tmp/mobileharness-main-device-2026102403-verified-retry.json and /tmp/mobileharness-main-device-2026102403-launch-retry.json.
