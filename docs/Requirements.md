# Product requirements

## Product goal

MobileHarness connects perception, cognition and behavior in one Apple-native application. The iPhone is the current host; specialized stateful Agents cooperate through explicit communication and shared processing capabilities.

## User scenarios

| Scenario | Expected behavior |
| --- | --- |
| Voice conversation | Start/stop microphone interaction, inspect recognition and receive spoken replies with captions. |
| Visual awareness | Use foreground camera preview and pose visualization independently of voice readiness. |
| Expressive companion | Present semantic eye expressions, gaze, voice phase and actual audio spectrum state. |
| Connected robot | Discover/connect a supported device and request bounded, supervised movement with truthful execution status. |
| Provider choice | Use local chat or explicitly configure a compatible cloud provider; surface configuration/provider failures. |
| Agent records | Inspect Agent-specific retained evidence for user/developer traceability. Current Assistant conversations include raw exchanges and foreground Task summaries/sources; start a new conversation, archive and retry titles without replaying behavior. Separate execution diagnostics retain runtime tasks. |
| Diagnostics | Explicitly run diagnostic operations and distinguish synthetic previews from real processing. |

## Behavioral requirements

- Camera lens selection specifies front or back; selecting the current healthy lens is idempotent. Manual switching resolves an explicit opposite-lens target.
- Completed ASR captions remain above the eyes while assistant captions stream below. User and assistant use distinct colors and accessibility labels; the next turn clears both. Reduce Motion disables the travel animation.
- Eye gaze follows both horizontal and vertical targets, with less vertical displacement. The love expression displays two heart-shaped eyes.
- User/OS stop, interruption and session replacement coordinate cancellation and cleanup; stale sessions cannot update current output.
- Speech, UI and device effects require explicit authorization and registered behavior; messages do not bypass execution permissions.
- Failures, unavailable capabilities and capacity exhaustion are explicit. Device actions are not silently discarded or replayed.
- Model and device operations have named owners; page navigation does not own ongoing runtime work.
- Local settings and conversation history survive application restart. Transient audio is scoped to its reply/session rather than durable history.
- Cloud processing is an explicit choice. Credentials remain device-local; captured media/model artifacts are not repository content.
- Physical robot protection cannot depend on continued iOS background execution or UI responsiveness.

## Scope and planned directions

Current implementation is described in [Architecture](Architecture.md) and the source technical documents. Detailed acceptance criteria and measurements belong to [validation](README.md#experiments-tests-and-acceptance); this document does not assign measured latency/quality targets.

Fast/slow cognitive coordination, additional media/memory capabilities and Photographer motion remain planned directions in [Roadmap](Roadmap.md). General cross-platform support, persistent background autonomy, arbitrary system/app control and distributed Agent infrastructure are outside the delivered scope.

The original [technical baseline](Tech_Design.md) and [Word design](Technical_Design.docx) retain the earlier project goals; this document summarizes the current product scope without making their example APIs current contracts.
