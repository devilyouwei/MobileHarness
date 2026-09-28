# ADR 0041 — Vision Perception Owns Skeleton Visualization

> Historical scope: Historical skeleton Action stage. [ADR 0042](0042-show-pose-completion-tool.md) changed UI.showPose to a completion-only Tool while VisionPerception retained ownership.

Status: accepted, 2026-09-26.

Photographer is reserved for camera-motion/composition business policy. Skeleton visualization is perception feedback and belongs to VisionPerception, superseding that part of ADR 0040.

✅ Move the existing hidden UI.showPose registration and Vision Channel from Photographer JSON to VisionPerception JSON. The perception worker publishes its full typed observation, then projects up to six people into bounded display JSON, resolves the Action through AgentGenerator and emits ActionCall plus agent.finished. App retains the explicit UI handler and drains the VisionPerception output stream through OutputGateway.

✅ Missing business subscribers is an expected standalone visualization case; only noRecipients is handled locally. Authorization, unavailable targets and unexpected errors still fail. Cancellation/expiry is rechecked after publication. The capacity-eight output stream fails on overflow and never replaces Actions. Inference remains one active/one latest pending frame.

✅ Remove the former display-only Photographer actor and config from production composition/package/navigation. Future motion responsibilities are now recorded in the [Photographer proposal](../Photographer-Proposal.md), without adding an empty placeholder Agent. Shared vision.pose remains available to future business subscribers.

❌ Physical camera-motion behavior and device acceptance are outside this change. Tests cover shared publication plus direct Actions, no-subscriber display, bounds, cancellation and overflow.

Validation (2026-09-26): final root checks passed, including 80 IntegrationTests and the no-subscriber/two-subscriber camera cases. All four simulator schemes and the unsigned physical Release target built successfully. Packaged VisionPerception JSON matches source; no Photographer JSON remains in the device App. No installation or physical-device acceptance was performed for this change.
