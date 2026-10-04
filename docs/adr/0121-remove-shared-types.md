# ADR 0121: Remove the shared Types module

Status: Accepted. Supersedes the transport/presentation placement in ADR0114–ADR0120.

## Decision

Capability SDKs own their input/output contracts. ModelKit, PlatformKit and Storage have no project dependencies; StorageChat and StorageAudio depend only on Storage. Consumers perform adaptation according to the called capability contract.

AgentCore/Input owns AudioInput, AudioValidationError, ImageInput, ImageAttachment and ImageInputError as generic gateway input contracts. AgentCore imports Foundation only and has no project dependencies. Business message values remain in Agents/Communication.

UI/Camera owns PoseOverlay, Joint and Statistics. UI depends only on StorageChat. VisionPerception owns an Encodable PoseOverlayPayload, Tool UI.showPose owns its validated ToolPoseOverlay, and App maps Tool values into UI values. Existing JSON fields and compact joint arrays remain unchanged; no UI dependency enters Agents.

Types sources, SwiftPM target/product membership and Xcode navigator group are removed without compatibility aliases. Boundary checks reject the retired module and enforce the owning targets.

## Consequences

Each boundary has an explicit adaptation point. The Agent, Tool and UI pose values represent different responsibilities and remain independently owned. Wire compatibility is validated by existing integration tests. Runtime lifecycle, queues and persisted formats are unchanged.
