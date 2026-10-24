# Agent containers

## Requirements

One AgentContainer exposes stable Assistant, ApplicationControl, Memory, Photographer, SpeechPerception, SpeechSynthesis and VisionPerception containers. Retain existing role policy, Gateway authorization and Actions execution ownership. No new directories or compilation targets.

## Current contract owners

- [Agents](../../../MobileHarness/Agents/README.md#agent-container): root API, seven stable role capabilities, ownership and module failure contract.
- [Support](../../../MobileHarness/Agents/Support/README.md#根生命周期机制): lifecycle algorithm, bounds, cancellation and cleanup.
- [App composition](../../../MobileHarness/App/Composition/README.md): cached root, dependency graph and presentation wiring.

## Implementation

- Implemented: role containers own context/session lifetime, registration, subscriptions, output and cleanup. Runtime only wires shared facilities.
- Implemented: root construction is inert. Start/stop coalesce; invalidate synchronously fences admission. Foreground transitions join cleanup. Stop is terminal. Partial startup rolls back.
- Implemented: AgentFailure retains original errors, source and cleanup errors; pure cancellation remains distinct.
- Implemented: App caches one root, merges agents/native lifecycle nodes, and presents narrow role capabilities without internal voice session access.
- Implemented: removed replaced entry points, peer lifecycle ownership in Assistant and shared perception/synthesis session ownership.

## Acceptance

Test root/child identity and isolation, concurrent lifecycle, partial startup rollback, cancellation, joined stop, terminal rejection, foreground generations and unique registration/output consumers. Regress existing business flows. Run scripts/check.sh and scripts/build-ios.sh. Record actual results separately from native UI, real model and physical device acceptance in docs/validation/Agent-Containers.md.

Branch: codex/agent-container.

## Status

Code migration is implemented. Automated/build evidence and remaining native UI, real model and physical device acceptance are tracked in [validation](../../validation/Agent-Containers.md); acceptance is not complete until those independent checks are recorded.
