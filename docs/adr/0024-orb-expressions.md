# ADR 0024: Present expressions independently from captions

> Historical scope: Historical emoji/orb presentation. [ADR 0046](0046-semantic-eye-expressions.md) replaced glyph transport with procedural eyes.

UI.smile and UI.express use an explicitly injected expression callback; UI.print retains caption presentation. Actions remain independent of SwiftUI. Assistant declares express in JSON v3; parameter metadata and invocation types remain unchanged.

App checks session identity before updating one expression value and a presentation identity. Each accepted expression replaces the current visual state. Successful return acknowledges state acceptance, not completion of a decorative animation; rapid expressions can replace an earlier expression while it animates. There is no new queue, timer or detached task. New user speech and session stop clear expression state, and stale-session callbacks throw cancellation.

Experience renders the emoji in the voice circle with a spring transition and glow. Reduced Motion disables the spring. The overlay does not intercept recording-control taps. Physical-device appearance and model adherence remain manual acceptance work.
