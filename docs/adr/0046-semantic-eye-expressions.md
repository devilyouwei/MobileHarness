# ADR 0046 — Semantic eye expressions

Accepted: 2026-09-27.

## Decision

UI.express previously converted emotion names into emoji before passing them to App. Remove that glyph transport. The Action now validates and supplies UIActions.Emotion; App stores the enum, with clear mapping to neutral. The existing Action path, required emotion string parameter and Gateway validation remain. Assistant.agent.json v4 documents the full domain, adding angry/scared/playful without separate Actions or Swift registration lists.

Experience owns an exhaustive mapping from emotion to two EyePose values: lid curvature/slant, openness, width, tilt and offset. Stable Shape identities and path topology allow native interpolation for every change. An interrupted transition targets the new pose from its current visual state; expression UUIDs and asset/glyph replacement are removed. Clearing follows the same transition.

The response uses a 0.65-second critically damped spring; blink uses a smooth cosine envelope at up to 60 Hz. Inactive scenes pause motion. Reduce Motion disables recurring movement and shortens the interpolation to 0.2 seconds. There is one current target, no expression FIFO or task per expression. Action completion still means target state accepted, not animation finished.

## Dependencies and extension

No third-party library is needed for two parameterized vector eyes. [SwiftUI Animatable](https://developer.apple.com/documentation/swiftui/animatable) supplies numeric interpolation; standard transforms and springs handle pose changes. Adding presets does not require adding rendering engines. Reconsider an external authoring/runtime tool only for a concrete need to import designer-authored multi-stage assets or share those assets across platforms.

## Validation and limits

✅ Parameterized Action tests cover every supported emotion, rejection and cancellation. Native view compilation checks the exhaustive preset mapping. JSON examples and capabilities continue through existing repository validation.

❌ Frame-time guarantees, richer multi-stage emotional performances, actual face/hand tracking and physical-device visual acceptance require separate validation. No emoji is used to represent a facial expression; ordinary conversation text is not globally filtered or rewritten.
