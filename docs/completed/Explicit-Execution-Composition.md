# Explicit execution composition

App explicitly sequences Agent input preparation, Actions-owned business configuration, Agent catalog validation, Gateway configuration and final role binding before root startup. AgentRuntime must not invoke callbacks that configure Actions or Gateway. ActionsContainer owns business assembly preparation and cleanup. Keep the executionBindings lifecycle boundary for reverse cleanup and partial-start rollback.

Affected implementation: Agents/AgentRuntime.swift and AgentContainer.swift expose staged preparation; Actions/ActionsBusinessAssembly.swift centralizes configuration; App/Composition/ApplicationActionAssembly.swift and ModuleRegistration.swift connect public stages. Update owning READMEs and overall design after implementation, preserving unrelated edits.

Validation: scripts/check.sh and scripts/build-ios.sh when Xcode is available; explicitly record failures and device acceptance limitations.

## Result and validation — 2026-10-31

Implemented the explicit App sequence and single-use Agent preparation/binding handles. ActionsContainer.configureBusiness now owns assembly preparation and returns public bindings. The existing executionBindings lifecycle boundary preserves rollback and reverse cleanup. No new directories were added.

`./scripts/check.sh` passed (exit 0), including boundary checks, formatting, package tests, the final 225-test live runtime phase, and plist validation. `./scripts/build-ios.sh` passed with BUILD SUCCEEDED for iOS Simulator. `git diff --check` passed. These results do not establish real-model, native app startup on device, or physical-device acceptance.
