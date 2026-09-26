# Vision — Person Detection Capability (Design Only)

Purpose: give `TrackingAgent` a typed detection capability without it choosing a concrete vision SDK, following the same capability/adapter split as every other `ModelKit` interface. Design goals: no business/tracking logic here (that stays in the Agent, per ADR 0035 decision 6), Sendable request/result types, and an adapter boundary that lets Apple Vision be replaced by a converted custom model later without changing `TrackingAgent`. See [ADR 0035](../../../docs/adr/0035-tracking-agent-and-robot-actions.md) and [ModelKit/README.md](../README.md)'s capability-interface conventions.

- ❌ Nothing in this directory is implemented.

## Why Apple Vision for Milestone 1, not a converted model

`smart_capture.md`'s reference system calls an external detection model service; MobileHarness has no equivalent on-device model host yet, and pulling in a converted CoreML detector means managing its weights, artifacts and a `Backends/CoreML` adapter target before the aim loop can be tested at all. `VNDetectHumanRectanglesRequest`/`VNDetectHumanBodyPoseRequest` (Apple's `Vision` framework) need no bundled weights and are already covered by the repository's "use public platform APIs" rule. `PersonDetectionCapability` is defined as a protocol specifically so a later custom-model adapter is a drop-in replacement, matching how `ChatCapability` already has both a production `Qwen3.5` adapter and could accept another provider without changing `AssistantAgent`.

## Planned capability contract

```swift
public protocol PersonDetectionCapability: Capability {
    func detect(_ frame: ImageFrame) async throws -> PersonDetectionResult
}

public struct PersonDetectionResult: Sendable {
    public struct Person: Sendable {
        public let boundingBox: NormalizedRect   // 0...1 image-plane coordinates
        public let confidence: Double
        // Body-pose keypoints are a candidate follow-up, not required for Milestone 1's
        // highest-confidence-box target selection (see Agents/Tracking/README.md).
    }
    public let people: [Person]
    public let frameTimestamp: TimeInterval
}
```

Illustrative only — not an existing Swift API. Follows the existing capability shape (`Capability: Sendable`, async `availability`, typed request/result, no model identity leakage) documented in `ModelKit/README.md`'s "Capability interfaces" section, adapted for a single-shot per-frame call rather than a streaming `InferenceSession`, since Apple Vision's request/response API does not need one.

## Direct relationships (planned)

```mermaid
flowchart LR
    TA[TrackingAgent] -->|detect frame| Vision[PersonDetectionCapability]
    Vision -->|VNDetectHumanRectanglesRequest| Engine[Apple Vision framework]
    Engine -->|Observations| Vision
    Vision -->|PersonDetectionResult| TA
```

`ImageFrame` (planned in `ModelKit/Core`, see `PlatformKit/Camera/README.md`) is the input type; both directories must agree on its exact shape before either is implemented.

## Explicitly out of scope

Face detection/recognition, embeddings, pose-based orientation classification (`smart_capture.md` section 6), and any multi-frame temporal tracking (`smart_capture.md` section 3.1's Kalman-filter tracker) — this capability is a single-frame, stateless detector; per-track identity and temporal smoothing belong to `TrackingAgent`'s own state, not to `ModelKit`, matching the existing rule that `ModelKit` does not choose business goals.

## Maintenance

Keep this README synchronized with implementation as soon as any file in this directory stops being documentation-only. Update `ModelKit/README.md`'s directory table and implementation-status list (currently "❌ VLM, computer vision, embeddings... are not implemented") when a concrete adapter lands, following the base-`ModelKit`-target-vs-adapter-target split already used by `Language/LLM`.
