# Native input and internal Signal flow overview

Date: 2026-10-25. Scope: document the implemented intake, perception, cognition, inter-role communication and execution paths; no runtime change.

## Intent and source evidence

The user describes the verified operational improvement from keeping raw sensor traffic outside Gateway and asks for a source-to-effect overview. The principal sensory loop is raw data → perception → semantic role communication → cognition → execution, with outcome and environmental feedback. Current code uses direct native/UI/container inputs and a separate identity-bound internal communication path. Perception/cognition are responsibilities inside Agents, not new modules or containers; neither is a mandatory additional LLM stage.

Checked sources:

- Agents/VisionPerception/VisionPerceptionCamera.swift: consumes native CameraFrame directly and locally adapts processing context; there is no Gateway input transport hop.
- Agents/SpeechPerception/SpeechPerceptionMicrophone.swift: owns the read-only capture subscription and processes the bounded native PCM source inline before pulling the next packet.
- Agents/Support/Communication/PerceptionMessage.swift and AgentContracts.swift: typed semantic speech/pose/coordination messages, distinct from raw media.
- Resources/Agents declarations: speech.final and speech.phase reach Assistant, vision.pose reaches Photographer; declaration alone does not guarantee a subscriber for other published contracts.
- Agents/Support/InputGateway.swift and OutputGateway.swift: role policy, producer identity, communication output and canonical execution submission.
- Gateway/Input/SignalTransport.swift: opaque endpoint/envelope transport, not perception or role policy.
- Gateway execution facilities and ActionsContainer: authorized execution request, preparation, scheduling/resources, execution and real correlated outcome.

## Documentation changes

Extend Part III, section 2 of the overall technical README with an English source/perception/cognition/execution figure, a concise distinction between direct inputs, internal messages and Action requests/results, and the legitimate bypass/feedback paths. Keep endpoint-level communication detail in the same section and link the concrete speech/vision workflows. Align the Agents and communication terminology documentation without duplicating algorithms or queue limits.

Direct intake avoids routing and validating each media packet as an inter-role Signal. This architectural explanation is supported by source ownership; it is not a new zero-copy claim, quantitative performance measurement or unconditional transport-liveness guarantee. The user's report of better behavior and fewer Gateway stalls is qualitative feedback. No new comparative benchmark or hardware run is performed here; prior evidence remains in [direct input validation](Direct-Container-Input.md).

## Verification

The new overview is in Part III, section 2, before the existing bound-endpoint figure. It distinguishes native/local inputs, derived and role-originated internal Signals, execution requests and returned outcomes. The main document and the Agents/communication/concept/architecture entry points are aligned through links to that one cross-module figure.

- All 24 figures in the current overall README parse and render successfully with Mermaid 11.12.0 in the installed headless Chrome environment. The new figure was visually inspected at full size and simplified to keep source ports, Agent responsibilities and the two facilities of one Gateway readable.
- The existing 23 Mermaid sources are byte-for-byte unchanged by this task; the new overview adds one figure. The overall technical document remains entirely English.
- Source review confirms native streams bypass SignalTransport; published speech.final/vision.pose and reply coordination follow the actual registered consumers. Unsubscribed publication is not described as delivered to a role.
- Local path/anchor and diff whitespace checks pass. Rendering artifacts are temporary files under /tmp; the Mermaid source in the README is authoritative.

Documentation only; repository builds, runtime acceptance and performance benchmarks are not rerun.
