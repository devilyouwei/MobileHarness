# Agents responsibility-boundary validation

Date: 2026-11-14. Scope: Assistant ownership, injected local-function catalogs, root host/Gateway contracts, and corresponding source/documentation moves. This record follows [the implementation plan](../requirements/technical/Agents-Responsibility-Boundaries.md).

## Implemented result

Assistant owns conversation orchestration, history/state projection, speech production and Decision presentation. Shared Chat owns neutral provider/message mechanisms. AgentConfigurations and CapabilityCoverage receive local declarations/paths from root composition without referencing WriterLocalTools. Root AgentHostBindings and AgentGatewayPorts expose module-wide contracts; Support implements Gateway assembly and scoped observations. Xcode references, call sites, fixtures and architecture checks follow the new names. No directory, compiled target or dependency was added.

The Support audit lists all 74 remaining Swift sources exactly once. Existing English-keyed localization and language injection are preserved. New code and design text use English.

## Automated evidence

- Native Swift test runner: 44 selected test functions passed across three runs (12 catalog/coverage/presentation, 16 full-duplex/task/feedback, 16 history/Decision). Parameterized cases also passed. Tests cover local owner/protocol rejection, duplicate/conflicting declarations, immutable catalog installation, exact coverage exemptions, cancellation, transactional history, SQLite reload, full-duplex joins, Writer feedback and localized app-owned copy.
- Architecture checker passed with full Xcode selected, including strengthened shared-versus-role source checks. An initial sandboxed rerun could not access compiler caches; the rerun with cache access passed.
- `./scripts/check.sh`: architecture, seven Python tests and strict Swift formatting passed; default Swift tests failed to build because Xcode could not find the Metal Toolchain for UI/Conversation/ListeningHalo.metal. Property-list checks passed. This is not a full-suite pass.
- `./scripts/build-ios.sh`: failed at the same Metal compilation step; no successful iOS build is claimed.
- Changed documentation paths and Assistant/Chat target anchors were checked; the obsolete caption anchor was repaired. The Support inventory matches the filesystem. Diff whitespace validation passed.

Native command prefix: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native --filter ...`. Generated xcstrings localization resources were available in the native test bundle. Native tests use fixtures/stubs; they do not validate Metal rendering.

## Remaining validation

Install the matching Xcode Metal Toolchain, then rerun both required scripts. Real-model, native UI and physical-device acceptance were not performed for this refactor. Preserve these distinctions when interpreting automated tests.

## Physical-device deployment follow-up

On 2026-11-14, the missing Metal Toolchain 27B47 was downloaded and its compiler verified. With the user's selected development team applied to both the app and Live Activity extension for this build, the physical-device MobileHarness Debug build succeeded. The signed app passed verification of 73 Agent/Skill assets, Live Activity packaging, and English/Simplified Chinese localization resources.

`devicectl` installed `dev.mobileharness.app` successfully on the connected iPhone 17 Pro (installation sequence 6988), without uninstalling or resetting application data. Launch was attempted but iOS rejected it because the device was locked (FBSOpenApplicationErrorDomain code 7). Installation is confirmed; successful launch, native UI, model readiness and physical-device behavior are not claimed. Build log: `/tmp/mobileharness-device-install-signed-build.log`.

This resolves the Metal component prerequisite and confirms the physical-iOS build. The earlier default full-suite and four-scheme simulator checks have not been rerun by this installation request and remain separate validation work.
