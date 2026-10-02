# Delivery roadmap

## Implemented foundation

| Area | Delivered scope |
| --- | --- |
| Agent runtime | Four business Agents, JSON v5 permissions, static communication and independent AgentCore. |
| Processing | Local speech/chat/pose capabilities, explicit cloud chat configuration and shared model management. |
| Behavior | Scheduled Actions, direct Tools, nested wait, result feedback and declared-resource coordination. |
| Host | Independent UI, role-specific lifecycle dependencies, six feature workflows and typed App adapters. |
| Data | Persistent settings/conversation history and reply-owned transient PCM. |
| Devices | Foreground camera/audio and NexArm connection, native feedback and shared Action bindings. |

Current contracts and dependencies live in the [technical design](../MobileHarness/README.md); implementation history is retained in [Milestone-History](Milestone-History.md).

## Acceptance work

- Record sustained iPhone Chinese/English conversation, listening quality, synthesis quality, first-audio latency, interruptions/route changes, memory and thermal behavior using [Voice](Voice.md) and [MOSS validation](Moss-Validation.md).
- Validate real cloud providers, switching and failure recovery separately from offline adapter tests.
- Extend supervised robot evidence to relevant BLE cadence, repeated operation, hardware/load configurations and recovery cases. Existing trial results are scoped to their recorded environment in [physical acceptance](NexArm_Physical_Acceptance.md) and [measurements](measurements/README.md).
- Validate current streaming/wait/cancellation behavior under real model output and device playback/presentation.

## Future implementation directions

| Direction | Boundary before implementation |
| --- | --- |
| Additional media/semantic memory | Concrete consumers, retention/privacy/deletion and capacity policy. |
| Richer model capabilities | Typed capability, real adapter need and explicit unsupported behavior. |
| Local native Tool events and result-driven request/reply | Transport schemas, permission/identity, cancellation and feedback ownership. |
| Fast/slow cognition and compute routing | Explicit Agent roles and capability availability/resource policy. |
| Activity supervision and multi-window ownership | Named lifetime/resource owners and isolated state routing. |
| Photographer motion | User task, native device capabilities, bounded motion, feedback and device-side protection; see [proposal](Photographer-Proposal.md). |

No delivery dates or physical safety certification are implied. Requirements belong to [Requirements](Requirements.md), experimental results to evidence documents, and architecture decisions to [ADRs](adr/README.md).

- Camera.open/close/flip Tools are registered and declared in Assistant JSON; physical camera/lens/permission acceptance and native model Tool event transport remain pending.
