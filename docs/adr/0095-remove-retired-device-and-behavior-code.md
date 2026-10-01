# ADR0095 — Remove retired device and behavior code

Status: implemented, 2026-10-02.

## Decision

Keep one production NexArm motion-completion path. The retired wrist/base polling diagnostics, fixed settlement waits and their diagnostic state move from the Action controller into a root IntegrationTests fixture. Historical opt-in tests keep their old algorithm for reproduction; application composition cannot reach it. Delete their duplicate native packet encoder and error cases that no production path emits.

Remove unused PermissionProvider/DeviceCapability/AuthorizationStatus and ExternalDeviceTransport placeholders. They have no callers or conformers. Current device adapters already perform public-platform authorization themselves, and no generic emergency-stop implementation exists. PlatformKit/Core is documentation only until real shared consumers justify a contract. Remove the unused single-buffer audio compatibility wrapper; playback and diagnostics already use playStream.

Live and observed native position writes use the same per-motor hardware-limit validation. The retired live-control full-encoder-range fallback must not admit targets rejected by the native encoder. Tests cover valid endpoints and rejected out-of-range positions for every motor.

Consolidate Actions/Runtime and Tools documentation around current macros, explicit bindings, resources, deadlines and failure continuation. Keep domain completion policy in Actions and transport facts in PlatformKit. No new Action paths, Agent permissions or motion choreography are introduced.

## Verification and limits

Root tests retain historical diagnostics separately and exercise the current production path. Boundary checks reject reintroduction of retired polling APIs into Actions. Full tests and simulator/device builds are recorded in the roadmap. This cleanup does not establish new physical acceptance or emergency-stop behavior.
